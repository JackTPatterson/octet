import Foundation

/// What a terminal is busy with as it's about to close: an agent, or a
/// command other than the shell. An idle prompt has nothing to lose and
/// isn't listed at all.
struct ClosingWork: Equatable {
    /// The agent's name when one runs there ("Claude", "Codex").
    var agent: String?
    /// Whether that agent is in the middle of a turn, rather than waiting.
    var agentWorking = false
    /// The command line, for a program that isn't an agent.
    var command: String?

    /// The agent in `pane`, if one runs there. A subagent viewer only
    /// watches another agent's work, so closing it stops nothing.
    static func agent(in pane: EnginePane, agents: [EngineAgent]) -> ClosingWork? {
        guard let agent = agents.first(where: { $0.paneId == pane.paneId && !$0.isSubagentViewer }),
              agent.agent != nil || agent.displayAgent != nil else { return nil }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.displayAgent ?? agent.agent ?? "Agent"
        return ClosingWork(agent: name, agentWorking: [.working, .blocked].contains(agent.agentStatus))
    }
}

/// The question to ask before closing a tab, pane or terminal that's
/// running something, worded for what it would stop. Idle shells close
/// without one.
struct ClosePrompt: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
    /// One row per thing that would stop, when there's more than one.
    var items: [String] = []

    /// `place` names what's closing, as in "in this tab".
    static func question(for work: [ClosingWork], place: String) -> ClosePrompt? {
        guard !work.isEmpty else { return nil }
        let agents = work.compactMap(\.agent)
        let rows = work.compactMap { $0.agent ?? $0.command.map { ShellRecovery.short($0) } }
        if agents.count == 1, work.count == 1, let only = work.first {
            let what = only.agentWorking ? "Closing will stop its current work." : "Closing will end its session."
            return ClosePrompt(title: "Stop this agent?",
                               message: "\(agents[0]) is running in this \(place). \(what)",
                               confirmTitle: "Stop Agent")
        }
        if !agents.isEmpty {
            return ClosePrompt(title: work.count == agents.count ? "Stop \(agents.count) agents?" : "Stop the agents and commands?",
                               message: "Closing this \(place) will stop their current work.",
                               confirmTitle: "Stop and Close", items: rows)
        }
        if work.count == 1, let command = work.first?.command {
            return ClosePrompt(title: "Stop running command?",
                               message: "\(ShellRecovery.short(command)) is still running in this \(place). Closing will stop it.",
                               confirmTitle: "Stop and Close")
        }
        return ClosePrompt(title: "Stop \(work.count) running commands?",
                           message: "They're still running in this \(place). Closing will stop them.",
                           confirmTitle: "Stop and Close", items: rows)
    }
}
