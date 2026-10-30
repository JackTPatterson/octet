import Foundation

/// One phone's RPC session: Effect RPC's JSON protocol over a WebSocket.
/// Requests arrive as `{"_tag":"Request","id","tag","payload"}`; streams answer
/// with `Chunk`s and unary calls with an `Exit`. Everything runs on `queue`.
final class PhoneRPCSession {
    private let session: PhoneAuthStore.Session
    var sessionID: String { session.id }
    private let router: PhoneHostRouter
    private let backend: PhoneHostBackend
    private let queue: DispatchQueue
    private let transmit: (String) -> Void
    private let sequence: () -> Int
    private var subscriptions: [String: Subscription] = [:]
    private var timer: DispatchSourceTimer?
    private(set) var closed = false

    private enum Kind {
        case serverConfig
        case lifecycle
        case shell(completionMarker: Bool)
        case thread(id: String, completionMarker: Bool)
        case terminalMetadata
        case terminal(thread: String, terminal: String)
        /// Streams the host doesn't serve stay open and silent.
        case silent
    }

    private struct Subscription {
        var id: Any
        var kind: Kind
        var last: String?
    }

    init(session: PhoneAuthStore.Session, router: PhoneHostRouter, backend: PhoneHostBackend, queue: DispatchQueue,
         sequence: @escaping () -> Int, transmit: @escaping (String) -> Void) {
        self.session = session
        self.router = router
        self.backend = backend
        self.queue = queue
        self.sequence = sequence
        self.transmit = transmit
    }

    func stop() {
        closed = true
        subscriptions = [:]
        timer?.cancel()
        timer = nil
    }

    // MARK: - Incoming

