import Foundation

/// Prompts waiting for an agent to finish its turn: typed now, sent the
/// moment the agent is idle or done, one per turn, in order.
struct PromptQueue: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let paneId: String
        let text: String
        let queuedAt: Date

        init(paneId: String, text: String, id: UUID = UUID(), queuedAt: Date = Date()) {
            self.id = id
            self.paneId = paneId
            self.text = text
            self.queuedAt = queuedAt
        }
    }

    private(set) var items: [Item] = []

    mutating func add(_ item: Item) { items.append(item) }
    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func items(for paneId: String) -> [Item] { items.filter { $0.paneId == paneId } }

    /// What to send now: for each pane whose agent has finished (idle or
    /// done), its oldest prompt. Prompts for panes that are gone are dropped
    /// and returned apart, to say so.
    mutating func due(statuses: [String: EngineAgentStatus]) -> (send: [Item], dropped: [Item]) {
        var send: [Item] = [], dropped: [Item] = [], served = Set<String>()
        for item in items {
            guard let status = statuses[item.paneId] else {
                dropped.append(item)
                continue
            }
            if (status == .idle || status == .done), !served.contains(item.paneId) {
                send.append(item)
                served.insert(item.paneId)
            }
        }
        let gone = Set((send + dropped).map(\.id))
        items.removeAll { gone.contains($0.id) }
        return (send, dropped)
    }
}
