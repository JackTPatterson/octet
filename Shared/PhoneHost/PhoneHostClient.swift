import Foundation

/// The other side of the phone host: what a Mac (or anything else) does to
/// read and drive another Octet the way the phone app does. Pair with a
/// one-time code, trade it for a bearer token, open the RPC WebSocket with a
/// ticket, and follow the shell and thread streams.

// MARK: - Pairing link

/// Where another Mac listens and the one-time code that lets this one in.
/// Reads the link Settings › Phone shows (`http://host:port/#token=CODE`) and
/// the plain "host:port CODE" a person types.
struct PhoneHostLink: Equatable {
    var host: String
    var port: Int
    var code: String

    var baseURL: URL? {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = port
        return parts.url
    }

    static func parse(_ text: String) -> PhoneHostLink? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let parts = URLComponents(string: text), let host = parts.host, let port = parts.port,
                  let fragment = parts.fragment,
                  let code = fragment.split(separator: "&").compactMap({ pair -> String? in
                      let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
                      return pieces.count == 2 && pieces[0] == "token" ? pieces[1] : nil
                  }).first, !code.isEmpty else { return nil }
            return PhoneHostLink(host: host, port: port, code: code)
        }
        // "host:port CODE", "host:port#token=CODE" or "host:port/CODE".
        let pieces = text.split(whereSeparator: { " \t#/".contains($0) }).map(String.init).filter { !$0.hasPrefix("token=") || $0.count > 6 }
        guard pieces.count >= 2 else { return nil }
        let address = pieces[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard address.count == 2, !address[0].isEmpty, let port = Int(address[1]), (1...65535).contains(port) else { return nil }
        let code = pieces[1].hasPrefix("token=") ? String(pieces[1].dropFirst(6)) : pieces[1]
        guard !code.isEmpty else { return nil }
        return PhoneHostLink(host: address[0], port: port, code: code)
    }
}

// MARK: - Reading the wire

/// The inverse of `PhoneHostWire`: T3's shapes back into Octet's own.
enum PhoneHostReader {
    static func date(_ value: Any?) -> Date {
        guard let text = value as? String else { return Date() }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
    }

    static func shell(_ snapshot: [String: Any]) -> (projects: [PhoneProject], threads: [PhoneThread]) {
        let projects = (snapshot["projects"] as? [[String: Any]] ?? []).compactMap { raw -> PhoneProject? in
            guard let id = raw["id"] as? String else { return nil }
            return PhoneProject(id: id, title: raw["title"] as? String ?? "Workspace", folder: raw["workspaceRoot"] as? String ?? "",
                                createdAt: date(raw["createdAt"]), updatedAt: date(raw["updatedAt"]))
        }
        let threads = (snapshot["threads"] as? [[String: Any]] ?? []).compactMap { raw -> PhoneThread? in
            guard let id = raw["id"] as? String, let project = raw["projectId"] as? String else { return nil }
            let model = (raw["modelSelection"] as? [String: Any])?["model"] as? String
            var approval: PhoneApproval?
            if let pending = raw["pendingRuntimeRequest"] as? [String: Any], let requestID = pending["id"] as? String {
                approval = PhoneApproval(id: requestID, kind: pending["kind"] as? String ?? "permission",
                                         prompt: "This agent is waiting for permission.", createdAt: date(pending["createdAt"]))
            }
            return PhoneThread(id: id, projectID: project, title: raw["title"] as? String ?? "Agent",
                               agent: raw["providerInstanceId"] as? String ?? "agent",
                               model: model == "default" ? nil : model,
                               status: PhoneThreadStatus(rawValue: raw["status"] as? String ?? "") ?? .idle,
                               createdAt: date(raw["createdAt"]), updatedAt: date(raw["updatedAt"]), approval: approval)
        }
        return (projects, threads)
    }

    /// A thread's transcript in order, and the permission it waits on with its prompt.
    static func projection(_ projection: [String: Any]) -> (items: [PhoneItem], approval: PhoneApproval?) {
        let raw = (projection["turnItems"] as? [[String: Any]] ?? [])
            .sorted { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }
        var items: [PhoneItem] = []
        var approval: PhoneApproval?
        for item in raw {
            guard let wireID = item["id"] as? String else { continue }
            // The host prefixes a thread item's id with "item-".
            let id = wireID.hasPrefix("item-") ? String(wireID.dropFirst(5)) : wireID
            let at = date(item["startedAt"])
            switch item["type"] as? String {
            case "user_message":
                items.append(.user(id: item["messageId"] as? String ?? id, text: item["text"] as? String ?? "", at: at))
            case "assistant_message":
                items.append(.assistant(id: item["messageId"] as? String ?? id, text: item["text"] as? String ?? "", at: at))
            case "reasoning":
                items.append(.reasoning(id: id, text: item["text"] as? String ?? "", at: at))
            case "command_execution":
                items.append(.tool(id: id, name: item["title"] as? String ?? "Tool", input: item["input"] as? String ?? "",
                                   output: item["output"] as? String, failed: item["outputIndicatesFailure"] as? Bool ?? false, at: at))
            case "approval_request":
                if let request = item["requestId"] as? String {
                    approval = PhoneApproval(id: request, kind: item["requestKind"] as? String ?? "permission",
                                             prompt: item["prompt"] as? String ?? "Permission needed", createdAt: at)
                }
            default:
                continue
            }
        }
        return (items, approval)
    }
}

