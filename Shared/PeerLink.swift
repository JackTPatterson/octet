import Foundation
import Network

/// One connection to another Octet: length-prefixed frames over TCP, the
/// hellos in the clear, then proofs of identity and everything else sealed
/// (see `PeerCrypto`). Runs on the node's queue.
final class PeerConnection {
    enum Phase: Equatable {
        case hello
        case proving
        /// Unknown Mac: waiting for both people to accept the code.
        case pairing
        case ready
        case closed
    }

    let id = UUID()
    let connection: NWConnection
    let role: PeerCrypto.Role
    private(set) var phase: Phase = .hello
    private(set) var session: PeerCrypto.Session?
    private let handshake: PeerCrypto.Handshake
    private var buffer = Data()
    private var peerProved = false
    private var provedSelf = false
    private(set) var localAccepted = false
    private(set) var remoteAccepted = false
    /// The other side's device, once its hello is in.
    var peerHello: PeerCrypto.Hello? { session?.peer }

    var onProved: ((PeerConnection) -> Void)?
    var onPairingAnswered: ((PeerConnection) -> Void)?
    var onMessage: ((PeerConnection, [String: Any]) -> Void)?
    var onClose: ((PeerConnection, Error?) -> Void)?

    static let maxFrame = 8 * 1024 * 1024

    init(connection: NWConnection, role: PeerCrypto.Role, identity: PeerCrypto.Identity, device: String, name: String) throws {
        self.connection = connection
        self.role = role
        handshake = try PeerCrypto.Handshake(role: role, identity: identity, device: device, name: name)
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.writeFrame(self.handshake.helloData)
                self.receive()
            case .failed(let error), .waiting(let error):
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Sending

    func send(_ message: [String: Any]) {
        guard phase != .closed, let session, let data = try? PeerProtocol.encode(message),
              let sealed = try? session.seal(data) else { return }
        writeFrame(sealed)
    }

    /// This side's answer to the pairing code.
    func answerPairing(_ accept: Bool) {
        guard phase == .pairing else { return }
        localAccepted = accept
        send(["type": "pair", "accept": accept])
        if !accept { close(PairingDeclined()) } else { onPairingAnswered?(self) }
    }

    /// Known Mac, or both sides accepted the code: requests may flow.
    func markReady() {
        guard phase != .closed else { return }
        phase = .ready
    }

    func close(_ error: Error? = nil) {
        guard phase != .closed else { return }
        phase = .closed
        connection.cancel()
        onClose?(self, error)
    }

    struct PairingDeclined: Error, CustomStringConvertible {
        var description: String { "The pairing was declined." }
    }

    private func writeFrame(_ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + payload
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error) }
        })
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drain()
            if let error { return self.close(error) }
            if complete { return self.close(nil) }
            if self.phase != .closed { self.receive() }
        }
    }

    private func drain() {
        while buffer.count >= 4, phase != .closed {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrame else { return close(PeerCrypto.Failure.badHello) }
            guard buffer.count >= 4 + length else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            buffer = Data(buffer)
            do { try handle(payload) } catch { return close(error) }
        }
    }

    private func handle(_ payload: Data) throws {
        switch phase {
        case .hello:
            let session = try handshake.finish(peerHelloData: payload)
            self.session = session
            phase = .proving
            send(["type": "proof", "signature": try session.proof().base64EncodedString()])
            provedSelf = true
        case .proving, .pairing, .ready:
            guard let session else { return }
            guard let message = PeerProtocol.decode(try session.open(payload)) else { throw PeerCrypto.Failure.sealed }
            switch message["type"] as? String {
            case "proof" where phase == .proving:
                guard let text = message["signature"] as? String, let signature = Data(base64Encoded: text) else {
                    throw PeerCrypto.Failure.badSignature
                }
                try session.verify(proof: signature)
                peerProved = true
                onProved?(self)
            case "pair" where phase == .pairing || phase == .proving:
                remoteAccepted = message["accept"] as? Bool ?? false
                if !remoteAccepted { return close(PairingDeclined()) }
                onPairingAnswered?(self)
            default:
                guard phase == .ready else { return }
                onMessage?(self, message)
            }
        case .closed:
            break
        }
    }

    /// Unknown Mac: show the code and wait for both answers.
    func beginPairing() {
        guard phase == .proving else { return }
        phase = .pairing
    }
}

