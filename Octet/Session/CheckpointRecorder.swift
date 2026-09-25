import Foundation

/// Takes a checkpoint of an agent's working tree each time it starts a turn
/// (its state goes to working), so the turn can be undone from the palette.
@MainActor
final class CheckpointRecorder {
    static let shared = CheckpointRecorder()

    private var statuses: [String: EngineAgentStatus] = [:]
    private var lastTaken: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.jpxsoftware.octet.checkpoints", qos: .utility)

    /// The whole snapshot, so agents in closed tabs are followed too.
    func observe(_ snapshot: EngineSnapshot) {
        var seen: [String: EngineAgentStatus] = [:]
        for agent in snapshot.agents where agent.agent != nil && !agent.isSubagentViewer {
            seen[agent.paneId] = agent.agentStatus
            let before = statuses[agent.paneId]
            // A turn starts when it goes to working from anything else it was
            // seen as; the first sighting doesn't count, it may be mid-turn.
            guard agent.agentStatus == .working, let before, before != .working,
                  let cwd = agent.reportedCwd ?? agent.effectiveCwd else { continue }
            let brand = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
            let tab = agent.tabId.flatMap { id in snapshot.tabs.first { $0.tabId == id } }
                .map { TabAutoName.display(label: $0.label, number: $0.number) }
            record(cwd: cwd, label: [brand, tab].compactMap { $0 }.joined(separator: " · "))
        }
        statuses = seen
    }

    private func record(cwd: String, label: String) {
        guard SettingsStore.shared.values.checkpointTurns else { return }
        // Several agents starting together in one tree need one snapshot.
        if let last = lastTaken[cwd], Date().timeIntervalSince(last) < 3 { return }
        lastTaken[cwd] = Date()
        queue.async { Checkpoints.create(in: cwd, label: label) }
    }
}
