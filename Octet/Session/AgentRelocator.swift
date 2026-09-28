import Foundation

/// Settings › Agents › "Move agents to the project they work in" (off by
/// default). An agent asked for work in one project while launched in
/// another spends every command `cd`ing across; once its last few commands
/// all went to the same other repository, it is restarted there between
/// turns, in its own tab, with its conversation resumed. A running agent's
/// folder can't be changed from outside, so restarting it is the only move.
@MainActor
final class AgentRelocator {
    static let shared = AgentRelocator()
    /// What each agent was doing at the last snapshot: a turn ending is
    /// when its commands are read.
    private var lastStatus: [String: EngineAgentStatus] = [:]
    /// Moves made or refused, by terminal and destination, so none repeats.
    private var handled: Set<String> = []
    private var checking: Set<String> = []

    func observe(_ snapshot: EngineSnapshot, store: SessionStore) {
        defer { lastStatus = Dictionary(snapshot.agents.compactMap { agent in agent.terminalId.map { ($0, agent.agentStatus) } },
                                        uniquingKeysWith: { first, _ in first }) }
        guard SettingsStore.shared.values.relocateAgents else { return }
        for (agent, record) in store.recovery.reloadableAgents() {
            guard let terminal = agent.terminalId, let sessionId = record.sessionId,
                  lastStatus[terminal] == .working, agent.agentStatus == .done || agent.agentStatus == .idle,
                  let brand = AgentBrand.forAgent(agent.agent)?.id, brand == "claude" || brand == "codex",
                  checking.insert(terminal).inserted else { continue }
            let launch = record.cwd
            DispatchQueue.global(qos: .utility).async {
                let transcript = brand == "claude"
                    ? ClaudeTranscriptActivity.projectDirectory(forCwd: launch) + "/\(sessionId).jsonl"
                    : AgentSessionFiles.codexPath(forSession: sessionId)
                let lines = transcript.map { CodexThreads.tail(path: $0) } ?? []
                let destination = AgentDrift.destination(
                    targets: AgentDrift.targets(transcript: lines, base: launch),
                    launchCwd: launch,
                    gitRoot: { GitBranch.location(for: $0)?.root })
                DispatchQueue.main.async {
                    self.checking.remove(terminal)
                    guard let destination, self.handled.insert(terminal + "\u{0}" + destination).inserted else { return }
                    self.move(agent, record, to: destination, transcript: brand == "claude" ? transcript : nil, store: store)
                }
            }
        }
    }

    private func move(_ agent: EngineAgent, _ record: AgentSessionRecord, to destination: String,
                      transcript: String?, store: SessionStore) {
        // Still between turns, and still the same agent in the same tab.
        guard let current = store.snapshot.agents.first(where: { $0.terminalId == agent.terminalId }),
              current.agentStatus == .done || current.agentStatus == .idle,
              current.tabId == agent.tabId else { return }
        let name = AgentRecoveryController.displayName(record)
        let place = (destination as NSString).lastPathComponent
        let client = store.client
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var moved = record
        moved.cwd = destination
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Claude looks for a conversation under the folder it's
                // started in, so the transcript goes there first. Codex finds
                // its sessions by id from anywhere.
                if let transcript, let sessionId = record.sessionId {
                    let folder = ClaudeTranscriptActivity.projectDirectory(forCwd: destination)
                    let copy = folder + "/\(sessionId).jsonl"
                    let files = FileManager.default
                    if !files.fileExists(atPath: copy) {
                        try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        try files.copyItem(atPath: transcript, toPath: copy)
                    }
                }
                try client.call("layout.apply", AgentRecovery.resumeRequest(
                    moved, shell: shell, workspaceId: agent.workspaceId, tabId: agent.tabId))
                DispatchQueue.main.async {
                    ToastCenter.shared.info("Moved \(name) to \(place)",
                                            detail: "Its last commands all ran in \(abbreviateHome(destination)), so it was restarted there with its conversation.",
                                            after: 8)
                }
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't move \(name) to \(place)", detail: String(describing: error))
                }
            }
        }
    }
}
