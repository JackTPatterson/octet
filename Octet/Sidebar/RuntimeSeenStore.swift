import Foundation

/// The Agents tab's read and dismissed rows (`RuntimeSeen`), kept across
/// launches, shared by every window so a row read in one is read in all.
@MainActor
final class RuntimeSeenStore: ObservableObject {
    static let shared = RuntimeSeenStore()
    private static let key = "octet.agentsTab.seen"

    @Published private(set) var state: RuntimeSeen {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(RuntimeSeen.self, from: data) {
            state = saved
        } else {
            state = RuntimeSeen()
        }
    }

    func isUnread(_ entry: RuntimeEntry) -> Bool {
        entry.kind != .shell && state.isUnread(id: entry.id, state: entry.state)
    }

    func isDismissed(_ entry: RuntimeEntry) -> Bool { state.isDismissed(entry.id) }

    /// Marks read only what isn't already, so nothing republishes for nothing.
    func markRead(_ entries: [RuntimeEntry]) {
        let ids = entries.filter(isUnread).map(\.id)
        guard !ids.isEmpty else { return }
        state.markRead(ids)
    }

    func markUnread(_ entry: RuntimeEntry) { state.markUnread(entry.id) }

    func dismiss(_ entries: [RuntimeEntry]) { state.dismiss(entries.map(\.id)) }

    func restore(_ ids: [String]) { state.restore(ids) }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
