import AppKit
import CoreImage.CIFilterBuiltins
import IOKit.ps
import Foundation

/// The Octet phone app's host: listens on this Mac while Settings › Phone is
/// on, pairs phones with a one-time code, and keeps the list of paired phones.
@MainActor
final class PhoneHostCenter: ObservableObject {
    static let shared = PhoneHostCenter()

    private static let enabledKey = "octet.phoneHost.enabled"
    private static let environmentKey = "octet.phoneHost.environmentId"

    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var error: String?
    @Published private(set) var pairing: PhoneAuthStore.Pairing?
    @Published private(set) var phones: [PhoneAuthStore.Session] = []

    private var server: PhoneHostServer?
    private var backend: OctetPhoneBackend?
    private var auth: PhoneAuthStore?
    private weak var store: SessionStore?
    private var timer: Timer?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            apply()
        }
    }

    var machineName: String { PeerCenter.shared.machineName }

    // MARK: - Lifecycle

    /// Follows the setting: on starts listening, off stops and forgets the pairing code.
    func apply(store: SessionStore? = nil) {
        if let store { self.store = store }
        var wanted = enabled
        #if DEBUG
        // Testing: a launch can turn the host on without touching the setting.
        if ProcessInfo.processInfo.environment["OCTET_PHONE_HOST"] != nil { wanted = true }
        #endif
        if wanted, server == nil { start() } else if !wanted, server != nil { stop() }
    }

    private func start() {
        guard let store else { return }
        let auth = PhoneAuthStore(url: EngineSession.supportDirectory.appendingPathComponent("phone-host.json"))
        let backend = OctetPhoneBackend()
        backend.start(store: store, machineName: machineName)
        let router = PhoneHostRouter(
            config: PhoneHostConfig(environmentID: environmentID, label: machineName,
                                    serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                                    machine: Self.machineKind),
            auth: auth)
        let server = PhoneHostServer(router: router, backend: backend)
        do {
            // The usual port when it is free, any other when not.
            do { try server.start(port: PhoneHostServer.defaultPort) } catch { try server.start(port: nil) }
        } catch {
            self.error = "Octet couldn't start listening for phones."
            backend.stop()
            return
        }
        self.auth = auth
        self.backend = backend
        self.server = server
        port = server.port
        error = nil
        running = true
        phones = auth.allSessions()
        #if DEBUG
        // Testing: write "<port> <code>" where the test asked, so a script can pair.
        if let path = ProcessInfo.processInfo.environment["OCTET_PHONE_CODE_FILE"] {
            let code = auth.createPairing(label: "test").credential
            try? "\(server.port ?? 0) \(code)".write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
        #if DEBUG
        // Testing: a sample conversation with a pending permission, so the phone has something to read.
        if ProcessInfo.processInfo.environment["OCTET_PHONE_SAMPLE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    guard let workspace = PhoneHostCenter.shared.store?.snapshot.workspaces.first?.workspaceId else { return }
                    let session = AgentCenter.shared.newConversation(workspaceId: workspace, cwd: NSHomeDirectory(), start: false)
                    session.debugLoadEverything()
                    session.debugShowPermission()
                }
            }
        }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { PhoneHostCenter.shared.poll() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        backend?.stop()
        server = nil
        backend = nil
        auth = nil
        running = false
        port = nil
        pairing = nil
    }

    /// Watches for the phone that used the code.
    private func poll() {
        guard let auth else { return }
        let sessions = auth.allSessions()
        if sessions != phones {
            if sessions.count > phones.count { pairing = nil }
            phones = sessions
        }
        if let pairing, pairing.expiresAt < Date() { self.pairing = nil }
    }

    // MARK: - Pairing

    func newPairing() {
        pairing = auth?.createPairing(label: nil)
    }

    func cancelPairing() { pairing = nil }

    func revoke(_ session: PhoneAuthStore.Session) {
        auth?.revoke(sessionID: session.id)
        server?.disconnect(sessionID: session.id)
        phones = auth?.allSessions() ?? []
    }

    func revokeAll() {
        let all = phones
        auth?.revokeAll()
        all.forEach { server?.disconnect(sessionID: $0.id) }
        phones = []
    }

    // MARK: - Addresses

    /// A name for this host that stays the same between launches.
    private var environmentID: String {
        if let id = UserDefaults.standard.string(forKey: Self.environmentKey) { return id }
        let id = "octet-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: Self.environmentKey)
        return id
    }

    /// T3's machine kinds: a Mac with a battery is a laptop.
    private static var machineKind: String {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], !sources.isEmpty {
            return "laptop"
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes).hasPrefix("Macmini") ? "mac-mini" : "desktop"
    }

    /// Where a phone could reach this Mac: Wi-Fi first, then Tailscale, then others.
    struct Address: Identifiable, Equatable {
        let label: String
        let host: String
        var id: String { host }
    }

    var addresses: [Address] { Self.localAddresses() }

    /// What the QR code and "Copy link" carry: the host's address with the code.
    func pairingLink(host: String) -> String? {
        guard let pairing, let port else { return nil }
        return "http://\(host):\(port)/#token=\(pairing.credential)"
    }

    static func localAddresses() -> [Address] {
        var found: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  Int32(entry.ifa_flags) & IFF_UP != 0, Int32(entry.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: entry.ifa_name)
            if ip.hasPrefix("169.254.") { continue }
            let label = ip.hasPrefix("100.") ? "Tailscale" : name == "en0" ? "Wi-Fi" : name
            found.append(Address(label: label, host: ip))
        }
        let order = ["Wi-Fi": 0, "Tailscale": 1]
        return found.sorted { (order[$0.label] ?? 2) < (order[$1.label] ?? 2) }
    }

    /// A black-on-white QR code for `text`, drawn crisp.
    static func qrImage(_ text: String, size: CGFloat = 176) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}
