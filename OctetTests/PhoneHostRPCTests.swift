import XCTest

final class PhoneHostRPCTests: XCTestCase {
    final class Backend: PhoneHostBackend {
        let machineName = "Test Mac"
        let homeFolder = "/Users/test"
        var onChange: (() -> Void)?
        var sent: [(String, String)] = []
        var interrupted: [String] = []
        var answers: [(String, Bool)] = []
        var approval: PhoneApproval?

        func projects() -> [PhoneProject] {
            [PhoneProject(id: "w1", title: "octet", folder: "/Users/test/octet", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))]
        }
        func threads() -> [PhoneThread] {
            [PhoneThread(id: "s:1", projectID: "w1", title: "Fix", agent: "claude", model: nil, status: approval == nil ? .idle : .waiting,
                         createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), approval: approval)]
        }
        func transcript(of threadID: String) -> [PhoneItem] { [.user(id: "m1", text: "hi", at: Date(timeIntervalSince1970: 0))] }
    var modelChanges: [(String, String, String)] = []
    func providers() -> [PhoneProvider] {
        [PhoneProvider(id: "claude", name: "Claude", models: [PhoneModel(id: "opus", name: "Opus", isDefault: true), PhoneModel(id: "sonnet", name: "Sonnet")]),
         PhoneProvider(id: "codex", name: "Codex", models: [PhoneModel(id: "gpt", name: "GPT", isDefault: true)])]
    }
    func setModel(_ model: String, provider: String, for threadID: String, completion: @escaping (Result<String, PhoneHostError>) -> Void) {
        modelChanges.append((model, provider, threadID))
        // Another agent continues in a new conversation.
        completion(.success(provider == "claude" ? threadID : threadID + "-next"))
    }
        func send(_ text: String, to threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
            sent.append((threadID, text)); completion(.success(()))
        }
        func interrupt(_ threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
            interrupted.append(threadID); completion(.success(()))
        }
        func answer(approval id: String, in threadID: String, allow: Bool, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
            answers.append((id, allow)); completion(.success(()))
        }
        func terminal(of threadID: String) -> PhoneTerminalView? { nil }
        func type(_ data: String, into threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) { completion(.success(())) }
    }

    private let queue = DispatchQueue(label: "test.rpc")

    private func session(scopes: [String] = PhoneAuthStore.supportedScopes, backend: Backend = Backend()) -> (PhoneRPCSession, () -> [[String: Any]]) {
        let auth = PhoneAuthStore()
        let router = PhoneHostRouter(config: PhoneHostConfig(environmentID: "e", label: "Test Mac", serverVersion: "1", machine: nil), auth: auth)
        let user = PhoneAuthStore.Session(id: "s", label: "Phone", deviceType: "mobile", os: nil, scopes: scopes,
                                          issuedAt: Date(), expiresAt: Date().addingTimeInterval(60), tokenHash: "")
        var out: [[String: Any]] = []
        let rpc = PhoneRPCSession(session: user, router: router, backend: backend, queue: queue, sequence: { 1 }, transmit: { text in
            if let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { out.append(message) }
        })
        return (rpc, { self.queue.sync { out } })
    }

    private func request(_ rpc: PhoneRPCSession, id: Int, _ tag: String, _ payload: [String: Any] = [:]) {
        let body = try! JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [Any]()])
        queue.sync { rpc.receive(String(decoding: body, as: UTF8.self)) }
    }

    // MARK: - WebSocket

    func testHandshakeAcceptKeyMatchesTheRFCExample() {
        let request = PhoneHTTPRequest(method: "GET", path: "/ws", query: [:], headers: [
            "upgrade": "websocket", "connection": "Upgrade", "sec-websocket-version": "13", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        ], body: Data())
        XCTAssertEqual(PhoneWebSocket.handshake(for: request)?.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    private func masked(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true) -> Data {
        let mask: [UInt8] = [1, 2, 3, 4]
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) } else {
            bytes += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        bytes += mask
        bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(bytes)
    }

    func testDecodesMaskedTextAcrossReadsAndFragments() {
        var decoder = PhoneWebSocket.Decoder()
        let frame = masked(0x1, Array("hello".utf8))
        XCTAssertEqual(decoder.feed(frame.prefix(3)), [])
        XCTAssertEqual(decoder.feed(frame.dropFirst(3)), [.text("hello")])
        XCTAssertEqual(decoder.feed(masked(0x1, Array("he".utf8), fin: false) + masked(0x0, Array("llo".utf8))), [.text("hello")])
        XCTAssertEqual(decoder.feed(masked(0x9, [7])), [.ping(Data([7]))])
        let large = [UInt8](repeating: 0x61, count: 300)
        XCTAssertEqual(decoder.feed(masked(0x1, large)), [.text(String(repeating: "a", count: 300))])
    }

    func testAnUnmaskedClientFrameClosesTheSocket() {
        var decoder = PhoneWebSocket.Decoder()
        XCTAssertEqual(decoder.feed(Data([0x81, 0x01, 0x61])), [.close])
    }

    func testServerFramesAreUnmaskedWithTheRightLengths() {
        XCTAssertEqual([UInt8](PhoneWebSocket.text("hi")), [0x81, 2, 0x68, 0x69])
        let big = [UInt8](PhoneWebSocket.text(String(repeating: "a", count: 200)))
        XCTAssertEqual(Array(big.prefix(4)), [0x81, 126, 0, 200])
    }

    // MARK: - RPC

    func testPingGetsPong() {
        let (rpc, out) = session()
        queue.sync { rpc.receive(#"{"_tag":"Ping"}"#) }
        XCTAssertEqual(out().first?["_tag"] as? String, "Pong")
    }

    func testShellSubscriptionSendsASnapshotOfProjectsAndThreads() {
        let (rpc, out) = session()
        request(rpc, id: 1, "orchestration.subscribeShell", ["requestCompletionMarker": true])
        let chunk = out().first
        XCTAssertEqual(chunk?["_tag"] as? String, "Chunk")
        let values = chunk?["values"] as? [[String: Any]]
        XCTAssertEqual(values?.map { $0["kind"] as? String }, ["snapshot", "synchronized"])
        let snapshot = values?.first?["snapshot"] as? [String: Any]
        XCTAssertEqual((snapshot?["projects"] as? [Any])?.count, 1)
        XCTAssertEqual((snapshot?["threads"] as? [Any])?.count, 1)
    }

    func testAnUnchangedStreamIsNotResentButAChangeIs() {
        let backend = Backend()
        let (rpc, out) = session(backend: backend)
        request(rpc, id: 1, "orchestration.subscribeShell")
        queue.sync { rpc.refresh() }
        XCTAssertEqual(out().count, 1)
        backend.approval = PhoneApproval(id: "r1", kind: "command", prompt: "Bash: ls", createdAt: Date())
        queue.sync { rpc.refresh() }
        XCTAssertEqual(out().count, 2)
    }

    func testMessagesInterruptsAndAnswersReachTheBackend() {
        let backend = Backend()
        let (rpc, out) = session(backend: backend)
        request(rpc, id: 1, "orchestration.dispatchCommand", ["type": "message.dispatch", "commandId": "c1", "threadId": "s:1", "text": "go"])
        request(rpc, id: 2, "orchestration.dispatchCommand", ["type": "run.interrupt", "commandId": "c2", "threadId": "s:1", "runId": "r"])
        request(rpc, id: 3, "orchestration.dispatchCommand", ["type": "runtime-request.respond", "commandId": "c3", "threadId": "s:1",
                                                              "requestId": "r1", "decision": "decline"])
        XCTAssertEqual(backend.sent.first?.1, "go")
        XCTAssertEqual(backend.interrupted, ["s:1"])
        XCTAssertEqual(backend.answers.first?.0, "r1")
        XCTAssertEqual(backend.answers.first?.1, false)
        XCTAssertEqual(out().count, 3)
    }

    func testSwitchingModelsAcrossProvidersContinuesInTheNewThread() {
        let backend = Backend()
        let (rpc, out) = session(backend: backend)
        request(rpc, id: 1, "orchestration.dispatchCommand", ["type": "thread.model-selection.set", "commandId": "c1", "threadId": "s:1",
                                                              "modelSelection": ["instanceId": "codex", "model": "gpt"]])
        XCTAssertEqual(backend.modelChanges.first?.1, "codex")
        XCTAssertEqual(backend.modelChanges.first?.2, "s:1")
        // A message that names another provider goes to the conversation that continues.
        request(rpc, id: 2, "orchestration.dispatchCommand", ["type": "message.dispatch", "commandId": "c2", "threadId": "s:1", "text": "go on",
                                                              "modelSelection": ["instanceId": "codex", "model": "gpt"]])
        XCTAssertEqual(backend.sent.first?.0, "s:1-next")
        XCTAssertEqual(out().count, 2)
    }

    func testServerConfigListsTheProvidersAndTheirModels() {
        let (rpc, out) = session()
        request(rpc, id: 1, "subscribeServerConfig")
        let values = out().first?["values"] as? [[String: Any]]
        let providers = (values?.first?["config"] as? [String: Any])?["providers"] as? [[String: Any]]
        XCTAssertEqual(providers?.map { $0["instanceId"] as? String }, ["claude", "codex"])
        XCTAssertEqual((providers?.first?["models"] as? [[String: Any]])?.count, 2)
    }

    func testACommandOctetCannotDoFailsWithTheTypedError() {
        let (rpc, out) = session()
        request(rpc, id: 1, "orchestration.dispatchCommand", ["type": "thread.delete", "commandId": "c1", "threadId": "s:1"])
        let exit = out().first?["exit"] as? [String: Any]
        let cause = (exit?["cause"] as? [[String: Any]])?.first
        XCTAssertEqual((cause?["error"] as? [String: Any])?["_tag"] as? String, "OrchestrationV2DispatchCommandError")
    }

    func testAPhoneWithoutOperateCannotDispatch() {
        let (rpc, out) = session(scopes: ["orchestration:read"])
        request(rpc, id: 1, "orchestration.dispatchCommand", ["type": "message.dispatch", "commandId": "c1", "threadId": "s:1", "text": "go"])
        let exit = out().first?["exit"] as? [String: Any]
        let error = ((exit?["cause"] as? [[String: Any]])?.first)?["error"] as? [String: Any]
        XCTAssertEqual(error?["_tag"] as? String, "EnvironmentAuthorizationError")
        XCTAssertEqual(error?["requiredScope"] as? String, "orchestration:operate")
    }

    func testUnknownCallsDieAndUnknownStreamsStaySilent() {
        let (rpc, out) = session()
        request(rpc, id: 1, "vcs.pull")
        request(rpc, id: 2, "subscribeVcsStatus")
        let messages = out()
        XCTAssertEqual(messages.count, 1)
        let cause = ((messages[0]["exit"] as? [String: Any])?["cause"] as? [[String: Any]])?.first
        XCTAssertEqual(cause?["_tag"] as? String, "Die")
    }

    func testProjectionHasMessagesRunsAndAnApprovalRequest() {
        let thread = PhoneThread(id: "s:1", projectID: "w1", title: "Fix", agent: "claude", model: nil, status: .waiting,
                                 createdAt: Date(), updatedAt: Date(),
                                 approval: PhoneApproval(id: "r1", kind: "command", prompt: "Bash: ls", createdAt: Date()))
        let items: [PhoneItem] = [.user(id: "m1", text: "hi", at: Date()), .assistant(id: "m2", text: "ok", at: Date()),
                                  .tool(id: "t1", name: "Bash", input: "ls", output: nil, failed: false, at: Date())]
        let projection = PhoneHostWire.projection(thread, items: items)
        XCTAssertEqual((projection["messages"] as? [Any])?.count, 2)
        XCTAssertEqual((projection["runs"] as? [[String: Any]])?.first?["status"] as? String, "waiting")
        XCTAssertEqual((projection["runtimeRequests"] as? [Any])?.count, 1)
        XCTAssertEqual((projection["turnItems"] as? [[String: Any]])?.last?["type"] as? String, "approval_request")
        XCTAssertEqual(PhoneHostWire.slug("My Agent!"), "MyAgent")
        XCTAssertEqual(PhoneHostWire.slug("9lives"), "agent9lives")
    }
}
