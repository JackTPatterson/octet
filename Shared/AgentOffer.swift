import Foundation

/// Which agent a command line starts on its own, for the setting that opens
/// it in Octet's conversation view instead of the terminal.
enum AgentLaunch {
    /// Agents Octet can converse with itself, by the command that starts each.
    static let commands: Set<String> = ["claude", "codex", "opencode", "pi", "qwen"]

    /// The agent when `line` is only that command, typed bare. Anything after
    /// it (a flag, a prompt, a pipe) is a request for something specific, and
    /// runs in the terminal as typed.
    static func agent(inCommandLine line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        return commands.contains(text) ? text : nil
    }
}

/// The banner over the terminal that offers an agent running in its own
/// interface to Octet's conversation view.
enum AgentOffer {
    /// The agent's id when Octet can converse
    /// with it, else nil.
    static func agentId(_ agent: EngineAgent) -> String? {
        AgentBrand.forAgent(agent.agent).map(\.id).flatMap { AgentLaunch.commands.contains($0) ? $0 : nil }
    }

    /// Identifies one agent in one pane, so dismissing its banner doesn't
    /// dismiss another's.
    static func key(_ agent: EngineAgent) -> String {
        "\(agent.paneId)|\(agentId(agent) ?? agent.agent ?? "")"
    }

    /// The agent to offer: the first Octet can converse with whose banner
    /// hasn't been dismissed.
    static func candidate(in agents: [EngineAgent], dismissed: Set<String>) -> EngineAgent? {
        agents.first { agentId($0) != nil && !dismissed.contains(key($0)) }
    }

    /// Dismissals that still apply: an agent that has exited is forgotten, so
    /// the next one launched in that pane gets its banner.
    static func remaining(_ dismissed: Set<String>, agents: [EngineAgent]) -> Set<String> {
        dismissed.intersection(Set(agents.map(key)))
    }
}