// MARK: - Connection

enum PhoneHostConnectionState: Equatable {
    case connecting
    case online
    /// Unreachable for now; tries again.
    case offline(String)
    /// The other Mac no longer accepts this one: removed there, or the code was wrong.
    case revoked
}

enum PhoneHostClientError: Error, Equatable {
    case invalidLink
    case unreachable(String)
    case rejected(String)
    case unexpected

    var message: String {
        switch self {
        case .invalidLink: "That isn't a pairing link. Paste the link or the address and code from Settings › Phone on the other Mac."
        case .unreachable(let detail): "Couldn't reach that Mac. \(detail)"
        case .rejected(let detail): detail
        case .unexpected: "That Mac answered in a way Octet doesn't understand."
        }
    }
}

/// One signed-in link to another Mac's host. Reconnects by itself until it's
/// stopped or the other Mac turns it away. Callbacks arrive on `queue`.
final class PhoneHostConnection: @unchecked Sendable {
    let baseURL: URL
    private let token: String
    private let queue = DispatchQueue(label: "octet.phoneclient")
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var stopped = true
    private var attempt = 0
    private var counter = 0
    private var pingTimer: DispatchSourceTimer?
    private var watching: (thread: String, request: String)?
    private var commands: [String: (Result<Void, PhoneHostError>) -> Void] = [:]

    var onState: ((PhoneHostConnectionState) -> Void)?
    var onShell: (([PhoneProject], [PhoneThread]) -> Void)?
    var onThread: ((String, [PhoneItem], PhoneApproval?) -> Void)?

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Pairing

