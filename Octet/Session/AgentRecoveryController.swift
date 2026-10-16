import AppKit
import Foundation

/// Journals every Claude/Codex (and integration-reported) agent session and,
/// when a shutdown or session server restart kills them, hands them to the
/// recovery panel to resume in their workspaces with `claude --resume <id>`
/// / `codex resume <id>`.
@MainActor
final class AgentRecoveryController: ObservableObject {
    /// Told of sessions a shutdown or server restart killed; the recovery
    /// panel lists them.
    var onLost: (([AgentSessionRecord]) -> Void)?

    private let client: EngineClient
    private let url: URL
    private var journal: AgentSessionJournal
    /// `lastObserved` from the previous run, consumed by the first check.
    private var pendingCheck: Date?
    private var lastInference = Date.distantPast
    private var lastSave = Date.distantPast
    private var lastSnapshot: EngineSnapshot = .empty
    /// Agents running out of sight (closed tabs kept running): not in the
    /// snapshot Octet draws, but not to be offered back either.
    private var hiddenTerminals: Set<String> = []
    /// The session server's native resume needs a few seconds to relaunch agents.
    static let gracePeriod: TimeInterval = 8
    static let inferenceInterval: TimeInterval = 10

    init(client: EngineClient, url: URL = EngineSession.supportDirectory.appendingPathComponent("agent-sessions.json")) {
        self.client = client
        self.url = url
        journal = AgentSessionJournal.load(from: url)
        pendingCheck = journal.records.isEmpty ? nil : journal.lastObserved
    }

    /// The session server went away and came back (crash, `server stop`, update handoff):
    /// check again against the last snapshot seen before the drop.
    func connectionLost() {
        guard pendingCheck == nil, !journal.records.isEmpty else { return }
        pendingCheck = journal.lastObserved
        save()
    }

    /// Terminal id → first-seen time, for off-main session inference.
    /// Nil when inference isn't due yet.
    func inferenceRequest(now: Date = Date()) -> [String: Date]? {
        guard now.timeIntervalSince(lastInference) >= Self.inferenceInterval else { return nil }
        lastInference = now
        return Dictionary(journal.records.map { ($0.terminalId, $0.firstSeen) }, uniquingKeysWith: { first, _ in first })
    }

