import Foundation
import Network

/// Listens for the Octet phone app. Plain requests go to the router; a request
/// to `/ws` with a valid ticket becomes an RPC session.
final class PhoneHostServer {
    static let defaultPort: UInt16 = 52200
    static let maxConnections = 64
    static let requestTimeout: TimeInterval = 10

    let router: PhoneHostRouter
    private let backend: PhoneHostBackend
    private let queue = DispatchQueue(label: "octet.phonehost")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: PhoneRPCSession] = [:]
    private var revision = 1
    private var refreshPending = false
    private(set) var port: UInt16?

    init(router: PhoneHostRouter, backend: PhoneHostBackend) {
        self.router = router
        self.backend = backend
        backend.onChange = { [weak self] in self?.backendChanged() }
    }

    /// Listens on `port` (any when nil). `loopbackOnly` keeps it off the network, for tests.
    func start(port: UInt16? = defaultPort, loopbackOnly: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try port.map { try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: $0)!) }
            ?? NWListener(using: parameters)
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
        if self.port == nil {
            listener.cancel()
            self.listener = nil
            throw StartError.couldNotListen
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            sessions.values.forEach { $0.stop() }
            sessions = [:]
            connections.values.forEach { $0.cancel() }
            connections = [:]
            port = nil
        }
    }

    enum StartError: Error { case couldNotListen }

    /// Drops every open phone session, as when a phone is unpaired.
    func disconnect(sessionID: String) {
        queue.async {
            for (id, session) in self.sessions where session.sessionID == sessionID {
                session.stop()
                self.sessions[id] = nil
                self.connections[id]?.cancel()
            }
        }
    }

    // MARK: - Changes

    private func backendChanged() {
        queue.async {
            self.revision += 1
            guard !self.refreshPending else { return }
            self.refreshPending = true
            self.queue.asyncAfter(deadline: .now() + 0.15) {
                self.refreshPending = false
                self.sessions.values.forEach { $0.refresh() }
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else { return connection.cancel() }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let finish = { [weak self] in
            connection.cancel()
            self?.queue.async {
                self?.connections[id] = nil
                self?.sessions[id]?.stop()
                self?.sessions[id] = nil
            }
        }
        var upgraded = false
        // A client that never finishes its request is cut off.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let self, let connection, !upgraded, self.connections[id] != nil else { return }
            self.send(.empty(408), on: connection, then: finish)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: finish()
            default: break
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data(), id: id, finish: finish, upgraded: { upgraded = true })
    }

    private func read(_ connection: NWConnection, buffer: Data, id: ObjectIdentifier, finish: @escaping () -> Void,
                      upgraded: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch PhoneHTTPParser.parse(buffer) {
            case .request(let request, let consumed):
                if request.path == "/ws" {
                    upgraded()
                    self.upgrade(request, rest: Data(buffer.dropFirst(consumed)), on: connection, id: id, finish: finish)
                } else {
                    self.send(self.router.handle(request), on: connection, then: finish)
                }
            case .invalid(let status):
                self.send(.empty(status), on: connection, then: finish)
            case .needMore:
                if error != nil || complete { return finish() }
                self.read(connection, buffer: buffer, id: id, finish: finish, upgraded: upgraded)
            }
        }
    }

    private func send(_ response: PhoneHTTPResponse, on connection: NWConnection, then finish: @escaping () -> Void) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in finish() })
    }

    // MARK: - WebSocket

    private func upgrade(_ request: PhoneHTTPRequest, rest: Data, on connection: NWConnection, id: ObjectIdentifier,
                         finish: @escaping () -> Void) {
        guard let handshake = PhoneWebSocket.handshake(for: request) else { return send(.empty(426), on: connection, then: finish) }
        guard let ticket = request.query["wsTicket"], let session = router.auth.consumeTicket(ticket, use: "rpc") else {
            return send(.empty(401), on: connection, then: finish)
        }
        let rpc = PhoneRPCSession(session: session, router: router, backend: backend, queue: queue,
                                  sequence: { [weak self] in self?.revision ?? 1 },
                                  transmit: { text in
                                      connection.send(content: PhoneWebSocket.text(text), completion: .contentProcessed { _ in })
                                  })
        sessions[id] = rpc
        connection.send(content: PhoneWebSocket.handshakeBytes(handshake), completion: .contentProcessed { _ in })
        var decoder = PhoneWebSocket.Decoder()
        let handle = { (data: Data) -> Bool in
            for event in decoder.feed(data) {
                switch event {
                case .text(let text): rpc.receive(text)
                case .ping(let payload): connection.send(content: PhoneWebSocket.frame(.pong, payload), completion: .contentProcessed { _ in })
                case .pong: break
                case .close:
                    connection.send(content: PhoneWebSocket.frame(.close), completion: .contentProcessed { _ in finish() })
                    return false
                }
            }
            return true
        }
        if !rest.isEmpty, !handle(rest) { return }
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data, !handle(data) { return }
                if error != nil || complete { return finish() }
                pump()
            }
        }
        pump()
    }
}
