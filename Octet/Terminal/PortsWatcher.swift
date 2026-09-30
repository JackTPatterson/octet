import AppKit

/// Which ports each pane's servers listen on, re-read every few seconds
/// while Octet is in front, for each workspace's ports in the sidebar.
@MainActor
final class PortsWatcher: ObservableObject {
    static let shared = PortsWatcher()

    @Published private(set) var byPane: [String: [Int]] = [:]
    /// What serves each port, as a `LanguageLogo` service slug.
    @Published private(set) var services: [Int: String] = [:]
    private var timer: Timer?
    private var reading = false
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
            let found = ListeningPorts.byPane(listeners, parents: parents, shells: shells)
            var services: [Int: String] = [:]
            for listener in listeners where services[listener.port] == nil {
                services[listener.port] = ServiceKind.detect(pid: listener.pid, command: listener.command,
                                                            processes: processes, parents: parents)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    if found != self.byPane { self.byPane = found }
                    if services != self.services { self.services = services }
                }
            }
        }
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