    /// `allTerminals` holds every running agent's terminal, those in closed
    /// tabs too, which `snapshot` leaves out.
    func observe(_ snapshot: EngineSnapshot, inferred: [String: String], allTerminals: Set<String> = [], now: Date = Date()) {
        lastSnapshot = snapshot
        hiddenTerminals = allTerminals.subtracting(snapshot.agents.compactMap(\.terminalId))
        let before = journal.records
        // Record against the pre-restart journal only after the check has
        // captured which sessions were alive.
        if let lastObserved = pendingCheck {
            pendingCheck = nil
            let candidates = before.filter { $0.lastSeen >= lastObserved.addingTimeInterval(-2) }
            if !candidates.isEmpty, SettingsStore.shared.values.offerRecovery {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracePeriod) { [weak self] in
                    self?.offerLost(candidates, lastObserved: lastObserved)
                }
            }
        }
        journal.records = AgentRecovery.record(snapshot, into: before, now: now) { agent, _ in
            agent.sessionReference ?? agent.terminalId.flatMap { inferred[$0] }
        }
        journal.lastObserved = now
        let changed = journal.records.map(\.sessionId) != before.map(\.sessionId) || journal.records.count != before.count
        if changed || now.timeIntervalSince(lastSave) > 20 { save() }
    }

    private func offerLost(_ candidates: [AgentSessionRecord], lastObserved: Date) {
        let liveSessions = Set(journal.records.filter { $0.lastSeen >= journal.lastObserved.addingTimeInterval(-2) }.compactMap(\.sessionId))
        // Handled in the meantime (resumed or dismissed from the palette's list).
        let handled = Set(journal.records.filter(\.handled).map(\.id))
        let lost = AgentRecovery.lostSessions(
            journal: candidates.filter { !handled.contains($0.id) && !hiddenTerminals.contains($0.terminalId) },
            lastObserved: lastObserved, current: lastSnapshot, liveSessionIds: liveSessions)
        guard !lost.isEmpty else { return }
        onLost?(lost)
    }

    /// What Octet knows about the agent in one terminal.
    func record(forTerminal terminalId: String) -> AgentSessionRecord? {
        journal.records.first { $0.terminalId == terminalId }
    }

    /// The session a running agent's terminal is on, once Octet has seen its
    /// id: from the agent's own report, or its session files.
    func sessionId(forTerminal terminalId: String) -> String? {
        journal.records.first { $0.terminalId == terminalId }?.sessionId
    }

    /// Past sessions with a known id that aren't running, newest first, for
    /// a resume menu or the recovery panel's history.
    func resumableSessions() -> [AgentSessionRecord] {
        AgentRecovery.history(journal: journal.records, current: lastSnapshot, liveTerminals: hiddenTerminals)
    }

    func copyCommand(_ record: AgentSessionRecord) {
        guard let command = record.resumeCommand else { return }
        let text = "cd \(shellPath(record.cwd)) && \(command)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // This toast says it better than the generic clipboard one.
        ClipboardWatcher.shared.acknowledge()
        ToastCenter.shared.info("Copied resume command", detail: text)
    }

    /// Resumes each session in its workspace (recreated when gone): in the
    /// tab the server brought back in its place when one is sitting at a
    /// prompt, else a new tab. `report` hears of each as it lands, with the
    /// error when it failed. A session that resumed isn't offered again.
    func resume(_ records: [AgentSessionRecord], report: @escaping @MainActor (AgentSessionRecord, String?) -> Void) {
        guard !records.isEmpty else { return }
        let client = self.client
        let snapshot = lastSnapshot
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var createdWorkspaces: [String: String] = [:]
            var usedTabs: Set<String> = []
            for record in records {
                var failure: String?
                do {
                    try Self.resume(record, client: client, snapshot: snapshot, shell: shell,
                                    created: &createdWorkspaces, used: &usedTabs)
                } catch {
                    failure = RecoveryError.describe(error)
                }
                DispatchQueue.main.async {
                    if failure == nil { self?.markHandled([record]) }
                    report(record, failure)
                }
            }
        }
    }

    private nonisolated static func resume(
        _ record: AgentSessionRecord,
        client: EngineClient,
        snapshot: EngineSnapshot,
        shell: String,
        created: inout [String: String],
        used: inout Set<String>
    ) throws {
        guard record.resumeCommand != nil else { throw RecoveryError.notResumable }
        // A shell started in a missing folder lands in ~, and the agent
        // there can't find the conversation.
        guard FileManager.default.fileExists(atPath: record.cwd) else { throw RecoveryError.folderGone }
        let key = record.workspaceLabel + "\u{0}" + record.cwd
        var tabId: String?
        var workspaceId = created[key] ?? RecoveryList.workspace(label: record.workspaceLabel, cwd: record.cwd, in: snapshot)
        if workspaceId == nil {
            let label = record.workspaceLabel.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.workspaceLabel
            let result = try client.call("workspace.create", ["cwd": record.cwd, "label": label, "focus": false])
            workspaceId = (result["workspace"] as? [String: Any])?["workspace_id"] as? String
            // Fill the new workspace's empty first tab instead of adding one.
            tabId = (result["tab"] as? [String: Any])?["tab_id"] as? String
            if let workspaceId { created[key] = workspaceId }
        } else if let workspaceId {
            // The tab the server restored in its place, left at a prompt.
            tabId = RecoveryList.reusableTabs(named: record.tabLabel, cwd: record.cwd, workspaceId: workspaceId,
                                              in: snapshot, excluding: used, displayName: false)
                .first { candidate in
                    (try? client.call("pane.process_info", ["pane_id": candidate.pane.paneId]))
                        .flatMap(ShellRecovery.job(in:)) == nil
                }?.tab.tabId
        }
        if let tabId { used.insert(tabId) }
        try client.call("layout.apply", AgentRecovery.resumeRequest(
            record, shell: shell, workspaceId: workspaceId, tabId: tabId
        ))
    }

    // MARK: - Hot swap

    /// Running agents Octet can restart in place without losing the
    /// conversation: it knows their session id and their tab holds one pane.
    func reloadableAgents() -> [(agent: EngineAgent, record: AgentSessionRecord)] {
        let byTerminal = Dictionary(journal.records.map { ($0.terminalId, $0) }, uniquingKeysWith: { first, _ in first })
        return lastSnapshot.agents.compactMap { agent in
            guard let terminal = agent.terminalId, let record = byTerminal[terminal],
                  record.sessionId != nil, let tabId = agent.tabId,
                  lastSnapshot.panes.filter({ $0.tabId == tabId }).count == 1 else { return nil }
            return (agent, record)
        }
    }

    /// Agents that are running but can't be restarted in place, with why.
    func unreloadableAgents() -> [(agent: EngineAgent, reason: String)] {
        let byTerminal = Dictionary(journal.records.map { ($0.terminalId, $0) }, uniquingKeysWith: { first, _ in first })
        return lastSnapshot.agents.compactMap { agent in
            guard let terminal = agent.terminalId else { return nil }
            guard let record = byTerminal[terminal], record.sessionId != nil else {
                return (agent, "no session id yet")
            }
            if let tabId = agent.tabId, lastSnapshot.panes.filter({ $0.tabId == tabId }).count > 1 {
                return (agent, "its tab has split panes")
            }
            return nil
        }
    }

    /// Restarts each agent in its own tab with `--resume`, so it picks up new
    /// MCP servers, plugins, or skills while keeping the conversation.
    func reload(_ agents: [(agent: EngineAgent, record: AgentSessionRecord)]) {
        guard !agents.isEmpty else { return }
        let noun = agents.count == 1 ? "1 agent" : "\(agents.count) agents"
        let toast = ToastCenter.shared.progress("Reloading \(noun)…")
        let client = self.client
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for (agent, record) in agents {
                do {
                    try client.call("layout.apply", AgentRecovery.resumeRequest(
                        record, shell: shell, workspaceId: agent.workspaceId, tabId: agent.tabId
                    ))
                } catch {
                    failures.append("\(record.tabLabel.isEmpty ? record.agent : record.tabLabel): \(error)")
                }
            }
            DispatchQueue.main.async {
                if failures.isEmpty {
                    ToastCenter.shared.succeed(toast, "Reloaded \(noun)",
                                               detail: "Resumed with the new configuration")
                } else {
                    ToastCenter.shared.fail(toast, "Reloaded \(agents.count - failures.count) of \(agents.count) agents",
                                            detail: failures.prefix(3).joined(separator: "\n"))
                }
            }
        }
    }

    nonisolated static func displayName(_ record: AgentSessionRecord) -> String {
        AgentBrand.forAgent(record.agent)?.displayName ?? record.agent
    }

    /// Not offered again after a restart: resumed, or dismissed.
    func markHandled(_ records: [AgentSessionRecord]) {
        let ids = Set(records.map(\.id))
        for index in journal.records.indices where ids.contains(journal.records[index].id) {
            journal.records[index].handled = true
        }
        save()
    }

    private func save() {
        lastSave = Date()
        let journal = self.journal, url = self.url
        DispatchQueue.global(qos: .utility).async { journal.save(to: url) }
    }

    private func shellPath(_ path: String) -> String {
        path.range(of: "^[A-Za-z0-9_./~-]+$", options: .regularExpression) != nil
            ? path : "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Why an item couldn't be brought back.
enum RecoveryError: LocalizedError {
    case notResumable
    case folderGone

    var errorDescription: String? {
        switch self {
        case .notResumable: "Octet doesn't know how to resume this session"
        case .folderGone: "Its folder no longer exists"
        }
    }

    /// An error as a line a row can show.
    nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}
