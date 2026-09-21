import Foundation

/// Notices Octet raises when an agent stops working: it finished, or it is
/// waiting on you. Works off the status every agent reports, so no agent is
/// treated specially.
struct AgentEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case finished
        case needsInput

        var title: String { self == .finished ? "finished" : "needs you" }
    }

    let id: String
    let kind: Kind
    let agent: String?
    let paneId: String
    let tabId: String?
    let workspaceId: String?
    /// What the tab is called, for the banner's line of context.
    let label: String
    /// How long it worked before this, when Octet saw it start.
    let workedFor: TimeInterval?
    let at: Date
}

/// Watches agent statuses between snapshots and reports the transitions worth
/// interrupting someone for.
struct AgentActivityWatcher {
    /// Per pane: the last status seen, and when it started working.
    private var states: [String: (status: EngineAgentStatus, startedWorking: Date?)] = [:]
    /// Panes seen for the first time don't fire; their state is only recorded.
    private var primed = false

    init() {}

    /// Transitions since the previous snapshot. `isVisible` suppresses a
    /// notice for work you are already looking at.
    mutating func events(
        in snapshot: EngineSnapshot,
        now: Date = Date(),
        isVisible: (EngineAgent) -> Bool = { _ in false }
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var next: [String: (status: EngineAgentStatus, startedWorking: Date?)] = [:]
        let labels = Dictionary(snapshot.tabs.map { ($0.tabId, $0.label) }, uniquingKeysWith: { first, _ in first })

        for agent in snapshot.agents {
            let previous = states[agent.paneId]
            let wasWorking = previous?.status == .working
            let startedWorking = agent.agentStatus == .working
                ? (wasWorking ? previous?.startedWorking : now) ?? now
                : nil
            next[agent.paneId] = (agent.agentStatus, startedWorking)

            guard primed, let previous, previous.status != agent.agentStatus else { continue }
            guard let kind = kind(from: previous.status, to: agent.agentStatus) else { continue }
            guard !isVisible(agent) else { continue }
            let label = agent.tabId.flatMap { labels[$0] } ?? ""
            events.append(AgentEvent(
                id: "\(agent.paneId)-\(agent.stateChangeSeq ?? 0)-\(kind == .finished ? "done" : "input")",
                kind: kind,
                agent: agent.agent,
                paneId: agent.paneId,
                tabId: agent.tabId,
                workspaceId: agent.workspaceId,
                label: TabAutoName.isUnnamed(label) ? (AgentBrand.forAgent(agent.agent)?.displayName ?? "Agent") : label,
                workedFor: previous.status == .working ? previous.startedWorking.map { now.timeIntervalSince($0) } : nil,
                at: now
            ))
        }
        states = next
        primed = true
        return events
    }

    /// Only a transition out of work is worth a notice: everything else is
    /// either noise or something the user just did.
    private func kind(from previous: EngineAgentStatus, to current: EngineAgentStatus) -> AgentEvent.Kind? {
        switch (previous, current) {
        case (.working, .done), (.working, .idle): .finished
        case (.working, .blocked), (.idle, .blocked), (.done, .blocked): .needsInput
        default: nil
        }
    }

    /// `2m 14s`, or nil when Octet didn't see the work start.
    static func durationLabel(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds >= 1 else { return nil }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return whole % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(whole % 60)s" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    }
}
