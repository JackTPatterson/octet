import AppKit

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

    private static let agentsKey = "octet.discovery.agents.v1"
    private static let scannedKey = "octet.discovery.scannedAt.v1"
    private static let fingerprintKey = "octet.discovery.fingerprint.v1"
    /// How often coming back to the app may stat the bin folders again.
    static let changeCheckInterval: TimeInterval = 5 * 60

    /// What the last scan looked at, for the cheap change check.
    private var fingerprint: AgentDiscoveryFingerprint?
    private var lastChangeCheck: Date?
    private var activation: NSObjectProtocol?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.agentsKey),
           let saved = try? JSONDecoder().decode([DiscoveredAgent].self, from: data) {
            agents = saved
        }
        scannedAt = UserDefaults.standard.object(forKey: Self.scannedKey) as? Date
        if let data = UserDefaults.standard.data(forKey: Self.fingerprintKey) {
            fingerprint = try? JSONDecoder().decode(AgentDiscoveryFingerprint.self, from: data)
        }
    }

    /// Watches for CLIs installed, removed or updated since the last scan:
    /// once shortly after launch, then each time the app comes back to the
    /// front. Launch itself stays cheap; the full scan runs only on a change.
    func watchForChanges(firstCheckAfter delay: TimeInterval = 3) {
        guard activation == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { AgentDiscoveryStore.shared.checkForChanges() }
        }
        // An install usually happens in a terminal, then you switch back.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AgentDiscoveryStore.shared.checkForChanges() } }
    }

    /// Stats the folders and executables the last scan saw, off the main
    /// thread, and scans again if any differ. At most every few minutes.
    func checkForChanges(now: Date = Date()) {
        guard !scanning else { return }
        if let lastChangeCheck, now.timeIntervalSince(lastChangeCheck) < Self.changeCheckInterval { return }
        lastChangeCheck = now
        let recorded = fingerprint
        DispatchQueue.global(qos: .utility).async {
            let changed = AgentDiscoveryFingerprint.needsRescan(recorded: recorded, stamp: FileStamp.of)
            guard changed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentDiscoveryStore.shared.scan() }
            }
        }
    }

    /// Keeps the cached list for immediate UI, then scans once it's older
    /// than `interval` (by default, always).
    func scanIfStale(after interval: TimeInterval = 0) {
        guard let scannedAt else { return scan() }
        // A scan saved before `onShellPath` existed would make the splash type
        // full paths where a name would do, so it doesn't wait out the day.
        let predatesPathCheck = agents.contains { $0.executablePath != nil && $0.onShellPath == nil }
        if predatesPathCheck || Date().timeIntervalSince(scannedAt) > interval { scan() }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let (found, fingerprint) = AgentDiscovery.scanRecordingFingerprint()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentDiscoveryStore.shared.finish(found, fingerprint: fingerprint) }
            }
        }
    }

    private func finish(_ found: [DiscoveredAgent], fingerprint: AgentDiscoveryFingerprint?) {
        scanning = false
        scannedAt = Date()
        UserDefaults.standard.set(scannedAt, forKey: Self.scannedKey)
        // A scan just ran, so a check right behind it would find nothing new.
        lastChangeCheck = scannedAt
        self.fingerprint = fingerprint
        if let fingerprint, let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: Self.fingerprintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.fingerprintKey)
        }
        AgentUpdatePrompter.shared.check(found)
        guard agents != found else { return }
        agents = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.agentsKey) }
    }
}
