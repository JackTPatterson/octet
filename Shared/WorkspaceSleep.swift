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
    /// Who put it to sleep, to say on its row.
    var cause: Cause = .manual

    enum Cause: Codable, Equatable {
        case manual
        /// By itself, unused for Settings' number of days.
        case automatic(afterDays: Int)
    }

    /// "Put to sleep by you", "Put to sleep by itself after 14 days unused".
    var causeText: String {
        switch cause {
        case .manual: "Put to sleep by you"
        case .automatic(let days): "Put to sleep by itself after \(Recap.count(days, "day")) unused"
        }
    }

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

extension SleepingWorkspace {
    // Fields with a default may be missing (written by an older build), so
    // adding one doesn't cost the entries already on disk.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try container.decode(String.self, forKey: .label)
        cwd = try container.decode(String.self, forKey: .cwd)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        sleptAt = try container.decode(Date.self, forKey: .sleptAt)
        lastActive = try container.decodeIfPresent(Date.self, forKey: .lastActive)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        conversations = try container.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        // A note on what it held isn't worth the workspace.
        work = (try? container.decodeIfPresent(IdleWork.self, forKey: .work)) ?? nil
        // A cause this build doesn't know reads as by hand.
        cause = (try? container.decodeIfPresent(Cause.self, forKey: .cause)) ?? .manual
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
            let agent = agents(inTab: tab.tabId, snapshot: snapshot).first
            return SleepingWorkspace.Tab(label: tab.label, cwd: panes.first?.effectiveCwd ?? cwd,
                                         agent: agent.flatMap { resumable($0, records: records) })
        }
        return SleepingWorkspace(label: workspace.label, cwd: cwd, branch: branch, project: project, sleptAt: now,
                                 lastActive: lastActive, tabs: tabs.isEmpty ? [.init(label: workspace.label, cwd: cwd)] : tabs,
                                 conversations: conversations, work: work)
    }

    /// The agents a tab's sleep note can hold: the first is the one resumed.
    private static func agents(inTab tabId: String, snapshot: EngineSnapshot) -> [EngineAgent] {
        snapshot.agents.filter { $0.tabId == tabId && !$0.isSubagentViewer }
    }

    /// The agent's journaled session, when its own `--resume` can bring it back.
    private static func resumable(_ agent: EngineAgent, records: [String: AgentSessionRecord]) -> AgentSessionRecord? {
        agent.terminalId.flatMap { records[$0] }.flatMap { $0.resumeCommand == nil ? nil : $0 }
    }

    /// Why a workspace can't go to sleep by itself, or nil when it can: it
    /// would end something. An agent still working or asking (in a
    /// terminal, or one of Octet's `conversations`), a program running in a
    /// pane (`busyPanes`, read from each pane's process), something an
    /// agent started running behind it (`agentJobs`, by pane), a server
    /// listening, an agent that couldn't be resumed (`records` are the
    /// journaled ones, by terminal), or one pinned or on screen. Work on
    /// disk is safe.
    static func reasonToStayAwake(
        _ workspace: EngineWorkspace,
        snapshot: EngineSnapshot,
        busyPanes: Set<String>,
        agentJobs: Set<String> = [],
        records: [String: AgentSessionRecord],
        conversations: ConversationActivity = .init(),
        ports: [Int],
        pinned: Bool,
        shown: Bool
    ) -> String? {
        let id = workspace.workspaceId
        if pinned { return "It's pinned." }
        if shown || id == snapshot.focusedWorkspaceId { return "It's on screen." }
        let agents = snapshot.agents(inWorkspace: id)
        if agents.contains(where: { $0.agentStatus == .working }) || workspace.agentStatus == .working
            || conversations.working.contains(id) { return "An agent is working." }
        if agents.contains(where: { $0.agentStatus == .blocked }) || workspace.agentStatus == .blocked
            || conversations.blocked.contains(id) { return "An agent is waiting on you." }
        if !ports.isEmpty { return "A server is listening on :\(ports[0])." }
        // A pane with an agent in it is resumed on waking, but not what the
        // agent left running in the background; any other busy pane would
        // lose what it's running.
        let agentPanes = Set(agents.map(\.paneId))
        if agentPanes.contains(where: agentJobs.contains) { return "An agent has something running in the background." }
        if snapshot.panes.contains(where: { $0.workspaceId == id && busyPanes.contains($0.paneId) && !agentPanes.contains($0.paneId) }) {
            return "Something is running in a terminal."
        }
        // Sleeping closes the terminal, and an agent with no session to
        // resume (or a second one in a tab) wouldn't come back.
        for tab in snapshot.tabs(inWorkspace: id) {
            let inTab = Self.agents(inTab: tab.tabId, snapshot: snapshot)
            if inTab.count > 1 || inTab.first.map({ resumable($0, records: records) == nil }) == true {
                return "An agent here can't be resumed."
            }
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
        if let file = try? decoder.decode(SleepingWorkspacesFile.self, from: data) { return file }
        // Some entry this build can't read: the rest still come back.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["workspaces"],
              let listData = try? JSONSerialization.data(withJSONObject: list) else {
            LossyList.keepAside(url)
            return SleepingWorkspacesFile()
        }
        return SleepingWorkspacesFile(workspaces: LossyList.decode(SleepingWorkspace.self, from: listData, file: url, decoder: decoder))
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
