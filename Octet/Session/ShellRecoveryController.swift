import Foundation

/// Crash recovery for terminals. Every few seconds Octet notes each terminal
/// that's running something (where, what, and its recent output, kept on
/// disk). Octet itself quitting or crashing loses nothing, since the session
/// server keeps the processes. If the server goes too, taking them with it,
/// Octet offers those terminals back in the recovery panel: in their
/// workspace and folder, showing what they last printed, with the command
/// named so it can be run again. It never reruns anything by itself.
@MainActor
final class ShellRecoveryController: ObservableObject {
    /// Told of terminals lost with the session server; the recovery panel
    /// lists them.
    var onLost: (([ShellSessionRecord]) -> Void)?
    /// Lost terminals not yet restored, offered or set aside: their output
    /// is kept on disk until they're restored or Octet quits.
    private var pending: [ShellSessionRecord] = []

    private let client: EngineClient
    private let url: URL
    let dumps: URL
    private var journal: ShellSessionJournal
    /// `lastObserved` before the drop, consumed by the first snapshot after it.
    private var pendingCheck: Date?
    /// No new look until the check has run, so it compares against the old one.
    private var holdUntil = Date.distantPast
    private var capturing = false
    private var lastCapture = Date.distantPast
    private var lastSnapshot: EngineSnapshot = .empty
    /// What each dump last held, to skip rewriting unchanged output.
    private var written: [String: Int] = [:]
    static let interval: TimeInterval = 10
    /// Enough of the output to see where it got to.
    static let dumpLines = 400

    init(client: EngineClient, directory: URL = EngineSession.supportDirectory) {
        self.client = client
        url = directory.appendingPathComponent("shell-sessions.json")
        dumps = directory.appendingPathComponent("shell-dumps", isDirectory: true)
        journal = ShellSessionJournal.load(from: url)
        pendingCheck = journal.records.isEmpty ? nil : journal.lastObserved
    }

    /// The session server went away: check against the last look before it.
    func connectionLost() {
        guard pendingCheck == nil, !journal.records.isEmpty else { return }
        pendingCheck = journal.lastObserved
    }

    /// Takes the snapshot Octet shows (closed tabs aren't journaled: they
    /// were closed on purpose).
    func observe(_ snapshot: EngineSnapshot) {
        lastSnapshot = snapshot
        if let lastObserved = pendingCheck {
            pendingCheck = nil
            let records = journal.records
            // The server brings back its own tabs first; judge after that.
            holdUntil = Date().addingTimeInterval(AgentRecoveryController.gracePeriod + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentRecoveryController.gracePeriod) { [weak self] in
                self?.offerLost(records, lastObserved: lastObserved)
            }
            return
        }
        capture()
    }

    private func offerLost(_ records: [ShellSessionRecord], lastObserved: Date) {
        let live = Set(lastSnapshot.panes.compactMap(\.terminalId))
        let lost = ShellRecovery.lost(records, lastObserved: lastObserved, liveTerminals: live)
        guard !lost.isEmpty, SettingsStore.shared.values.offerRecovery else { return }
        pending.removeAll { record in lost.contains { $0.id == record.id } }
        pending += lost
        // Offered now: the journal's next look shouldn't offer them twice.
        journal.records.removeAll { record in lost.contains { $0.id == record.id } }
        save()
        onLost?(lost)
    }

    // MARK: - Journaling

