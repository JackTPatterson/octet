import Foundation

/// Where one item in the recovery panel stands.
enum RecoveryStatus: Equatable {
    /// Can be brought back.
    case ready
    case restoring
    case restored
    /// Tried and failed, with why; it can be tried again.
    case failed(String)
    /// Can't be brought back, with why (its folder or session file is gone).
    case unavailable(String)

    var canRestore: Bool {
        switch self {
        case .ready, .failed: true
        default: false
        }
    }

    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
}

/// One agent session or terminal the recovery panel offers back.
struct RecoveryItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case agent(AgentSessionRecord)
        case terminal(ShellSessionRecord)
    }

    let kind: Kind
    /// The agent's last message, or the terminal's last line of output.
    var preview: String?
    var status: RecoveryStatus = .ready

    init(agent record: AgentSessionRecord, status: RecoveryStatus = .ready, preview: String? = nil) {
        kind = .agent(record)
        self.status = status
        self.preview = preview
    }

    init(terminal record: ShellSessionRecord, status: RecoveryStatus = .ready, preview: String? = nil) {
        kind = .terminal(record)
        self.status = status
        self.preview = preview
    }

    var id: String {
        switch kind {
        case .agent(let record): "agent:" + record.id
        case .terminal(let record): "terminal:" + record.id
        }
    }

    var agentRecord: AgentSessionRecord? { if case .agent(let record) = kind { record } else { nil } }
    var terminalRecord: ShellSessionRecord? { if case .terminal(let record) = kind { record } else { nil } }

    /// `claude`, `codex`, …; nil for a terminal.
    var agent: String? { agentRecord?.agent }

    var workspaceLabel: String {
        switch kind {
        case .agent(let record): record.workspaceLabel
        case .terminal(let record): record.workspaceLabel
        }
    }

    var cwd: String {
        switch kind {
        case .agent(let record): record.cwd
        case .terminal(let record): record.cwd
        }
    }

    var lastSeen: Date {
        switch kind {
        case .agent(let record): record.lastSeen
        case .terminal(let record): record.lastSeen
        }
    }

    /// The row's name: the tab's name when it has a meaningful one, else the
    /// agent's name or the terminal's command.
    var title: String {
        switch kind {
        case .agent(let record):
            let name = AgentBrand.forAgent(record.agent)?.displayName ?? record.agent
            let tab = record.tabLabel.trimmingCharacters(in: .whitespaces)
            let generic = tab.isEmpty || tab.lowercased() == record.agent.lowercased() || tab == name
                || tab == TabAutoName.unnamedLabel
            return generic ? name : tab
        case .terminal(let record):
            return ShellRecovery.short(record.command)
        }
    }

    /// What the title leaves out: the agent for a named tab, the tab for a
    /// terminal.
    var detail: String? {
        switch kind {
        case .agent(let record):
            let name = AgentBrand.forAgent(record.agent)?.displayName ?? record.agent
            return title == name ? nil : name
        case .terminal(let record):
            return record.tabLabel.isEmpty || record.tabLabel == TabAutoName.unnamedLabel ? nil : record.tabLabel
        }
    }

    /// What reopening it runs, for copying.
    var command: String? {
        switch kind {
        case .agent(let record): record.resumeCommand
        case .terminal(let record): record.command
        }
    }
}

