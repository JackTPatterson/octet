import AppKit
import Foundation
import Network

/// Other Macs: pairs with Octets on the network and lets agents on each
/// talk to the other's. Answers paired Macs from this Mac's session (asking
/// first, as each Mac's trust says), starts and watches the tasks they
/// delegate, and serves `octet-cli peer …` and the agents' MCP tools over a
/// local socket. Off until Settings › Other Macs turns it on.
@MainActor
final class PeerCenter: ObservableObject, PeerHost {
    static let shared = PeerCenter()

    struct Activity: Identifiable {
        let id = UUID()
        let date = Date()
        let incoming: Bool
        let machine: String
        let summary: String
    }

    /// A task another Mac gave an agent here.
    private struct IncomingTask {
        let id: String
        let device: String
        let paneId: String
        let summary: String
        var sawWorking = false
        var reportedBlocked = false
        let started = Date()
    }

    /// A task this Mac gave an agent on another.
    private struct OutgoingTask {
        let id: String
        let device: String
        let machine: String
        let summary: String
        var status = "working"
        var result: String?
        var waiters: [([String: Any]) -> Void] = []
    }

    @Published private(set) var running = false
    @Published private(set) var paired: [PairedPeer] = []
    @Published private(set) var online: Set<String> = []
    @Published private(set) var nearby: [DiscoveredPeer] = []
    @Published private(set) var port: UInt16?
    @Published private(set) var activity: [Activity] = []
    @Published private(set) var pairingStatus: String?

    private var node: PeerNode?
    private var control: PermissionSocketServer?
    private weak var store: SessionStore?
    private var incoming: [String: IncomingTask] = [:]
    private var outgoing: [String: OutgoingTask] = [:]
    private(set) lazy var peerStore = PeerStore(url: EngineSession.supportDirectory.appendingPathComponent("peers.json"))

    var identityFingerprint: String { PeerCrypto.fingerprint(peerStore.identity.publicKey) }