/// A Mac found on the network by Bonjour.
struct DiscoveredPeer: Equatable, Identifiable {
    let name: String
    let device: String?
    let endpoint: NWEndpoint
    var id: String { device ?? name }
}

/// What the node asks of the app around it.
protocol PeerHost: AnyObject {
    /// A request from a paired Mac. Reply once, from any thread.
    func handle(method: PeerProtocol.Method, params: [String: Any], from peer: PairedPeer,
                reply: @escaping @Sendable (Result<[String: Any], PeerProtocol.RemoteError>) -> Void)
    /// An event from a paired Mac.
    func handle(event: String, data: [String: Any], from peer: PairedPeer)
    /// An unknown Mac, with the code both screens show. Answer once.
    func approvePairing(name: String, code: String, fingerprint: String, incoming: Bool, answer: @escaping @Sendable (Bool) -> Void)
    /// Pairing, connections or the Macs nearby changed.
    func peersChanged()
}

/// This Mac's end: listens (and, when asked, advertises), finds other
/// Octets, pairs, and carries requests to paired Macs and back.
final class PeerNode {
    let store: PeerStore
    let queue = DispatchQueue(label: "com.jpxsoftware.octet.peers")
    weak var host: PeerHost?
    private let machineName: @Sendable () -> String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [UUID: PeerConnection] = [:]
    /// Ready connections by device.
    private var ready: [String: PeerConnection] = [:]
    private var pending: [String: @Sendable (Result<[String: Any], PeerProtocol.RemoteError>) -> Void] = [:]
    private var waitingForConnection: [String: [(PeerConnection?) -> Void]] = [:]
    private(set) var port: UInt16?
    private(set) var discovered: [DiscoveredPeer] = []
    /// Accepting Macs that haven't paired: while the user is pairing, or
    /// always when the listener is on.
    var acceptsPairing = true

    init(store: PeerStore, machineName: @escaping @Sendable () -> String) {
        self.store = store
        self.machineName = machineName
    }

    // MARK: - Lifecycle