/// The recovery panel's logic, kept apart from its view and controllers so
/// it can be tested: grouping, what can still be resumed, where it goes back,
/// what the buttons say.
enum RecoveryList {
    /// Items of one workspace, under its name.
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [RecoveryItem]
    }

    /// Rows grouped by workspace (by folder when the workspace had no name),
    /// the most recently active group first, and newest first inside each.
    static func groups(_ items: [RecoveryItem]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [RecoveryItem]] = [:]
        for item in items {
            let key = item.workspaceLabel.isEmpty ? "dir:" + item.cwd : "ws:" + item.workspaceLabel
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { key in
            let members = buckets[key]!.sorted { ($0.lastSeen, $1.id) > ($1.lastSeen, $0.id) }
            let first = members[0]
            let title = first.workspaceLabel.isEmpty
                ? ((first.cwd as NSString).lastPathComponent.isEmpty ? first.cwd : (first.cwd as NSString).lastPathComponent)
                : first.workspaceLabel
            return Group(id: key, title: title, items: members)
        }
        .sorted { ($0.items[0].lastSeen, $1.id) > ($1.items[0].lastSeen, $0.id) }
    }

    /// One record per session, the most recently seen: the same conversation
    /// resumed in a second terminal would otherwise be offered twice.
    static func dedupe(_ records: [AgentSessionRecord]) -> [AgentSessionRecord] {
        var newest: [String: AgentSessionRecord] = [:]
        for record in records {
            guard let id = record.sessionId else { continue }
            if let kept = newest[id], kept.lastSeen >= record.lastSeen { continue }
            newest[id] = record
        }
        return records.filter { record in
            guard let id = record.sessionId else { return true }
            return newest[id]?.terminalId == record.terminalId
        }
    }

    /// New items joined to those already listed: none twice, and none that
    /// was restored or dismissed earlier in this run.
    static func merge(_ existing: [RecoveryItem], _ incoming: [RecoveryItem], settled: Set<String>) -> [RecoveryItem] {
        var seen = Set(existing.map(\.id))
        var sessions = Set(existing.compactMap { $0.agentRecord?.sessionId })
        var result = existing
        for item in incoming where !settled.contains(item.id) && seen.insert(item.id).inserted {
            if let session = item.agentRecord?.sessionId, !sessions.insert(session).inserted { continue }
            result.append(item)
        }
        return result
    }

    // MARK: - Availability

    /// Why an agent session can't be resumed, or nil when it can.
    /// `sessionFileExists` is nil when Octet can't tell (an agent whose
    /// session files it doesn't know).
    static func unavailableReason(_ record: AgentSessionRecord, folderExists: Bool, sessionFileExists: Bool?) -> String? {
        let name = AgentBrand.forAgent(record.agent)?.displayName ?? record.agent
        if record.sessionId == nil {
            return "Octet never learned which session it was"
        }
        if record.resumeCommand == nil {
            return "\(name) can't resume a session from the command line"
        }
        if !folderExists {
            return "Its folder no longer exists"
        }
        if sessionFileExists == false {
            return "\(name) no longer has this session"
        }
        return nil
    }

    /// Why a terminal can't be reopened, or nil when it can.
    static func unavailableReason(_ record: ShellSessionRecord, folderExists: Bool) -> String? {
        folderExists ? nil : "Its folder no longer exists"
    }

    /// Whether the agent's own record of the session is still on disk: nil
    /// for agents whose files Octet doesn't read.
    static func sessionFileExists(_ record: AgentSessionRecord, home: String = NSHomeDirectory(),
                                  now: Date = Date()) -> Bool? {
        guard let id = record.sessionId else { return nil }
        switch AgentBrand.forAgent(record.agent)?.id {
        case "claude":
            // Claude resumes only from the folder it was started in.
            let path = ClaudeTranscriptActivity.projectDirectory(forCwd: record.cwd, home: home) + "/\(id).jsonl"
            return FileManager.default.fileExists(atPath: path)
        case "codex":
            return AgentSessionFiles.codexPath(forSession: id, now: now, home: home) != nil
        default:
            return nil
        }
    }

    /// The session's transcript, for the row's preview.
    static func transcriptPath(_ record: AgentSessionRecord, home: String = NSHomeDirectory()) -> String? {
        guard let id = record.sessionId else { return nil }
        switch AgentBrand.forAgent(record.agent)?.id {
        case "claude": return ClaudeTranscriptActivity.projectDirectory(forCwd: record.cwd, home: home) + "/\(id).jsonl"
        case "codex": return AgentSessionFiles.codexPath(forSession: id, home: home)
        default: return nil
        }
    }

    /// The last thing the agent said, from the tail of its transcript.
    static func lastMessage(agent: String, lines: [String], limit: Int = 160) -> String? {
        let conversation = TwinTranscript.parse(agent: agent, lines: lines)
        for message in conversation.messages.reversed() where message.role == .assistant {
            for block in message.blocks.reversed() {
                guard case .text(let text) = block else { continue }
                let line = TwinTranscript.condense(text, limit: limit)
                if !line.isEmpty { return line }
            }
        }
        return nil
    }

    // MARK: - Placement

    /// The workspace an item goes back into: the one of that name in its
    /// folder, else one in its folder, else the closest one holding its
    /// folder, else one of that name. Nil means a new one is made.
    static func workspace(label: String, cwd: String, in snapshot: EngineSnapshot,
                          home: String = NSHomeDirectory()) -> String? {
        let folders = snapshot.workspaces.map { ($0, snapshot.directory(ofWorkspace: $0.workspaceId)) }
        func holds(_ folder: String?) -> Bool {
            guard let folder, folder != home, folder != "/" else { return false }
            return cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
        if !label.isEmpty, let match = folders.first(where: { $0.0.label == label && $0.1 == cwd }) {
            return match.0.workspaceId
        }
        if !label.isEmpty, let match = folders.first(where: { $0.0.label == label && holds($0.1) }) {
            return match.0.workspaceId
        }
        if let match = folders.first(where: { $0.1 == cwd }) { return match.0.workspaceId }
        if let match = folders.filter({ holds($0.1) }).max(by: { ($0.1?.count ?? 0) < ($1.1?.count ?? 0) }) {
            return match.0.workspaceId
        }
        if !label.isEmpty, let match = folders.first(where: { $0.0.label == label }) {
            return match.0.workspaceId
        }
        return nil
    }

    /// Tabs the session server brought back in an item's place: the same
    /// name, one pane, in the same folder, with no agent in it. Whether
    /// something is running in it is the caller's to ask.
    static func reusableTabs(named label: String, cwd: String, workspaceId: String, in snapshot: EngineSnapshot,
                             excluding used: Set<String>, displayName: Bool) -> [(tab: EngineTab, pane: EnginePane)] {
        guard !label.isEmpty else { return [] }
        let agentTabs = Set(snapshot.agents.compactMap(\.tabId))
        return snapshot.tabs(inWorkspace: workspaceId).compactMap { tab in
            let name = displayName ? TabAutoName.display(label: tab.label, number: tab.number) : tab.label
            guard !used.contains(tab.tabId), tab.paneCount == 1, name == label, !agentTabs.contains(tab.tabId),
                  let pane = snapshot.panes.first(where: { $0.tabId == tab.tabId }),
                  pane.effectiveCwd == cwd else { return nil }
            return (tab, pane)
        }
    }

    // MARK: - Words

    /// The main button: what it restores.
    static func restoreTitle(selected: Int, restorable: Int) -> String {
        if selected == 0 { return "Restore" }
        if selected == restorable, restorable > 1 { return "Restore All" }
        return "Restore \(selected)"
    }

    /// Where a batch has got to: done (restored or failed) of total.
    static func progress(_ items: [RecoveryItem], batch: Set<String>) -> (done: Int, total: Int)? {
        guard !batch.isEmpty else { return nil }
        let members = items.filter { batch.contains($0.id) }
        let done = members.filter { $0.status == .restored || $0.status.isFailed }.count
        return (done, batch.count)
    }

    /// Nothing left to do: every row restored or unavailable.
    static func isFinished(_ items: [RecoveryItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .restored || $0.status.isUnavailable }
    }

    /// "2 agent sessions and 1 terminal", for the panel's subtitle.
    static func countPhrase(_ items: [RecoveryItem]) -> String {
        let agents = items.filter { $0.agentRecord != nil }.count
        let terminals = items.count - agents
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) agent session\(agents == 1 ? "" : "s")") }
        if terminals > 0 { parts.append("\(terminals) terminal\(terminals == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }
}

extension ShellRecovery {
    /// The last line a terminal printed, without its colours, for a row's
    /// preview.
    static func lastOutputLine(_ text: String, limit: Int = 160) -> String? {
        // CSI and OSC sequences, then any other control character.
        let stripped = text
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}.", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for raw in stripped.components(separatedBy: "\n").reversed() {
            // A carriage return redraws the line: what's after the last one shows.
            let shown = raw.components(separatedBy: "\r").last ?? raw
            let line = String(shown.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }
}
