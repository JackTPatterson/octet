import Foundation

/// Which running agents' banners were dismissed. Dismissing one silences it
/// for as long as that agent runs in that pane; a new agent gets its own
/// banner. "Don't show again" is a setting, not kept here.
@MainActor
final class AgentOfferCenter: ObservableObject {
    static let shared = AgentOfferCenter()

    @Published private(set) var dismissed: Set<String> = []

    func dismiss(_ agent: EngineAgent) {
        dismissed.insert(AgentOffer.key(agent))
    }

    /// Forgets dismissals for agents that have exited.
    func observe(_ snapshot: EngineSnapshot) {
        let kept = AgentOffer.remaining(dismissed, agents: snapshot.agents)
        if kept != dismissed { dismissed = kept }
    }
}
