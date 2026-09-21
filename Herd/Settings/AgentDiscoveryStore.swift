import Foundation

/// The agents found on this machine, kept so the list is there the moment
/// Settings opens. A scan runs every CLI it finds for its version, which
/// takes a second or two, so it happens off the main thread and its result
/// is remembered until asked to look again.
@MainActor
final class AgentDiscoveryStore: ObservableObject {
    static let shared = AgentDiscoveryStore()

    @Published private(set) var agents: [DiscoveredAgent] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?

    private static let agentsKey = "herd.discovery.agents.v1"
    private static let scannedKey = "herd.discovery.scannedAt.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.agentsKey),
           let saved = try? JSONDecoder().decode([DiscoveredAgent].self, from: data) {
            agents = saved
        }
        scannedAt = UserDefaults.standard.object(forKey: Self.scannedKey) as? Date
    }

    /// Scans once at launch, and whenever a day has passed since the last
    /// one: agents are installed and updated rarely.
    func scanIfStale(after interval: TimeInterval = 86400) {
        guard let scannedAt else { return scan() }
        if Date().timeIntervalSince(scannedAt) > interval { scan() }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = AgentDiscovery.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentDiscoveryStore.shared.finish(found) }
            }
        }
    }

    private func finish(_ found: [DiscoveredAgent]) {
        scanning = false
        scannedAt = Date()
        UserDefaults.standard.set(scannedAt, forKey: Self.scannedKey)
        guard agents != found else { return }
        agents = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.agentsKey) }
    }
}
