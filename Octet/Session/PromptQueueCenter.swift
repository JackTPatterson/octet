import Foundation

/// Sends queued prompts as their agents finish; see `PromptQueue`.
@MainActor
final class PromptQueueCenter: ObservableObject {
    static let shared = PromptQueueCenter()

    @Published private(set) var queue = PromptQueue()
    private weak var store: SessionStore?

    func add(_ text: String, for agent: EngineAgent, name: String, store: SessionStore) {
        self.store = store
        queue.add(.init(paneId: agent.paneId, text: text))
        let waiting = queue.items(for: agent.paneId).count
        ToastCenter.shared.info(waiting == 1 ? "Queued for \(name)" : "Queued for \(name), \(waiting) waiting",
                                detail: "Sent when it finishes its turn.")
        observe(store.snapshot)
    }

    func cancel(_ id: UUID) { queue.remove(id) }

    /// The visible snapshot, on every refresh.
    func observe(_ snapshot: EngineSnapshot) {
        guard !queue.items.isEmpty, let store else { return }
        var statuses: [String: EngineAgentStatus] = [:]
        for agent in snapshot.agents where agent.agent != nil { statuses[agent.paneId] = agent.agentStatus }
        let due = queue.due(statuses: statuses)
        for item in due.send {
            store.broadcast(item.text, to: [Broadcast.Target(paneId: item.paneId, name: "the queued prompt", isAgent: true)])
        }
        if !due.dropped.isEmpty {
            ToastCenter.shared.info("Dropped \(due.dropped.count) queued \(due.dropped.count == 1 ? "prompt" : "prompts")",
                                    detail: "Its agent isn't running any more.")
        }
    }
}