    /// Listens on `port` (any when nil); with `advertise`, Bonjour tells the
    /// network, and other Octets are looked for.
    func start(port: UInt16? = nil, advertise: Bool, loopbackOnly: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try port.map { try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: $0)!) }
            ?? NWListener(using: parameters)
        if advertise {
            listener.service = NWListener.Service(name: machineName(), type: PeerProtocol.bonjourType,
                                                  txtRecord: NWTXTRecord(["device": store.device]))
        }
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue
                started.signal()
            case .failed:
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        _ = started.wait(timeout: .now() + 5)
        if advertise { browse() }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
            for connection in connections.values { connection.close() }
            connections = [:]
            ready = [:]
            discovered = []
            port = nil
        }
    }

    var onlineDevices: Set<String> { queue.sync { Set(ready.keys) } }
    var nearby: [DiscoveredPeer] { queue.sync { discovered } }

    // MARK: - Discovery

    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PeerProtocol.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.discovered = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var device: String?
                if case .bonjour(let record) = result.metadata { device = record["device"] }
                guard device != self.store.device else { return nil }
                return DiscoveredPeer(name: name, device: device, endpoint: result.endpoint)
            }
            self.notifyChanged()
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: - Connections

    private func accept(_ nw: NWConnection) {
        guard let connection = try? PeerConnection(connection: nw, role: .server, identity: store.identity,
                                                   device: store.device, name: machineName()) else { return nw.cancel() }
        wire(connection, pairing: false, completion: nil)
    }

    /// Connects to `endpoint`. An unknown Mac is paired (both people accept
    /// the code) when `pairing` is set, refused otherwise.
    func connect(to endpoint: NWEndpoint, pairing: Bool, completion: (@Sendable (Result<PairedPeer, Error>) -> Void)? = nil) {
        queue.async {
            guard let connection = try? PeerConnection(connection: NWConnection(to: endpoint, using: .tcp), role: .client,
                                                       identity: self.store.identity, device: self.store.device,
                                                       name: self.machineName()) else { return }
            self.wire(connection, pairing: pairing, completion: completion)
        }
    }

    private func wire(_ connection: PeerConnection, pairing: Bool, completion: (@Sendable (Result<PairedPeer, Error>) -> Void)?) {
        var finished = false
        let finish: (Result<PairedPeer, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion?(result)
        }
        connections[connection.id] = connection
        connection.onProved = { [weak self] connection in
            guard let self, let hello = connection.peerHello else { return }
            if let known = self.store.peer(device: hello.device) {
                guard known.identity == hello.identity else {
                    // Same device id, different key: not the Mac that paired.
                    connection.close(IdentityChanged(name: known.name))
                    return
                }
                self.becameReady(connection, peer: known)
                finish(.success(known))
                return
            }
            guard pairing || (connection.role == .server && self.acceptsPairing), let session = connection.session else {
                connection.close(NotPaired())
                return
            }
            connection.beginPairing()
            self.host?.approvePairing(name: hello.name, code: session.pairingCode,
                                      fingerprint: PeerCrypto.fingerprint(hello.identity),
                                      incoming: connection.role == .server) { accept in
                self.queue.async { connection.answerPairing(accept) }
            }
        }
        connection.onPairingAnswered = { [weak self] connection in
            guard let self, connection.localAccepted, connection.remoteAccepted, let hello = connection.peerHello else { return }
            var host: String?, port: UInt16?
            if case .hostPort(let h, let p) = connection.connection.currentPath?.remoteEndpoint ?? connection.connection.endpoint {
                host = "\(h)"
                port = connection.role == .client ? p.rawValue : nil
            }
            let peer = PairedPeer(device: hello.device, name: hello.name, identity: hello.identity, trust: .ask,
                                  lastHost: host, lastPort: port, paired: Date())
            self.store.add(peer)
            self.becameReady(connection, peer: peer)
            finish(.success(peer))
        }
        connection.onMessage = { [weak self] connection, message in self?.received(message, on: connection) }
        connection.onClose = { [weak self] connection, error in
            guard let self else { return }
            self.connections[connection.id] = nil
            if let device = connection.peerHello?.device, self.ready[device] === connection {
                self.ready[device] = nil
                self.notifyChanged()
            }
            self.flushWaiters(device: connection.peerHello?.device, with: nil)
            finish(.failure(error ?? ConnectionClosed()))
        }
        connection.start(on: queue)
    }

    private func becameReady(_ connection: PeerConnection, peer: PairedPeer) {
        connection.markReady()
        ready[peer.device] = connection
        // Remember where it answered from, to find it again.
        if connection.role == .client, case .hostPort(let host, let port) = connection.connection.endpoint {
            store.update(device: peer.device) { $0.lastHost = "\(host)"; $0.lastPort = port.rawValue }
        }
        flushWaiters(device: peer.device, with: connection)
        notifyChanged()
    }

    private func flushWaiters(device: String?, with connection: PeerConnection?) {
        guard let device, let waiters = waitingForConnection.removeValue(forKey: device) else { return }
        for waiter in waiters { waiter(connection) }
    }

    private func notifyChanged() {
        host?.peersChanged()
    }

    struct IdentityChanged: Error, CustomStringConvertible {
        let name: String
        var description: String { "\(name) answered with a different identity than it paired with. Forget it and pair again if it was reinstalled." }
    }

    struct NotPaired: Error, CustomStringConvertible {
        var description: String { "That Mac isn't paired with this one." }
    }

    struct ConnectionClosed: Error, CustomStringConvertible {
        var description: String { "The connection closed." }
    }

    // MARK: - Requests

    /// Calls `method` on a paired Mac, connecting first if needed.
    func call(device: String, method: PeerProtocol.Method, params: [String: Any], timeout: TimeInterval = 30,
              completion: @escaping @Sendable (Result<[String: Any], PeerProtocol.RemoteError>) -> Void) {
        queue.async {
            self.withConnection(to: device) { connection in
                guard let connection else {
                    return completion(.failure(.init(code: PeerProtocol.ErrorCode.unavailable.rawValue,
                                                     message: "\(self.store.peer(device: device)?.name ?? "That Mac") isn't reachable. Is Octet open there, with other Macs allowed?")))
                }
                let id = UUID().uuidString
                self.pending[id] = completion
                connection.send(PeerProtocol.request(id: id, method: method, params: params))
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiting = self.pending.removeValue(forKey: id) else { return }
                    waiting(.failure(.init(code: PeerProtocol.ErrorCode.unavailable.rawValue, message: "No answer within \(Int(timeout)) s.")))
                }
            }
        }
    }

    /// An event to a paired Mac, if it's connected (or can be).
    func send(event: PeerProtocol.Event, data: [String: Any], to device: String) {
        queue.async {
            self.withConnection(to: device) { $0?.send(PeerProtocol.event(event, data: data)) }
        }
    }

    private func withConnection(to device: String, _ body: @escaping (PeerConnection?) -> Void) {
        if let connection = ready[device] { return body(connection) }
        guard let peer = store.peer(device: device) else { return body(nil) }
        let endpoint: NWEndpoint?
        if let found = discovered.first(where: { $0.device == device }) {
            endpoint = found.endpoint
        } else if let host = peer.lastHost, let port = peer.lastPort, let nwPort = NWEndpoint.Port(rawValue: port) {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        } else {
            endpoint = nil
        }
        guard let endpoint else { return body(nil) }
        let first = waitingForConnection[device] == nil
        waitingForConnection[device, default: []].append(body)
        guard first else { return }
        connect(to: endpoint, pairing: false)
        queue.asyncAfter(deadline: .now() + 8) { self.flushWaiters(device: device, with: nil) }
    }

    private func received(_ message: [String: Any], on connection: PeerConnection) {
        guard let device = connection.peerHello?.device, let peer = store.peer(device: device) else { return }
        switch message["type"] as? String {
        case "request":
            guard let id = message["id"] as? String else { return }
            guard let method = (message["method"] as? String).flatMap(PeerProtocol.Method.init(rawValue:)) else {
                return connection.send(PeerProtocol.response(id: id, error: .badRequest, "Unknown request."))
            }
            if method == .ping { return connection.send(PeerProtocol.response(id: id, result: ["pong": true])) }
            guard let host else {
                return connection.send(PeerProtocol.response(id: id, error: .unavailable, "Octet isn't ready."))
            }
            host.handle(method: method, params: message["params"] as? [String: Any] ?? [:], from: peer) { [weak connection] result in
                self.queue.async {
                    switch result {
                    case .success(let value): connection?.send(PeerProtocol.response(id: id, result: value))
                    case .failure(let error):
                        connection?.send(["type": "response", "id": id, "error": ["code": error.code, "message": error.message]])
                    }
                }
            }
        case "response":
            guard let id = message["id"] as? String, let waiting = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                waiting(.failure(.init(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "It failed.")))
            } else {
                waiting(.success(message["result"] as? [String: Any] ?? [:]))
            }
        case "event":
            guard let event = message["event"] as? String else { return }
            host?.handle(event: event, data: message["data"] as? [String: Any] ?? [:], from: peer)
        default:
            break
        }
    }

    /// Drops a paired Mac's connection (after forgetting it).
    func disconnect(device: String) {
        queue.async {
            self.ready[device]?.close()
            self.ready[device] = nil
        }
    }
}