    private func capture(now: Date = Date()) {
        guard !capturing, now >= holdUntil, now.timeIntervalSince(lastCapture) >= Self.interval else { return }
        capturing = true
        lastCapture = now
        let snapshot = lastSnapshot
        let client = self.client
        let dumps = self.dumps
        let written = self.written
        // Agents are resumed from their own sessions, not replayed.
        let agentPanes = Set(snapshot.agents.map(\.paneId))
        let panes = snapshot.panes.filter { $0.terminalId != nil && !agentPanes.contains($0.paneId) }
        let keepDumps = Set(pending.map(\.terminalId))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var busy: [(pane: EnginePane, job: ShellJob)] = []
            var wrote: [String: Int] = [:]
            try? FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
            for pane in panes {
                guard let job = (try? client.call("pane.process_info", ["pane_id": pane.paneId])).flatMap(ShellRecovery.job(in:)),
                      let terminal = pane.terminalId else { continue }
                busy.append((pane, job))
                let read = try? client.call("pane.read", ["pane_id": pane.paneId, "source": "recent",
                                                          "lines": Self.dumpLines, "format": "ansi"])
                guard let text = (read?["read"] as? [String: Any])?["text"] as? String else { continue }
                let hash = text.hashValue
                wrote[terminal] = hash
                if written[terminal] != hash {
                    try? Data(text.utf8).write(to: ShellRecovery.dumpURL(for: terminal, in: dumps), options: .atomic)
                }
            }
            // Output of terminals that finished or closed isn't needed.
            let keep = Set(busy.compactMap { $0.pane.terminalId }).union(keepDumps)
                .map { ShellRecovery.dumpURL(for: $0, in: dumps).lastPathComponent }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dumps.path)) ?? []
            for file in files where !keep.contains(file) {
                try? FileManager.default.removeItem(at: dumps.appendingPathComponent(file))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                self.written = wrote
                // A check that started meanwhile compares against the old look.
                guard self.pendingCheck == nil, Date() >= self.holdUntil else { return }
                self.journal.records = ShellRecovery.record(busy, in: snapshot, into: self.journal.records, now: now)
                self.journal.lastObserved = now
                self.save()
            }
        }
    }

    // MARK: - Restoring

    /// Reopens each terminal in its workspace: in the tab the server brought
    /// back for it when there is one sitting at a prompt, else a new tab.
    /// `report` hears of each as it lands, with the error when it failed.
    func restore(_ records: [ShellSessionRecord], report: @escaping @MainActor (ShellSessionRecord, String?) -> Void) {
        guard !records.isEmpty else { return }
        let client = self.client
        let snapshot = lastSnapshot
        let dumps = self.dumps
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var createdWorkspaces: [String: String] = [:]
            var usedTabs: Set<String> = []
            for record in records {
                var failure: String?
                do {
                    try Self.restore(record, client: client, snapshot: snapshot, dumps: dumps, shell: shell,
                                     created: &createdWorkspaces, used: &usedTabs)
                } catch {
                    failure = RecoveryError.describe(error)
                }
                DispatchQueue.main.async {
                    // Back on screen: its kept output can go with the next look.
                    if failure == nil { self?.forget([record]) }
                    report(record, failure)
                }
            }
        }
    }

    /// The output kept for a lost terminal, for its row's preview.
    func dumpURL(for record: ShellSessionRecord) -> URL {
        ShellRecovery.dumpURL(for: record.terminalId, in: dumps)
    }

    private nonisolated static func restore(
        _ record: ShellSessionRecord, client: EngineClient, snapshot: EngineSnapshot, dumps: URL, shell: String,
        created: inout [String: String], used: inout Set<String>
    ) throws {
        guard FileManager.default.fileExists(atPath: record.cwd) else { throw RecoveryError.folderGone }
        let key = record.workspaceLabel + "\u{0}" + record.cwd
        var tabId: String?
        // By name and folder: a name alone took the first workspace of that
        // name, wherever it was.
        var workspaceId = created[key] ?? RecoveryList.workspace(label: record.workspaceLabel, cwd: record.cwd, in: snapshot)
        if workspaceId == nil {
            let label = record.workspaceLabel.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.workspaceLabel
            let result = try client.call("workspace.create", ["cwd": record.cwd, "label": label, "focus": false])
            workspaceId = (result["workspace"] as? [String: Any])?["workspace_id"] as? String
            tabId = (result["tab"] as? [String: Any])?["tab_id"] as? String
            if let workspaceId { created[key] = workspaceId }
        } else if let workspaceId {
            // The tab the server restored in its place: same name, one pane,
            // in the same folder, with nothing running.
            tabId = RecoveryList.reusableTabs(named: record.tabLabel, cwd: record.cwd, workspaceId: workspaceId,
                                              in: snapshot, excluding: used, displayName: true)
                .first { candidate in
                    (try? client.call("pane.process_info", ["pane_id": candidate.pane.paneId]))
                        .flatMap(ShellRecovery.job(in:)) == nil
                }?.tab.tabId
        }
        if let tabId { used.insert(tabId) }
        let dump = ShellRecovery.dumpURL(for: record.terminalId, in: dumps)
        let result = try client.call("layout.apply", ShellRecovery.reopenRequest(
            record, dump: FileManager.default.fileExists(atPath: dump.path) ? dump : nil,
            shell: shell, workspaceId: workspaceId, tabId: tabId
        ))
        // The command goes back on the prompt, unsent: running it again is
        // your call. Typed once the shell is up, so it isn't echoed twice.
        guard let pane = EngineCreated(result: result).paneId else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            _ = try? client.call("pane.send_text", ["pane_id": pane, "text": record.command])
        }
    }

    /// Lets lost terminals go for good, and the output kept for them (on
    /// the next look). Dismissing from the panel doesn't: the palette can
    /// still bring the list back until Octet quits.
    func forget(_ records: [ShellSessionRecord]) {
        pending.removeAll { record in records.contains { $0.id == record.id } }
        journal.records.removeAll { record in records.contains { $0.id == record.id } }
        save()
    }

    private func save() {
        let journal = self.journal, url = self.url
        DispatchQueue.global(qos: .utility).async { journal.save(to: url) }
    }
}
