import XCTest

final class PeerMCPTests: XCTestCase {
    private let inOctet = PeerControl.Origin(pane: "w1:p3", session: "/s/herdr.sock")

    private func answer(_ request: [String: Any], origin: PeerControl.Origin?? = .none,
                        call: (PeerControl.Method, [String: Any]) throws -> [String: Any] = { _, _ in [:] }) -> [String: Any]? {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return PeerMCP.respond(to: line, origin: origin ?? inOctet, instructions: { "Hi from Octet" }, call: call)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testListsItsToolsWithSchemas() {
        let tools = ((answer(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["list_machines", "list_agents", "send_to_agent", "read_agent", "delegate_task", "wait_for_task"])
        let delegate = tools.first { $0["name"] as? String == "delegate_task" }
        XCTAssertEqual(((delegate?["inputSchema"] as? [String: Any])?["required"] as? [String]), ["machine", "agent_type", "folder", "task"])
    }

    func testAToolCallAsksTheAppAndSaysWhichPaneAsked() {
        var asked: (PeerControl.Method, [String: Any])?
        let reply = answer(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": ["name": "send_to_agent", "arguments": ["machine": "Studio", "agent": "w2:p1", "message": "hi"]]]) {
            asked = ($0, $1)
            return ["delivered": true]
        }
        XCTAssertEqual(asked?.0, .send)
        XCTAssertEqual(asked?.1["text"] as? String, "hi")
        XCTAssertEqual(asked?.1["from_pane"] as? String, "w1:p3")
        XCTAssertEqual(asked?.1["from_session"] as? String, "/s/herdr.sock")
        let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertTrue(content?.contains("\"delivered\" : true") == true, content ?? "")
    }

    func testDelegateWithWaitStartsThenWaits() {
        var methods: [PeerControl.Method] = []
        _ = answer(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": ["name": "delegate_task", "arguments": ["machine": "Studio", "agent_type": "claude",
                                                                      "folder": "/x", "task": "t", "wait": true]]]) { method, _ in
            methods.append(method)
            return method == .delegate ? ["task": "abc"] : ["status": "done"]
        }
        XCTAssertEqual(methods, [.delegate, .wait])
    }

    func testFailuresComeBackAsToolErrors() {
        let reply = answer(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                            "params": ["name": "list_agents", "arguments": ["machine": "Nope"]]]) { _, _ in
            throw PeerControl.Failure(message: "No Mac named Nope is paired.")
        }
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertNil(answer(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testFindsTheAppsSocketFromWhereItRuns() {
        XCTAssertEqual(PeerControl.socketPath(session: nil, home: "/Users/me"), "/Users/me/Library/Application Support/Octet/peers.sock")
        XCTAssertEqual(PeerControl.socketPath(session: "e2e", home: "/Users/me"),
                       "/Users/me/Library/Application Support/Octet/sessions/e2e/peers.sock")
        XCTAssertEqual(PeerControl.resolveSocket(explicit: nil, environment: ["OCTET_PEERS_SOCKET": "/s"]), "/s")
        XCTAssertEqual(PeerControl.session(ofServer: "/Users/me/.config/herdr/sessions/e2e-b/herdr.sock"), "e2e-b")
        XCTAssertNil(PeerControl.session(ofServer: "/Users/me/.config/herdr/herdr.sock"))
    }

    /// A claude started in another terminal still launches the server (it's
    /// in the user's config), but gets no tools and no instructions there.
    func testOutsideOctetThereAreNoToolsAndCallsAreRefused() {
        let initialize = answer(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]], origin: .some(nil))
        XCTAssertNil((initialize?["result"] as? [String: Any])?["instructions"])
        let list = answer(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], origin: .some(nil))
        XCTAssertEqual(((list?["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        var called = false
        let call = answer(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_machines", "arguments": [:]]],
                          origin: .some(nil)) { _, _ in called = true; return [:] }
        XCTAssertFalse(called)
        XCTAssertEqual((call?["result"] as? [String: Any])?["isError"] as? Bool, true)
        // Inside Octet the agent is told about the feature on start.
        let inside = answer(["jsonrpc": "2.0", "id": 4, "method": "initialize", "params": [:]])
        XCTAssertEqual((inside?["result"] as? [String: Any])?["instructions"] as? String, "Hi from Octet")
    }

    func testOnlyAnOctetPaneCountsAsInsideOctet() {
        let pane = ["HERDR_PANE_ID": "w1:p1", "HERDR_SOCKET_PATH": "/s/herdr.sock"]
        XCTAssertEqual(PeerControl.Origin.current(pane.merging(["OCTET_PEERS_SOCKET": "/p"]) { $1 })?.pane, "w1:p1")
        XCTAssertNotNil(PeerControl.Origin.current(pane.merging(["OCTET_CLI": "/c"]) { $1 }))
        XCTAssertNil(PeerControl.Origin.current(pane), "a plain herdr pane, not Octet's")
        XCTAssertNil(PeerControl.Origin.current(["OCTET_CLI": "/c"]), "not in a pane at all")
    }

    func testTheInstructionsNameTheMacsAndHowToUseThem() {
        let text = PeerMCP.instructions(machines: ["this_machine": "Laptop", "on": true,
                                                   "machines": [["name": "Studio", "online": true], ["name": "Mini", "online": false]]])
        XCTAssertTrue(text.contains("inside Octet on Laptop"))
        XCTAssertTrue(text.contains("Studio (online), Mini (not connected right now)"))
        XCTAssertTrue(text.contains("delegate_task"))
        XCTAssertTrue(PeerMCP.instructions(machines: ["this_machine": "Laptop", "on": true, "machines": []]).contains("none are paired yet"))
        XCTAssertTrue(PeerMCP.instructions(machines: ["on": false]).contains("turned off"))
    }
}
