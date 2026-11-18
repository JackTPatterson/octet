import Foundation

/// Other Macs this one is signed in to, the way the Octet phone app is: each
/// is another Octet with Settings › Phone on, reached with the link or code it
/// shows. Their agents are listed here live, readable, and can be messaged,
/// stopped and answered from this Mac. Pair each Mac with the other and both
/// see both.
@MainActor
final class RemoteMacCenter: ObservableObject {
    static let shared = RemoteMacCenter()

    /// What's kept about a paired Mac; its token stays in the Keychain.
    struct Saved: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var host: String
        var port: Int
    }

    struct Machine: Identifiable, Equatable {
        var saved: Saved
        var state: PhoneHostConnectionState = .connecting
        var projects: [PhoneProject] = []
        var threads: [PhoneThread] = []
        var id: String { saved.id }

        var online: Bool { state == .online }
    }

    struct Selection: Equatable {
        var machine: String
        var thread: String
    }

    @Published private(set) var machines: [Machine] = []
    @Published private(set) var selection: Selection?
    @Published private(set) var items: [PhoneItem] = []
    @Published private(set) var approval: PhoneApproval?
    @Published private(set) var pairing = false
    @Published var notice: String?

    private var connections: [String: PhoneHostConnection] = [:]
    private var started = false
    private let url = EngineSession.supportDirectory.appendingPathComponent("remote-macs.json")

    private static func account(_ id: String) -> String { "octet.remote-mac.\(id)" }

    var machineName: String { PeerCenter.shared.machineName }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        for saved in load() {
            guard let token = CredentialKeychain.get(Self.account(saved.id)) else { continue }
            machines.append(Machine(saved: saved))
            connect(saved, token: token)
        }
    }

    private func load() -> [Saved] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }

    private func persist() {
        let data = try? JSONEncoder().encode(machines.map(\.saved))
        try? data?.write(to: url, options: .atomic)
    }

    private func connect(_ saved: Saved, token: String) {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = saved.host
        parts.port = saved.port
        guard let base = parts.url else { return }
        let connection = PhoneHostConnection(baseURL: base, token: token)
        let id = saved.id
        connection.onState = { state in
            Task { @MainActor in RemoteMacCenter.shared.update(id) { $0.state = state } }
        }
        connection.onShell = { projects, threads in
            Task { @MainActor in
                RemoteMacCenter.shared.update(id) { $0.projects = projects; $0.threads = threads }
                RemoteMacCenter.shared.clearSelectionIfGone(machine: id, threads: threads)
            }
        }
        connection.onThread = { thread, items, approval in
            Task { @MainActor in RemoteMacCenter.shared.received(machine: id, thread: thread, items: items, approval: approval) }
        }
        connections[id] = connection
        connection.start()
        if selection?.machine == id, let thread = selection?.thread { connection.watch(thread: thread) }
    }

    private func update(_ id: String, _ change: (inout Machine) -> Void) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        change(&machines[index])
    }

    private func received(machine: String, thread: String, items: [PhoneItem], approval: PhoneApproval?) {
        guard selection == Selection(machine: machine, thread: thread) else { return }
        self.items = items
        self.approval = approval
    }

    private func clearSelectionIfGone(machine: String, threads: [PhoneThread]) {
        if selection?.machine == machine, let thread = selection?.thread, !threads.contains(where: { $0.id == thread }) {
            close()
            notice = "That agent is gone from the other Mac."
        }
    }

    // MARK: - Pairing

    /// Pairs with the Mac the pasted link or "address code" names.
    func pair(_ text: String) async {
        notice = nil
        guard let link = PhoneHostLink.parse(text) else { return notice = PhoneHostClientError.invalidLink.message }
        pairing = true
        defer { pairing = false }
        do {
            let result = try await PhoneHostConnection.pair(link: link, label: machineName)
            var saved = Saved(id: result.environmentID, name: result.name, host: link.host, port: link.port)
            if let index = machines.firstIndex(where: { $0.id == saved.id }) {
                // Paired already: the new link is where it lives now.
                connections[saved.id]?.stop()
                connections[saved.id] = nil
                saved.name = result.name
                machines[index] = Machine(saved: saved)
            } else {
                machines.append(Machine(saved: saved))
            }
            CredentialKeychain.set(result.token, for: Self.account(saved.id))
            persist()
            connect(saved, token: result.token)
        } catch let error as PhoneHostClientError {
            notice = error.message
        } catch {
            notice = PhoneHostClientError.unexpected.message
        }
    }

    func forget(_ id: String) {
        connections[id]?.stop()
        connections[id] = nil
        CredentialKeychain.delete(Self.account(id))
        if selection?.machine == id { close() }
        machines.removeAll { $0.id == id }
        persist()
    }

    func reconnect(_ id: String) {
        connections[id]?.reconnectNow()
    }

    // MARK: - Reading and driving

    func open(machine: String, thread: String) {
        selection = Selection(machine: machine, thread: thread)
        items = []
        approval = machines.first { $0.id == machine }?.threads.first { $0.id == thread }?.approval
        connections[machine]?.watch(thread: thread)
    }

    func close() {
        if let machine = selection?.machine { connections[machine]?.watch(thread: nil) }
        selection = nil
        items = []
        approval = nil
    }

    var openThread: PhoneThread? {
        guard let selection else { return nil }
        return machines.first { $0.id == selection.machine }?.threads.first { $0.id == selection.thread }
    }

    var openMachine: Machine? {
        guard let selection else { return nil }
        return machines.first { $0.id == selection.machine }
    }

    func send(_ text: String) {
        guard let selection else { return }
        connections[selection.machine]?.send(text, to: selection.thread) { [weak self] result in
            if case .failure(let error) = result { Task { @MainActor in self?.notice = error.message } }
        }
    }

    func stopAgent() {
        guard let selection else { return }
        connections[selection.machine]?.interrupt(selection.thread) { _ in }
    }

    func answer(allow: Bool) {
        guard let selection, let approval else { return }
        connections[selection.machine]?.answer(approval: approval.id, in: selection.thread, allow: allow) { [weak self] result in
            if case .failure(let error) = result { Task { @MainActor in self?.notice = error.message } }
        }
    }
}