    var machineName: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["OCTET_PEER_NAME"] { return name }
        #endif
        let name = SettingsStore.shared.values.peerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? (Host.current().localizedName ?? "This Mac") : name
    }

    // MARK: - Lifecycle

    /// Follows the setting: on starts listening and looking, off stops both.
    func apply(store: SessionStore? = nil) {
        if let store { self.store = store }
        startControlSocket()
        let wanted = SettingsStore.shared.values.peersEnabled
        if wanted, node == nil { start() } else if !wanted, node != nil { stop() }
        refresh()
    }

    /// The name, readable from the network queue.
    final class NameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "Octet"
        func set(_ name: String) { lock.withLock { value = name } }
        func get() -> String { lock.withLock { value } }
    }
    nonisolated static let currentName = NameBox()

    func restart() {
        guard node != nil else { return }
        stop()
        start()
        refresh()
    }

    private func start() {
        Self.currentName.set(machineName)
        let node = PeerNode(store: peerStore, machineName: { Self.currentName.get() })
        node.host = self
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        // Testing: a fixed port on the loopback interface, without Bonjour
        // (which would ask for local network access).
        let testPort = environment["OCTET_PEER_PORT"].flatMap(UInt16.init)
        let loopback = testPort != nil
        #else
        let testPort: UInt16? = nil
        let loopback = false
        #endif
        _ = environment
        do {
            try node.start(port: testPort, advertise: !loopback, loopbackOnly: loopback)
            self.node = node
            running = true
            log(false, machineName, "Listening on port \(node.port.map(String.init) ?? "?")")
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't start talking to other Macs", detail: String(describing: error))
        }
    }

    private func stop() {
        node?.stop()
        node = nil
        running = false
    }

    private func startControlSocket() {
        guard control == nil else { return }
        let path = EngineSession.supportDirectory.appendingPathComponent(PeerControl.socketName).path
        let server = PermissionSocketServer(path: path)
        do {
            try server.start { [weak self] request, reply in
                MainActor.assumeIsolated {
                    guard let self else { return reply(["error": "Octet is closing."]) }
                    self.handleControl(request, reply: reply)
                }
            }
            control = server
        } catch {
            // The CLI and tools will say Octet isn't reachable.
        }
    }

    func refresh() {
        paired = peerStore.peers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        online = node?.onlineDevices ?? []
        let pairedDevices = Set(paired.map(\.device))
        nearby = (node?.nearby ?? []).filter { $0.device.map { !pairedDevices.contains($0) } ?? true }
        port = node?.port
    }

    // MARK: - Pairing and trust (Settings)

    func pair(with endpoint: NWEndpoint, name: String, completion: ((String?) -> Void)? = nil) {
        guard let node else { completion?("Other Macs is off."); return }
        pairingStatus = "Connecting to \(name)…"
        node.connect(to: endpoint, pairing: true) { @Sendable result in
            nonisolated(unsafe) let result = result
            DispatchQueue.main.async {
                self.pairingStatus = nil
                switch result {
                case .success: completion?(nil)
                case .failure(let error): completion?(String(describing: error))
                }
                switch result {
                case .success(let peer):
                    ToastCenter.shared.succeed(nil, "Paired with \(peer.name)")
                    self.log(false, peer.name, "Paired")
                case .failure(let error):
                    ToastCenter.shared.fail(nil, "Couldn't pair with \(name)", detail: String(describing: error))
                }
                self.refresh()
            }
        }
    }

    /// "studio.local:52100", "192.168.1.20:52100" or "[::1]:52100".
    func pair(address: String, completion: ((String?) -> Void)? = nil) {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            ToastCenter.shared.info("Give the address as host:port", detail: "The port shows in the other Mac's Settings › Other Macs.")
            completion?("Give the address as host:port.")
            return
        }
        let host = String(text[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        pair(with: .hostPort(host: NWEndpoint.Host(host), port: nwPort), name: host, completion: completion)
    }

    func setTrust(_ trust: PeerTrust, for device: String) {
        peerStore.update(device: device) { $0.trust = trust }
        refresh()
    }

    func forget(_ device: String) {
        let name = peerStore.peer(device: device)?.name ?? "that Mac"
        peerStore.forget(device: device)
        node?.disconnect(device: device)
        log(false, name, "Forgotten")
        refresh()
    }

    // MARK: - PeerHost

    nonisolated func peersChanged() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
    }

    nonisolated func approvePairing(name: String, code: String, fingerprint: String, incoming: Bool, answer: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                #if DEBUG
                if ProcessInfo.processInfo.environment["OCTET_PEER_AUTOPAIR"] != nil {
                    self.log(incoming, name, "Pairing code \(code) accepted by the test hook")
                    return answer(true)
                }
                #endif
                NSApp.requestUserAttention(.criticalRequest)
                ConfirmCenter.shared.ask(ConfirmCenter.Request(
                    title: incoming ? "\(name) wants to pair with this Mac" : "Pair with \(name)?",
                    message: "Pair only if \(name) shows the same code. A paired Mac can see your agents, and message them or give them tasks as you allow in Settings › Other Macs. Its key: \(fingerprint).",
                    detail: code,
                    confirmTitle: "Codes Match, Pair",
                    cancelTitle: "Don't Pair",
                    onConfirm: { _ in answer(true) },
                    onCancel: { answer(false) }
                ))
            }
        }
    }

    nonisolated func handle(method: PeerProtocol.Method, params: [String: Any], from peer: PairedPeer,
                            reply: @escaping @Sendable (Result<[String: Any], PeerProtocol.RemoteError>) -> Void) {
        // Params and reply cross threads as they are; the dictionaries are
        // plain JSON values.
        nonisolated(unsafe) let params = params
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.serve(method, params: params, from: peer, reply: reply) }
        }
    }

    nonisolated func handle(event: String, data: [String: Any], from peer: PairedPeer) {
        nonisolated(unsafe) let data = data
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.received(event: event, data: data, from: peer) }
        }
    }

    // MARK: - Serving other Macs

    private static func failure(_ code: PeerProtocol.ErrorCode, _ message: String) -> Result<[String: Any], PeerProtocol.RemoteError> {
        .failure(.init(code: code.rawValue, message: message))
    }

    private func serve(_ method: PeerProtocol.Method, params: [String: Any], from peer: PairedPeer,
                       reply: @escaping (Result<[String: Any], PeerProtocol.RemoteError>) -> Void) {
        guard let store else { return reply(Self.failure(.unavailable, "Octet here has no session open.")) }
        let sender = PeerProtocol.Sender(params["from"] as? [String: Any], machine: peer.name)
        switch method {
        case .agents:
            reply(.success(["machine": machineName, "agents": agents(in: store).map(\.dictionary)]))
        case .send:
            guard let paneId = params["agent"] as? String, let text = params["text"] as? String, !text.isEmpty else {
                return reply(Self.failure(.badRequest, "A message needs an agent and some text."))
            }
            guard let agent = agents(in: store).first(where: { $0.id == paneId }) else {
                return reply(Self.failure(.notFound, "No agent \(paneId) on \(machineName). List them first."))
            }
            let deliver = { (allowed: PeerProtocol.Allowed) in
                let prompt = PeerProtocol.prompt(text, from: sender, allowed: allowed, here: self.machineName)
                let client = store.client
                DispatchQueue.global(qos: .userInitiated).async {
                    let failed = Broadcast.deliver(prompt, to: [.init(paneId: agent.id, name: agent.name, isAgent: true)]) { method, params in
                        _ = try client.call(method, params)
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if failed.isEmpty {
                                self.log(true, peer.name, "Message to \(agent.name) in \(agent.project): \(Self.short(text))")
                                reply(.success(["delivered": true]))
                            } else {
                                reply(Self.failure(.unavailable, "Couldn't deliver it to \(agent.name)."))
                            }
                        }
                    }
                }
            }
            approve(.send, from: peer, title: "\(sender.agentName.map { "\($0) on " } ?? "")\(peer.name) sent a message to \(agent.name)",
                    message: "In \(agent.project). It arrives as the agent's next prompt.", detail: text,
                    confirmTitle: "Deliver", allowAlways: "Always allow messages from \(peer.name)",
                    trustIfAlways: .messages, reply: reply, then: deliver)
        case .read:
            guard let paneId = params["agent"] as? String, agents(in: store).contains(where: { $0.id == paneId }) else {
                return reply(Self.failure(.notFound, "No agent with that id on \(machineName)."))
            }
            let lines = min(400, max(1, params["lines"] as? Int ?? 60))
            let client = store.client
            DispatchQueue.global(qos: .userInitiated).async {
                let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "recent", "lines": lines]))?["read"] as? [String: Any]
                let text = PeerProtocol.tail(read?["text"] as? String ?? "", lines: lines)
                DispatchQueue.main.async { reply(.success(["text": text])) }
            }
        case .delegate:
            delegateHere(params, sender: sender, from: peer, store: store, reply: reply)
        case .taskStatus:
            guard let id = params["task"] as? String, let task = incoming[id] else {
                return reply(Self.failure(.notFound, "No such task here."))
            }
            let status = store.snapshot.agents.first { $0.paneId == task.paneId }?.agentStatus.rawValue ?? "closed"
            reply(.success(["task": id, "status": status]))
        case .ping:
            reply(.success(["pong": true]))
        }
    }

    /// Asks first when the Mac's trust says to; "always" raises its trust.
    private func approve(_ method: PeerProtocol.Method, from peer: PairedPeer, title: String, message: String, detail: String,
                         confirmTitle: String, allowAlways: String, trustIfAlways: PeerTrust,
                         reply: @escaping (Result<[String: Any], PeerProtocol.RemoteError>) -> Void,
                         then go: @escaping (PeerProtocol.Allowed) -> Void) {
        let trust = peerStore.peer(device: peer.device)?.trust ?? .ask
        guard trust.needsApproval(method) else { return go(.trusted) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OCTET_PEER_AUTOAPPROVE"] != nil { return go(.approved) }
        #endif
        NSApp.requestUserAttention(.informationalRequest)
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: title, message: message, detail: detail, confirmTitle: confirmTitle, cancelTitle: "Decline",
            suppressTitle: allowAlways,
            onConfirm: { always in
                if always { self.setTrust(trustIfAlways, for: peer.device) }
                go(.approved)
            },
            onCancel: {
                self.log(true, peer.name, "Declined: \(title)")
                reply(Self.failure(.declined, "The person at \(self.machineName) declined."))
            }
        ))
    }

    private func delegateHere(_ params: [String: Any], sender: PeerProtocol.Sender, from peer: PairedPeer, store: SessionStore,
                              reply: @escaping (Result<[String: Any], PeerProtocol.RemoteError>) -> Void) {
        guard let kind = params["agent_type"] as? String, let folder = params["folder"] as? String,
              let task = params["task"] as? String, !task.isEmpty else {
            return reply(Self.failure(.badRequest, "A task needs agent_type, folder and task."))
        }
        var isFolder: ObjCBool = false
        let path = (folder as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return reply(Self.failure(.notFound, "There's no folder \(folder) on \(machineName)."))
        }
        guard let agent = AgentDiscoveryStore.shared.agents.first(where: { $0.id == kind }), let executable = agent.executablePath else {
            return reply(Self.failure(.notFound, "\(kind) isn't installed on \(machineName)."))
        }
        let project = URL(fileURLWithPath: path).lastPathComponent
        let start = { (_: PeerProtocol.Allowed) in
            let id = UUID().uuidString.prefix(8).lowercased()
            let prompt = PeerProtocol.taskPrompt(task, from: sender)
            self.startAgent(agent, executable: executable, in: path, prompt: prompt, store: store) { paneId in
                guard let paneId else {
                    return reply(Self.failure(.unavailable, "Couldn't start \(agent.displayName) in \(project)."))
                }
                self.incoming[String(id)] = IncomingTask(id: String(id), device: peer.device, paneId: paneId, summary: Self.short(task))
                self.log(true, peer.name, "Task for \(agent.displayName) in \(project): \(Self.short(task))")
                reply(.success(["task": String(id), "agent": paneId, "machine": self.machineName]))
            }
        }
        approve(.delegate, from: peer, title: "\(sender.agentName.map { "\($0) on " } ?? "")\(peer.name) wants \(agent.displayName) to work on a task",
                message: "In \(path). A new tab starts the agent on it, and the result goes back when it finishes.", detail: task,
                confirmTitle: "Start", allowAlways: "Always allow messages and tasks from \(peer.name)",
                trustIfAlways: .messagesAndTasks, reply: reply, then: start)
    }

    /// A tab running `agent` on `prompt` in `folder`, without taking the front.
    private func startAgent(_ agent: DiscoveredAgent, executable: String, in folder: String, prompt: String, store: SessionStore,
                            completion: @escaping (String?) -> Void) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = shellQuote(executable) + " " + shellQuote(prompt)
        var params: [String: Any] = [
            "tab_label": "\(agent.displayName) · task", "focus": false,
            "root": ["type": "pane", "label": agent.displayName, "cwd": folder,
                     "command": [shell, "-lic", "\(command); exec \(shell) -l"]] as [String: Any],
        ]
        let client = store.client
        let existing = store.snapshot.workspaces.first { store.snapshot.directory(ofWorkspace: $0.workspaceId) == folder }?.workspaceId
        DispatchQueue.global(qos: .userInitiated).async {
            var workspace = existing
            if workspace == nil {
                let created = try? client.call("workspace.create", ["cwd": folder, "label": URL(fileURLWithPath: folder).lastPathComponent, "focus": false])
                workspace = (created?["workspace"] as? [String: Any])?["workspace_id"] as? String
            }
            if let workspace { params["workspace_id"] = workspace }
            let result = try? client.call("layout.apply", params)
            let pane = PeerProtocol.paneId(inLayoutResult: result)
            DispatchQueue.main.async { completion(pane) }
        }
    }

    private func agents(in store: SessionStore) -> [PeerProtocol.Agent] {
        store.snapshot.agents.filter { $0.agent != nil && !$0.isSubagentViewer }.map { agent in
            let folder = agent.foregroundCwd ?? agent.cwd ?? store.snapshot.workingDirectory(ofPane: agent.paneId) ?? ""
            let brand = AgentBrand.forAgent(agent.agent)
            return PeerProtocol.Agent(id: agent.paneId, agent: agent.agent ?? "", name: brand?.displayName ?? agent.agent ?? "Agent",
                                      project: URL(fileURLWithPath: folder).lastPathComponent, folder: folder,
                                      status: agent.agentStatus.rawValue)
        }
    }

    /// Watches the tasks other Macs gave agents here, on every refresh.
    func observe(_ snapshot: EngineSnapshot) {
        guard !incoming.isEmpty, let store else { return }
        for (id, var task) in incoming {
            let status = snapshot.agents.first { $0.paneId == task.paneId }?.agentStatus
            let paneGone = !snapshot.panes.contains { $0.paneId == task.paneId }
            if status == .working { task.sawWorking = true; task.reportedBlocked = false }
            if status == .blocked, !task.reportedBlocked {
                task.reportedBlocked = true
                node?.send(event: .taskBlocked, data: ["task": id, "machine": machineName], to: task.device)
            }
            // A quick task can finish between refreshes, never seen working.
            let settled = status == .idle || status == .done
            let finished = paneGone || (settled && (task.sawWorking || Date().timeIntervalSince(task.started) > 15))
                || (status == nil && Date().timeIntervalSince(task.started) > 20)
            incoming[id] = task
            guard finished else { continue }
            incoming[id] = nil
            let client = store.client, device = task.device, pane = task.paneId, node = self.node
            let machine = machineName
            DispatchQueue.global(qos: .userInitiated).async {
                let read = paneGone ? nil : (try? client.call("pane.read", ["pane_id": pane, "source": "recent", "lines": 80]))?["read"] as? [String: Any]
                let result = PeerProtocol.tail(read?["text"] as? String ?? "", lines: 80)
                node?.send(event: .taskFinished, data: ["task": id, "status": paneGone ? "closed" : "done",
                                                        "result": result, "machine": machine], to: device)
            }
            log(false, peerStore.peer(device: task.device)?.name ?? "?", "Task finished: \(task.summary)")
        }
    }

    // MARK: - Events from other Macs

    private func received(event: String, data: [String: Any], from peer: PairedPeer) {
        guard let id = data["task"] as? String else { return }
        switch PeerProtocol.Event(rawValue: event) {
        case .taskFinished:
            let status = data["status"] as? String ?? "done"
            let result = data["result"] as? String ?? ""
            if var task = outgoing[id] {
                task.status = status
                task.result = result
                let waiters = task.waiters
                task.waiters = []
                outgoing[id] = task
                let answer = Self.taskAnswer(task)
                for waiter in waiters { waiter(answer) }
                ToastCenter.shared.info("\(peer.name) finished a task", detail: task.summary)
            }
            log(true, peer.name, "Task \(status): \(outgoing[id]?.summary ?? id)")
        case .taskBlocked:
            if let task = outgoing[id] {
                ToastCenter.shared.info("A task on \(peer.name) is waiting for someone there", detail: task.summary)
            }
            log(true, peer.name, "Task waiting on someone: \(outgoing[id]?.summary ?? id)")
        case nil:
            break
        }
    }

    private static func taskAnswer(_ task: OutgoingTask) -> [String: Any] {
        var answer: [String: Any] = ["task": task.id, "machine": task.machine, "status": task.status]
        if let result = task.result { answer["result"] = result }
        return answer
    }

    // MARK: - The local socket (CLI and MCP tools)

    /// The same requests the socket takes, from Octet's own palette.
    func request(_ method: PeerControl.Method, _ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        handleControl(["method": method.rawValue, "params": params], fromOctet: true, reply: reply)
    }

    /// A request from the socket counts only from a pane of this Octet's
    /// own session: other terminals don't get this feature.
    private func fromThisSession(_ params: [String: Any]) -> Bool {
        guard let store, let pane = params["from_pane"] as? String, let session = params["from_session"] as? String else { return false }
        let mine = URL(fileURLWithPath: store.client.socketPath).resolvingSymlinksInPath().path
        let theirs = URL(fileURLWithPath: session).resolvingSymlinksInPath().path
        return mine == theirs && store.snapshot.panes.contains { $0.paneId == pane }
    }

    private func handleControl(_ request: [String: Any], fromOctet: Bool = false, reply: @escaping ([String: Any]) -> Void) {
        var params = request["params"] as? [String: Any] ?? [:]
        let fail: (String) -> Void = { reply(["error": $0]) }
        guard fromOctet || fromThisSession(params) else { return fail(PeerControl.notInOctet) }
        if fromOctet { params["from_pane"] = nil }
        guard let method = (request["method"] as? String).flatMap(PeerControl.Method.init(rawValue:)) else {
            return fail("Unknown request.")
        }
        if method == .machines {
            return reply(["result": ["this_machine": machineName, "on": running, "machines": paired.map { peer in
                ["name": peer.name, "online": online.contains(peer.device), "trust": peer.trust.rawValue,
                 "key": peer.fingerprint] as [String: Any]
            }, "nearby_unpaired": nearby.map(\.name)] as [String: Any]])
        }
        guard running, let node else { return fail("Other Macs is off. Turn it on in Octet's Settings › Other Macs.") }
        if method == .pair {
            guard let address = params["address"] as? String else { return fail("Pair with which address (host:port)?") }
            return pair(address: address) { error in
                if let error { fail(error) } else { reply(["result": ["paired": true, "machines": self.paired.map(\.name)]]) }
            }
        }
        if method == .wait {
            guard let id = params["task"] as? String, var task = outgoing[id] else { return fail("No task \(params["task"] ?? "") was started from here.") }
            if task.result != nil { return reply(["result": Self.taskAnswer(task)]) }
            let timeout = min(3600, max(1, params["timeout_seconds"] as? Int ?? 600))
            var answered = false
            task.waiters.append { answer in
                guard !answered else { return }
                answered = true
                reply(["result": answer])
            }
            outgoing[id] = task
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) {
                guard !answered else { return }
                answered = true
                reply(["result": Self.taskAnswer(self.outgoing[id] ?? task).merging(["note": "Still running after \(timeout) s; wait again."]) { $1 }])
            }
            return
        }
        if method == .status {
            guard let id = params["task"] as? String, let task = outgoing[id] else { return fail("No such task.") }
            return reply(["result": Self.taskAnswer(task)])
        }
        guard let name = params["machine"] as? String, let peer = peerStore.peer(named: name) else {
            let known = paired.map(\.name).joined(separator: ", ")
            return fail("No Mac named \(params["machine"] ?? "") is paired\(known.isEmpty ? "" : " (paired: \(known))").")
        }
        var remote = params
        remote.removeValue(forKey: "machine")
        remote.removeValue(forKey: "from_pane")
        remote.removeValue(forKey: "from_session")
        remote["from"] = sender(fromPane: params["from_pane"] as? String).dictionary
        let remoteMethod: PeerProtocol.Method
        switch method {
        case .agents: remoteMethod = .agents
        case .send: remoteMethod = .send
        case .read: remoteMethod = .read
        case .delegate: remoteMethod = .delegate
        default: return fail("Unknown request.")
        }
        let timeout: TimeInterval = remoteMethod == .send || remoteMethod == .delegate ? 300 : 20
        nonisolated(unsafe) let payload = remote
        node.call(device: peer.device, method: remoteMethod, params: payload, timeout: timeout) { @Sendable result in
            nonisolated(unsafe) let result = result
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        if remoteMethod == .delegate, let id = value["task"] as? String {
                            self.outgoing[id] = OutgoingTask(id: id, device: peer.device, machine: peer.name,
                                                             summary: Self.short(params["task"] as? String ?? ""))
                            self.log(false, peer.name, "Delegated: \(Self.short(params["task"] as? String ?? ""))")
                        } else if remoteMethod == .send {
                            self.log(false, peer.name, "Message sent: \(Self.short(params["text"] as? String ?? ""))")
                        }
                        reply(["result": value])
                    case .failure(let error):
                        reply(["error": error.message])
                    }
                }
            }
        }
    }

    /// Who's asking: the agent in the pane the tool runs in, if Octet knows it.
    private func sender(fromPane pane: String?) -> PeerProtocol.Sender {
        guard let pane, let agent = store?.snapshot.agents.first(where: { $0.paneId == pane && $0.agent != nil }) else {
            // A script or a shell, not an agent: nothing to answer to.
            return .init(machine: machineName, agent: nil, agentName: nil)
        }
        return .init(machine: machineName, agent: pane, agentName: AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent)
    }

    // MARK: - Activity

    private func log(_ incoming: Bool, _ machine: String, _ summary: String) {
        activity.insert(Activity(incoming: incoming, machine: machine, summary: summary), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    private static func short(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
