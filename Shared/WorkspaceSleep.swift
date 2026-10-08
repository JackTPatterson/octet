import Foundation

/// A workspace put to sleep: its terminals closed, so it costs nothing, and
/// written down so it comes back as it was. Its folder and branch, a tab per
/// tab (the shell's folder, or the agent conversation it held, resumed with
/// the agent's own `--resume`), and Octet's conversations in it. Files are
/// never touched; a sleeping workspace's changes stay where they are.
struct SleepingWorkspace: Codable, Equatable, Identifiable {
    struct Tab: Codable, Equatable {
        var label: String
        var cwd: String
        /// The agent conversation the tab held, to resume in it.
        var agent: AgentSessionRecord?
    }

    struct Conversation: Codable, Equatable {
        /// `AgentSession.Engine`'s raw value.
        var engine: String
        var sessionId: String
        var title: String
        var cwd: String
    }

    var id: String = UUID().uuidString
    var label: String
    var cwd: String
    var branch: String?
    var project: String?
    var sleptAt: Date
    var lastActive: Date?
    var tabs: [Tab]
    var conversations: [Conversation] = []
    /// What it held when it went to sleep (uncommitted files, …), to say on its row.
    var work: IdleWork?

    /// "2 tabs · Claude, Codex".
    var summary: String {
        var parts = [Recap.count(tabs.count, "tab")]
        let agents = (tabs.compactMap { $0.agent?.agent } + conversations.map(\.engine))
            .map { AgentBrand.forAgent($0)?.displayName ?? $0 }
        var seen = Set<String>()
        let unique = agents.filter { seen.insert($0).inserted }
        if !unique.isEmpty { parts.append(unique.joined(separator: ", ")) }
        if let risks = work?.summary { parts.append(risks) }
        return parts.joined(separator: " · ")
    }
}

enum WorkspaceSleep {
    /// Writes down a workspace before it sleeps. `records` are the agents
    /// Octet has journaled (with their session ids), by terminal.
    static func capture(
        _ workspace: EngineWorkspace,
        snapshot: EngineSnapshot,
        records: [String: AgentSessionRecord],
        conversations: [SleepingWorkspace.Conversation],
        branch: String?,
        project: String?,
        lastActive: Date?,
        work: IdleWork?,
        now: Date = Date()
    ) -> SleepingWorkspace {
        let id = workspace.workspaceId
        let cwd = snapshot.directory(ofWorkspace: id) ?? NSHomeDirectory()
        let tabs = snapshot.tabs(inWorkspace: id).map { tab -> SleepingWorkspace.Tab in
            let panes = snapshot.panes.filter { $0.tabId == tab.tabId }
            let agent = snapshot.agents.first { $0.tabId == tab.tabId && !$0.isSubagentViewer }
            let record = agent?.terminalId.flatMap { records[$0] }.flatMap { $0.resumeCommand == nil ? nil : $0 }
            return SleepingWorkspace.Tab(label: tab.label, cwd: panes.first?.effectiveCwd ?? cwd, agent: record)
        }
        return SleepingWorkspace(label: workspace.label, cwd: cwd, branch: branch, project: project, sleptAt: now,
                                 lastActive: lastActive, tabs: tabs.isEmpty ? [.init(label: workspace.label, cwd: cwd)] : tabs,
                                 conversations: conversations, work: work)
    }

    /// Why a workspace can't go to sleep by itself, or nil when it can: it
    /// would end something. An agent still working or asking, a program
    /// running in a pane (`busyPanes`, read from each pane's process), a
    /// server listening, or one pinned or on screen. Work on disk is safe.
    static func reasonToStayAwake(
        _ workspace: EngineWorkspace,
        snapshot: EngineSnapshot,
        busyPanes: Set<String>,
        ports: [Int],
        pinned: Bool,
        shown: Bool
    ) -> String? {
        let id = workspace.workspaceId
        if pinned { return "It's pinned." }
        if shown || id == snapshot.focusedWorkspaceId { return "It's on screen." }
        let agents = snapshot.agents(inWorkspace: id)
        if agents.contains(where: { $0.agentStatus == .working }) || workspace.agentStatus == .working { return "An agent is working." }
        if agents.contains(where: { $0.agentStatus == .blocked }) || workspace.agentStatus == .blocked { return "An agent is waiting on you." }
        if !ports.isEmpty { return "A server is listening on :\(ports[0])." }
        // A pane with an agent in it is resumed on waking; any other busy
        // pane would lose what it's running.
        let agentPanes = Set(agents.map(\.paneId))
        if snapshot.panes.contains(where: { $0.workspaceId == id && busyPanes.contains($0.paneId) && !agentPanes.contains($0.paneId) }) {
            return "Something is running in a terminal."
        }
        return nil
    }

    /// Whether it has been idle long enough to sleep by itself. Zero days is never.
    static func isDue(lastActive: Date?, afterDays days: Int, now: Date = Date()) -> Bool {
        guard days > 0, let lastActive else { return false }
        return now.timeIntervalSince(lastActive) >= Double(days) * 86_400
    }
}

/// On disk: `sleeping-workspaces.json` in Octet's support folder.
struct SleepingWorkspacesFile: Codable, Equatable {
    var workspaces: [SleepingWorkspace] = []

    static func load(from url: URL) -> SleepingWorkspacesFile {
        guard let data = try? Data(contentsOf: url) else { return SleepingWorkspacesFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SleepingWorkspacesFile.self, from: data)) ?? SleepingWorkspacesFile()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
