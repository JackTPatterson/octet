import XCTest

final class PhoneHostClientTests: XCTestCase {
    func testReadsTheLinkTheHostShows() {
        let link = PhoneHostLink.parse("http://studio.local:52200/#token=ABCD-1234")
        XCTAssertEqual(link, PhoneHostLink(host: "studio.local", port: 52200, code: "ABCD-1234"))
    }

    func testReadsAnAddressAndACode() {
        XCTAssertEqual(PhoneHostLink.parse(" 100.64.0.2:52200  ABCD-1234 "), PhoneHostLink(host: "100.64.0.2", port: 52200, code: "ABCD-1234"))
        XCTAssertEqual(PhoneHostLink.parse("mac.local:52201#token=XY"), PhoneHostLink(host: "mac.local", port: 52201, code: "XY"))
        XCTAssertNil(PhoneHostLink.parse("hello"))
        XCTAssertNil(PhoneHostLink.parse("mac.local CODE"))
        XCTAssertNil(PhoneHostLink.parse("http://mac.local:52200/"))
    }

    func testWhatTheHostWritesIsWhatTheClientReads() {
        let project = PhoneProject(id: "w1", title: "octet", folder: "/Users/t/octet", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
        let approval = PhoneApproval(id: "r1", kind: "command", prompt: "Bash: ls", createdAt: Date(timeIntervalSince1970: 150))
        let thread = PhoneThread(id: "s:1", projectID: "w1", title: "Fix", agent: "claude", model: "opus", status: .waiting,
                                 createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200), approval: approval)
        let items: [PhoneItem] = [
            .user(id: "m1", text: "hi", at: Date(timeIntervalSince1970: 110)),
            .assistant(id: "m2", text: "hello", at: Date(timeIntervalSince1970: 120)),
            .tool(id: "t1", name: "Bash", input: "ls", output: "a\nb", failed: false, at: Date(timeIntervalSince1970: 130)),
        ]
        let shell = PhoneHostReader.shell(PhoneHostWire.shellSnapshot(projects: [project], threads: [(thread, items)], sequence: 1))
        XCTAssertEqual(shell.projects, [project])
        XCTAssertEqual(shell.threads.first?.id, "s:1")
        XCTAssertEqual(shell.threads.first?.status, .waiting)
        XCTAssertEqual(shell.threads.first?.model, "opus")
        XCTAssertEqual(shell.threads.first?.approval?.id, "r1")

        let read = PhoneHostReader.projection(PhoneHostWire.projection(thread, items: items))
        XCTAssertEqual(read.items, items)
        XCTAssertEqual(read.approval?.prompt, "Bash: ls")
    }

    func testAFailedExitCarriesTheHostsMessage() {
        let exit: [String: Any] = ["_tag": "Failure", "cause": [["_tag": "Fail", "error": ["message": "No such agent."]]]]
        guard case .failure(let error) = PhoneHostConnection.result(of: exit) else { return XCTFail("should fail") }
        XCTAssertEqual(error, .failed("No such agent."))
        guard case .success = PhoneHostConnection.result(of: ["_tag": "Success", "value": NSNull()]) else { return XCTFail("should succeed") }
    }
}

/// A real server on loopback and a real client talking to it.
final class PhoneHostClientEndToEndTests: XCTestCase {
    func testAMacPairsReadsAndMessagesAnother() async throws {
        let backend = PhoneHostRPCTests.Backend()
        let auth = PhoneAuthStore()
        let router = PhoneHostRouter(config: PhoneHostConfig(environmentID: "env-9", label: "Studio", serverVersion: "1", machine: "desktop"), auth: auth)
        let server = PhoneHostServer(router: router, backend: backend)
        try server.start(port: nil, loopbackOnly: true)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let code = auth.createPairing().credential
        let link = try XCTUnwrap(PhoneHostLink.parse("http://127.0.0.1:\(port)/#token=\(code)"))
        let paired = try await PhoneHostConnection.pair(link: link, label: "Laptop")
        XCTAssertEqual(paired.environmentID, "env-9")
        XCTAssertEqual(paired.name, "Studio")
        XCTAssertEqual(auth.allSessions().count, 1)

        // A used code is spent.
        do { _ = try await PhoneHostConnection.pair(link: link, label: "Again"); XCTFail("code reused") } catch {}

        let connection = PhoneHostConnection(baseURL: try XCTUnwrap(link.baseURL), token: paired.token)
        let shell = expectation(description: "shell")
        let thread = expectation(description: "thread")
        connection.onShell = { projects, threads in
            if projects.first?.title == "octet", threads.first?.id == "s:1" { shell.fulfill() }
        }
        connection.onThread = { id, items, _ in
            if id == "s:1", items.count == 1 { thread.fulfill() }
        }
        connection.start()
        defer { connection.stop() }
        await fulfillment(of: [shell], timeout: 10)
        connection.watch(thread: "s:1")
        await fulfillment(of: [thread], timeout: 10)

        let sent = expectation(description: "sent")
        connection.send("from the laptop", to: "s:1") { result in
            if case .success = result { sent.fulfill() }
        }
        await fulfillment(of: [sent], timeout: 10)
        XCTAssertEqual(backend.sent.first?.1, "from the laptop")
    }

    func testARemovedMacIsToldItsTokenIsNoLongerGood() async throws {
        let auth = PhoneAuthStore()
        let router = PhoneHostRouter(config: PhoneHostConfig(environmentID: "e", label: "Studio", serverVersion: "1", machine: nil), auth: auth)
        let server = PhoneHostServer(router: router, backend: PhoneHostRPCTests.Backend())
        try server.start(port: nil, loopbackOnly: true)
        defer { server.stop() }
        let connection = PhoneHostConnection(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(server.port))")!, token: "stale")
        let revoked = expectation(description: "revoked")
        connection.onState = { if $0 == .revoked { revoked.fulfill() } }
        connection.start()
        defer { connection.stop() }
        await fulfillment(of: [revoked], timeout: 10)
    }
}
