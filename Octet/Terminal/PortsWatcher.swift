import AppKit

/// Which ports each pane's servers listen on, re-read every few seconds
/// while Octet is in front, for each workspace's ports in the sidebar.
@MainActor
final class PortsWatcher: ObservableObject {
    static let shared = PortsWatcher()

    @Published private(set) var byPane: [String: [Int]] = [:]
    /// What serves each port, as a `LanguageLogo` service slug.
    @Published private(set) var services: [Int: String] = [:]
    /// The processes listening on each port shown, for stopping them.
    @Published private(set) var listeners: [Int: [ListeningPorts.Listener]] = [:]
    private var timer: Timer?
    private var reading = false
    /// Whether each server serves a page, by "pid:port", once known; ports
    /// that don't aren't shown, as opening them shows nothing.
    private var pages: [String: Bool] = [:]
    /// Probes a server didn't answer, so one that never does isn't asked forever.
    private var unanswered: [String: Int] = [:]
    private var ticks = 0
    private weak var store: SessionStore?

    func start(store: SessionStore) {
        self.store = store
        guard timer == nil else { return }
        read()
        // Every 5 s while Octet is in front, every 30 s behind other apps.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                if NSApp.isActive || self.ticks % 6 == 0 { self.read() }
            }
        }
    }

    /// Ports in a workspace, from every pane in it.
    func ports(inWorkspace workspaceId: String, snapshot: EngineSnapshot) -> [Int] {
        let panes = snapshot.panes.filter { $0.workspaceId == workspaceId }.map(\.paneId)
        return Array(Set(panes.flatMap { byPane[$0] ?? [] })).sorted()
    }

    /// The logo of the first port in a workspace that has one.
    func service(inWorkspace workspaceId: String, snapshot: EngineSnapshot) -> String? {
        ports(inWorkspace: workspaceId, snapshot: snapshot).lazy.compactMap { self.services[$0] }.first
    }

    private func read() {
        guard !reading, let store else { return }
        reading = true
        let client = store.client
        let panes = store.snapshot.panes.map(\.paneId)
        let known = pages
        let unanswered = self.unanswered
        DispatchQueue.global(qos: .utility).async {
            var shells: [String: Int] = [:]
            for pane in panes {
                if let pid = (try? client.call("pane.process_info", ["pane_id": pane])).flatMap(ShellPrompt.parse)?.shellPid {
                    shells[pane] = pid
                }
            }
            let listeners = ListeningPorts.parseLsof(Self.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]))
            let table = Self.output("/bin/ps", ["-axww", "-o", "pid=,ppid=,args="])
            let parents = ListeningPorts.parseParents(table)
            let processes = ServiceKind.parseArguments(table)
            let owned = ListeningPorts.owned(listeners, parents: parents, shells: shells).map(\.0)
            // Ask each server once whether it serves a page; one still
            // thinking is shown meanwhile and asked again next time, and
            // one that never answers stays shown, as it was before.
            var pages: [String: Bool] = [:]
            var stillUnanswered: [String: Int] = [:]
            for listener in owned {
                let key = "\(listener.pid):\(listener.port)"
                if let page = known[key] ?? pages[key] { pages[key] = page; continue }
                switch Self.probe(port: listener.port) {
                case .page: pages[key] = true
                case .notPage: pages[key] = false
                case .noAnswer:
                    let tries = (unanswered[key] ?? 0) + 1
                    if tries >= 3 { pages[key] = true } else { stillUnanswered[key] = tries }
                }
            }
            let shown = listeners.filter { pages["\($0.pid):\($0.port)"] ?? true }
            let found = ListeningPorts.byPane(shown, parents: parents, shells: shells)
            var services: [Int: String] = [:]
            let owners = Dictionary(grouping: owned, by: \.port)
            for listener in listeners where services[listener.port] == nil {
                services[listener.port] = ServiceKind.detect(pid: listener.pid, command: listener.command,
                                                            processes: processes, parents: parents)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    self.pages = pages
                    self.unanswered = stillUnanswered
                    if found != self.byPane { self.byPane = found }
                    if services != self.services { self.services = services }
                    if owners != self.listeners { self.listeners = owners }
                }
            }
        }
    }

    /// Stops what listens on `port`: asks it to quit, or with `force`
    /// ends it at once. Only processes found under a pane's shell are ever
    /// signalled, the ones whose port the sidebar shows.
    func stop(port: Int, force: Bool = false) {
        let owners = listeners[port] ?? []
        guard !owners.isEmpty else {
            ToastCenter.shared.info("Nothing is listening on :\(port) now")
            read()
            return
        }
        var refused: [String] = []
        for owner in owners where Darwin.kill(pid_t(owner.pid), force ? SIGKILL : SIGTERM) != 0 && errno != ESRCH {
            refused.append("\(owner.command) (\(owner.pid))")
        }
        if !refused.isEmpty {
            ToastCenter.shared.fail(nil, "Couldn't stop :\(port)", detail: refused.joined(separator: ", ") + " didn't allow it.")
        }
        // Read again once it has had a moment to go, and later for one that
        // takes its time shutting down.
        for delay in [0.8, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.read() }
        }
    }

    /// Asks a local server for `/` over plain TCP, on IPv4 then IPv6, as
    /// servers often listen on only one.
    nonisolated private static func probe(port: Int) -> ListeningPorts.Probe {
        for host in ["127.0.0.1", "::1"] {
            if let answer = probe(host: host, port: port) { return answer }
        }
        return .notPage
    }

    /// Nil when nothing could be reached there.
    nonisolated private static func probe(host: String, port: Int) -> ListeningPorts.Probe? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let address = info else { return nil }
        defer { freeaddrinfo(info) }
        let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else { return nil }
        let request = "GET / HTTP/1.0\r\nHost: localhost:\(port)\r\nAccept: text/html\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else { return .notPage }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .noAnswer }
        guard count > 0 else { return .notPage }
        return ListeningPorts.probe(response: String(decoding: buffer[..<count], as: UTF8.self))
    }

    nonisolated private static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return String(decoding: data, as: UTF8.self)
    }
}