    func receive(_ text: String) {
        guard !closed, let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
        let messages = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        for message in messages { handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        switch message["_tag"] as? String {
        case "Ping":
            send(["_tag": "Pong"])
        case "Request":
            guard let id = message["id"], let tag = message["tag"] as? String else { return }
            request(id: id, tag: tag, payload: message["payload"] as? [String: Any] ?? [:])
        case "Interrupt":
            if let id = message["requestId"] { subscriptions[key(id)] = nil }
        case "Eof":
            stop()
        default:
            // Ack and anything newer: nothing to do.
            break
        }
    }

    // MARK: - Dispatch

    private func request(id: Any, tag: String, payload: [String: Any]) {
        if let missing = missingScope(for: tag) { return fail(id, Self.authorizationError(missing)) }
        switch tag {
        case "subscribeServerConfig":
            subscribe(id, .serverConfig)
        case "subscribeServerLifecycle":
            subscribe(id, .lifecycle)
        case "orchestration.subscribeShell":
            subscribe(id, .shell(completionMarker: payload["requestCompletionMarker"] as? Bool ?? false))
        case "orchestration.subscribeThread":
            guard let thread = payload["threadId"] as? String else { return die(id, "A thread id is required.") }
            guard backend.threads().contains(where: { $0.id == thread }) else {
                return fail(id, ["_tag": "OrchestrationV2GetThreadProjectionError", "threadId": thread, "message": "No agent \(thread) here."])
            }
            subscribe(id, .thread(id: thread, completionMarker: payload["requestCompletionMarker"] as? Bool ?? false))
        case "orchestration.getThreadProjection":
            guard let thread = payload["threadId"] as? String, let found = backend.threads().first(where: { $0.id == thread }) else {
                return fail(id, ["_tag": "OrchestrationV2GetThreadProjectionError", "threadId": payload["threadId"] as? String ?? "",
                                 "message": "No such agent here."])
            }
            succeed(id, PhoneHostWire.projection(found, items: backend.transcript(of: thread)))
        case "orchestration.dispatchCommand":
            dispatch(id, command: payload)
        case "subscribeTerminalMetadata":
            subscribe(id, .terminalMetadata)
        case "terminal.open", "terminal.attach", "terminal.observe":
            terminalStart(id, tag: tag, payload: payload)
        case "terminal.write":
            terminalWrite(id, payload)
        case "terminal.resize", "terminal.clear", "terminal.close":
            succeed(id)
        case "server.probe":
            succeed(id, [String: Any]())
        case "server.getConfig":
            succeed(id, PhoneHostWire.serverConfig(router: router, backend: backend))
        default:
            if tag.hasPrefix("subscribe") || tag.hasSuffix(".subscribe") {
                subscriptions[key(id)] = Subscription(id: id, kind: .silent)
            } else {
                die(id, "\(tag) isn't available on this host.")
            }
        }
    }

    /// The permission the call needs that this phone wasn't granted.
    private func missingScope(for tag: String) -> String? {
        let needed: String?
        switch tag {
        case "orchestration.dispatchCommand": needed = "orchestration:operate"
        case _ where tag.hasPrefix("orchestration."), "subscribeServerConfig", "subscribeServerLifecycle", "server.getConfig", "server.probe":
            needed = "orchestration:read"
        case "terminal.open", "terminal.attach", "terminal.write", "terminal.resize", "terminal.clear", "terminal.close":
            needed = "terminal:operate"
        case "terminal.observe", "subscribeTerminalMetadata": needed = "terminal:read"
        default: needed = nil
        }
        guard let needed, !session.scopes.contains(needed) else { return nil }
        return needed
    }

    static func authorizationError(_ scope: String) -> [String: Any] {
        ["_tag": "EnvironmentAuthorizationError", "message": "This phone wasn't granted \(scope).",
         "requiredScope": scope, "requiredPermission": scope]
    }

    // MARK: - Commands

    private func dispatch(_ id: Any, command: [String: Any]) {
        let type = command["type"] as? String ?? ""
        let commandID = command["commandId"] as? String ?? "unknown"
        let threadID = command["threadId"] as? String ?? ""
        let failure = { (message: String) in
            self.fail(id, ["_tag": "OrchestrationV2DispatchCommandError", "commandId": commandID, "commandType": type, "message": message])
        }
        let done: (Result<Void, PhoneHostError>) -> Void = { result in
            self.queue.async {
                switch result {
                case .success: self.succeed(id, ["sequence": self.sequence()])
                case .failure(let error): failure(error.message)
                }
            }
        }
        switch type {
        case "message.dispatch":
            guard let text = command["text"] as? String, !text.isEmpty else { return failure("A message needs some text.") }
            // The phone names the model with each message; a change takes
            // effect first, and the message follows the conversation.
            if let selection = command["modelSelection"] as? [String: Any], let provider = selection["instanceId"] as? String,
               let model = selection["model"] as? String,
               backend.threads().first(where: { $0.id == threadID }).map({ PhoneHostWire.slug($0.agent) != provider || $0.model != model }) == true {
                return backend.setModel(model, provider: provider, for: threadID) { result in
                    switch result {
                    case .success(let target): self.backend.send(text, to: target, completion: done)
                    case .failure(let error): self.queue.async { failure(error.message) }
                    }
                }
            }
            backend.send(text, to: threadID, completion: done)
        case "thread.model-selection.set":
            guard let selection = command["modelSelection"] as? [String: Any], let provider = selection["instanceId"] as? String,
                  let model = selection["model"] as? String else { return failure("A model change needs a provider and a model.") }
            backend.setModel(model, provider: provider, for: threadID) { result in done(result.map { _ in () }) }
        case "run.interrupt", "thread.stop":
            backend.interrupt(threadID, completion: done)
        case "runtime-request.respond":
            guard let request = command["requestId"] as? String else { return failure("An answer needs the request it answers.") }
            let decision = command["decision"] as? String ?? "decline"
            backend.answer(approval: request, in: threadID, allow: decision.hasPrefix("accept"), completion: done)
        default:
            failure("Octet can't do \"\(type)\" from the phone.")
        }
    }

    // MARK: - Terminals

    private func terminalSummary(_ thread: PhoneThread, view: PhoneTerminalView?) -> [String: Any] {
        [
            "threadId": thread.id, "terminalId": "term-1", "cwd": backend.projects().first { $0.id == thread.projectID }?.folder ?? "/",
            "worktreePath": NSNull(), "status": (view?.running ?? false) ? "running" : "exited", "pid": NSNull(),
            "exitCode": NSNull(), "exitSignal": NSNull(), "hasRunningSubprocess": thread.status == .running,
            "label": String(thread.title.prefix(128)), "updatedAt": PhoneHostWire.date(thread.updatedAt),
        ]
    }

    private func terminalSnapshot(thread: PhoneThread, terminal: String, view: PhoneTerminalView) -> [String: Any] {
        var snapshot = terminalSummary(thread, view: view)
        snapshot["terminalId"] = terminal
        snapshot["history"] = view.text
        snapshot["sequence"] = sequence()
        snapshot["cols"] = max(1, min(1000, view.cols))
        snapshot["rows"] = max(1, min(500, view.rows))
        snapshot["updatedAt"] = PhoneHostWire.date(Date())
        return snapshot
    }

    private func terminalStart(_ id: Any, tag: String, payload: [String: Any]) {
        guard let thread = payload["threadId"] as? String, let terminal = payload["terminalId"] as? String else {
            return die(id, "A terminal needs a thread and a terminal id.")
        }
        guard let found = backend.threads().first(where: { $0.id == thread }), let view = backend.terminal(of: thread) else {
            return fail(id, ["_tag": "TerminalSessionLookupError", "threadId": thread, "terminalId": terminal])
        }
        if tag == "terminal.open" {
            return succeed(id, terminalSnapshot(thread: found, terminal: terminal, view: view))
        }
        subscribe(id, .terminal(thread: thread, terminal: terminal))
    }

    private func terminalWrite(_ id: Any, _ payload: [String: Any]) {
        guard let thread = payload["threadId"] as? String, let data = payload["data"] as? String else {
            return die(id, "Typing needs a thread and some text.")
        }
        guard backend.terminal(of: thread) != nil else {
            return fail(id, ["_tag": "TerminalSessionLookupError", "threadId": thread, "terminalId": payload["terminalId"] as? String ?? ""])
        }
        backend.type(data, into: thread) { result in
            self.queue.async {
                switch result {
                case .success: self.succeed(id)
                case .failure(let error): self.die(id, error.message)
                }
            }
        }
    }

    // MARK: - Subscriptions

    private func subscribe(_ id: Any, _ kind: Kind) {
        let subscription = Subscription(id: id, kind: kind)
        subscriptions[key(id)] = subscription
        push(key(id), initial: true)
        if case .terminal = kind { startTimer() }
    }

    /// The backend changed: tell every stream whose picture is now different.
    func refresh() {
        guard !closed else { return }
        for key in Array(subscriptions.keys) { push(key, initial: false) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            for (key, subscription) in self.subscriptions {
                if case .terminal = subscription.kind { self.push(key, initial: false) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func push(_ key: String, initial: Bool) {
        guard var subscription = subscriptions[key] else { return }
        defer { if subscriptions[key] != nil { subscriptions[key] = subscription } }
        switch subscription.kind {
        case .silent:
            return
        case .serverConfig:
            guard initial else { return }
            chunk(subscription.id, [["version": 1, "type": "snapshot", "config": PhoneHostWire.serverConfig(router: router, backend: backend)]])
        case .lifecycle:
            guard initial else { return }
            let environment = router.descriptor()
            chunk(subscription.id, [
                ["version": 1, "sequence": 1, "type": "welcome",
                 "payload": ["environment": environment, "cwd": backend.homeFolder.isEmpty ? "/" : backend.homeFolder, "projectName": backend.machineName]],
                ["version": 1, "sequence": 2, "type": "ready", "payload": ["at": PhoneHostWire.date(Date()), "environment": environment]],
            ])
        case .shell(let marker):
            let threads = backend.threads().map { ($0, backend.transcript(of: $0.id)) }
            let snapshot = PhoneHostWire.shellSnapshot(projects: backend.projects(), threads: threads, sequence: sequence())
            guard let signature = Self.signature(snapshot, dropping: "snapshotSequence"), signature != subscription.last else { return }
            subscription.last = signature
            var items: [[String: Any]] = [["kind": "snapshot", "snapshot": snapshot]]
            if initial && marker { items.append(["kind": "synchronized"]) }
            chunk(subscription.id, items)
        case .thread(let threadID, let marker):
            guard let thread = backend.threads().first(where: { $0.id == threadID }) else {
                subscriptions[key] = nil
                return fail(subscription.id, ["_tag": "OrchestrationV2GetThreadProjectionError", "threadId": threadID, "message": "That agent is gone."])
            }
            let projection = PhoneHostWire.projection(thread, items: backend.transcript(of: threadID))
            guard let signature = Self.signature(projection, dropping: ""), signature != subscription.last else { return }
            subscription.last = signature
            var items: [[String: Any]] = [["kind": "snapshot", "snapshotSequence": sequence(), "projection": projection]]
            if initial && marker { items.append(["kind": "synchronized"]) }
            chunk(subscription.id, items)
        case .terminalMetadata:
            let terminals = backend.threads().compactMap { thread in backend.terminal(of: thread.id).map { terminalSummary(thread, view: $0) } }
            guard let signature = Self.signature(["terminals": terminals], dropping: "updatedAt"), signature != subscription.last else { return }
            subscription.last = signature
            chunk(subscription.id, [["type": "snapshot", "terminals": terminals]])
        case .terminal(let threadID, let terminalID):
            guard let thread = backend.threads().first(where: { $0.id == threadID }), let view = backend.terminal(of: threadID) else {
                subscriptions[key] = nil
                return chunk(subscription.id, [["type": "closed", "threadId": threadID, "terminalId": terminalID]])
            }
            if initial {
                subscription.last = view.text
                return chunk(subscription.id, [["type": "snapshot", "snapshot": terminalSnapshot(thread: thread, terminal: terminalID, view: view)]])
            }
            guard view.text != subscription.last else { return }
            subscription.last = view.text
            // A pane is a screen, not a byte stream: repaint it.
            chunk(subscription.id, [["type": "output", "threadId": threadID, "terminalId": terminalID, "sequence": sequence(),
                                     "data": "\u{1b}[2J\u{1b}[H" + view.text.replacingOccurrences(of: "\n", with: "\r\n")]])
        }
    }

    /// A stable fingerprint of a value, so an unchanged picture isn't sent again.
    private static func signature(_ value: [String: Any], dropping key: String) -> String? {
        var copy = value
        if !key.isEmpty { copy[key] = nil }
        return (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Outgoing

    private func key(_ id: Any) -> String { "\(id)" }

    private func send(_ message: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        transmit(String(decoding: data, as: UTF8.self))
    }

    private func chunk(_ id: Any, _ values: [[String: Any]]) {
        guard !values.isEmpty else { return }
        send(["_tag": "Chunk", "requestId": id, "values": values])
    }

    private func succeed(_ id: Any, _ value: Any? = nil) {
        // A void success still carries its key; the client's decoder wants it present.
        let exit: [String: Any] = ["_tag": "Success", "value": value ?? NSNull()]
        send(["_tag": "Exit", "requestId": id, "exit": exit])
    }

    private func fail(_ id: Any, _ error: [String: Any]) {
        send(["_tag": "Exit", "requestId": id, "exit": ["_tag": "Failure", "cause": [["_tag": "Fail", "error": error]]]])
    }

    private func die(_ id: Any, _ message: String) {
        send(["_tag": "Exit", "requestId": id, "exit": ["_tag": "Failure", "cause": [["_tag": "Die", "defect": message]]]])
    }
}