    /// Spends the one-time code and answers the bearer token with the other Mac's description.
    static func pair(link: PhoneHostLink, label: String) async throws -> (token: String, environmentID: String, name: String) {
        guard let base = link.baseURL else { throw PhoneHostClientError.invalidLink }
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            return configuration
        }())
        defer { session.invalidateAndCancel() }

        var descriptorRequest = URLRequest(url: base.appendingPathComponent(".well-known/t3/environment"))
        descriptorRequest.httpMethod = "GET"
        let (descriptorData, descriptorResponse) = try await send(descriptorRequest, with: session)
        guard (descriptorResponse as? HTTPURLResponse)?.statusCode == 200,
              let descriptor = (try? JSONSerialization.jsonObject(with: descriptorData)) as? [String: Any],
              let environment = descriptor["environmentId"] as? String else { throw PhoneHostClientError.unexpected }

        var request = URLRequest(url: base.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": link.code,
            "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "client_label": label, "client_device_type": "desktop", "client_os": "macOS",
        ]
        request.httpBody = Data(fields.map { "\($0.key)=\(encode($0.value))" }.sorted().joined(separator: "&").utf8)
        let (data, response) = try await send(request, with: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 429 { throw PhoneHostClientError.rejected("Too many wrong codes. Wait half a minute and try again.") }
            throw PhoneHostClientError.rejected("That code didn't work. Codes work once and expire after 5 minutes; show a new one on the other Mac.")
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = body["access_token"] as? String else {
            throw PhoneHostClientError.unexpected
        }
        return (token, environment, descriptor["label"] as? String ?? link.host)
    }

    private static func send(_ request: URLRequest, with session: URLSession) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch {
            throw PhoneHostClientError.unreachable((error as NSError).localizedDescription)
        }
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    // MARK: Lifecycle

    func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.attempt = 0
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.generation += 1
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            self.failCommands("Disconnected.")
        }
    }

    /// Brings a stalled link back now rather than at its next retry.
    func reconnectNow() {
        queue.async {
            guard !self.stopped else { return }
            self.attempt = 0
            self.drop(reason: nil, retry: true)
        }
    }

    private func connect() {
        guard !stopped else { return }
        generation += 1
        let mine = generation
        onState?(.connecting)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/websocket-ticket/rpc"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, mine == self.generation else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    self.stopped = true
                    self.onState?(.revoked)
                    return
                }
                guard error == nil, status == 200, let data,
                      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let ticket = body["ticket"] as? String else {
                    return self.retryLater(error.map { ($0 as NSError).localizedDescription } ?? "It isn't answering.")
                }
                self.open(ticket: ticket, mine: mine)
            }
        }
        task.resume()
    }

    private func open(ticket: String, mine: Int) {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.scheme = "ws"
        parts?.path = "/ws"
        parts?.queryItems = [URLQueryItem(name: "wsTicket", value: ticket)]
        guard let url = parts?.url else { return retryLater("Bad address.") }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        socket.resume()
        request("shell", tag: "orchestration.subscribeShell", payload: ["requestCompletionMarker": false])
        if let watching { request(watching.request, tag: "orchestration.subscribeThread", payload: ["threadId": watching.thread]) }
        receive(on: socket, mine: mine)
        startPings(mine: mine)
    }

    private func receive(on socket: URLSessionWebSocketTask, mine: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped, mine == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.drop(reason: (error as NSError).localizedDescription, retry: true)
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: socket, mine: mine)
                }
            }
        }
    }

    private func startPings(mine: Int) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, mine == self.generation, let socket = self.socket else { return }
            socket.sendPing { error in
                guard error != nil else { return }
                self.queue.async {
                    guard mine == self.generation else { return }
                    self.drop(reason: "The connection went quiet.", retry: true)
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func drop(reason: String?, retry: Bool) {
        generation += 1
        pingTimer?.cancel()
        pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failCommands("Disconnected.")
        if retry { retryLater(reason ?? "Reconnecting.", delayed: reason != nil) }
    }

    private func retryLater(_ reason: String, delayed: Bool = true) {
        onState?(.offline(reason))
        attempt += 1
        let delay = delayed ? min(30, Double(1 << min(attempt, 5))) : 0
        let mine = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, mine == self.generation else { return }
            self.connect()
        }
    }

    // MARK: Sending

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func write(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func request(_ id: String, tag: String, payload: [String: Any]) {
        write(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [Any]()])
    }

    /// Follows one thread's transcript (nil stops following).
    func watch(thread: String?) {
        queue.async {
            if let current = self.watching {
                self.write(["_tag": "Interrupt", "requestId": current.request])
                self.watching = nil
            }
            guard let thread else { return }
            let id = self.nextID("thread")
            self.watching = (thread, id)
            self.request(id, tag: "orchestration.subscribeThread", payload: ["threadId": thread])
        }
    }

    func send(_ text: String, to thread: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        command(["type": "message.dispatch", "threadId": thread, "text": text], completion)
    }

    func interrupt(_ thread: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        command(["type": "run.interrupt", "threadId": thread], completion)
    }

    func answer(approval: String, in thread: String, allow: Bool, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        command(["type": "runtime-request.respond", "threadId": thread, "requestId": approval,
                 "decision": allow ? "accept" : "decline"], completion)
    }

    private func command(_ body: [String: Any], _ completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        queue.async {
            guard self.socket != nil, !self.stopped else { return completion(.failure(.failed("That Mac isn't connected."))) }
            let id = self.nextID("cmd")
            var payload = body
            payload["commandId"] = UUID().uuidString.lowercased()
            self.commands[id] = completion
            self.request(id, tag: "orchestration.dispatchCommand", payload: payload)
        }
    }

    private func failCommands(_ reason: String) {
        let pending = commands
        commands = [:]
        pending.values.forEach { $0(.failure(.failed(reason))) }
    }

    // MARK: Receiving

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
        let messages = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        for message in messages {
            let id = message["requestId"].map { "\($0)" }
            switch message["_tag"] as? String {
            case "Ping": write(["_tag": "Pong"])
            case "Chunk":
                guard let id, let values = message["values"] as? [[String: Any]] else { continue }
                chunk(id, values)
            case "Exit":
                guard let id, let done = commands.removeValue(forKey: id) else { continue }
                done(Self.result(of: message["exit"] as? [String: Any]))
            default: break
            }
        }
    }

    private func chunk(_ id: String, _ values: [[String: Any]]) {
        for value in values where value["kind"] as? String == "snapshot" {
            if id == "shell", let snapshot = value["snapshot"] as? [String: Any] {
                let (projects, threads) = PhoneHostReader.shell(snapshot)
                onShell?(projects, threads)
            } else if let watching, id == watching.request, let projection = value["projection"] as? [String: Any] {
                let (items, approval) = PhoneHostReader.projection(projection)
                onThread?(watching.thread, items, approval)
            }
        }
    }

    static func result(of exit: [String: Any]?) -> Result<Void, PhoneHostError> {
        guard let exit else { return .failure(.failed("No answer.")) }
        if exit["_tag"] as? String == "Success" { return .success(()) }
        let cause = (exit["cause"] as? [[String: Any]])?.first
        if let error = cause?["error"] as? [String: Any] {
            return .failure(.failed(error["message"] as? String ?? error["_tag"] as? String ?? "That Mac refused."))
        }
        return .failure(.failed(cause?["defect"] as? String ?? "That Mac refused."))
    }
}
