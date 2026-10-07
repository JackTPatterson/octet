import XCTest

final class TerminalAccessTests: XCTestCase {
    private func rpc(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
    }

    private func result(_ line: String?) throws -> [String: Any] {
        let reply = try XCTUnwrap(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private let inPane = TerminalControl.Origin(pane: "w1:p2", workspace: "w1")

    func testOnlyAProcessOctetStartedIsInOctet() {
        // A pane of a session Octet started.
        XCTAssertEqual(TerminalControl.Origin.current(["HERDR_PANE_ID": "w1:p2", "HERDR_SOCKET_PATH": "/s/herdr.sock", "HERDR_WORKSPACE_ID": "w1"]),
                       inPane)
        // One of its conversations, which has no pane but is told where the app is.
        XCTAssertEqual(TerminalControl.Origin.current(["OCTET_TERMINAL_SOCKET": "/s/terminal.sock"]),
                       TerminalControl.Origin(pane: nil, workspace: nil))
        // Any other terminal app: not in Octet.
        XCTAssertNil(TerminalControl.Origin.current([:]))
        XCTAssertNil(TerminalControl.Origin.current(["HERDR_PANE_ID": "w1:p2"]))
        XCTAssertNil(TerminalControl.Origin.current(["OCTET_TERMINAL_SOCKET": ""]))
        XCTAssertEqual(inPane.params["from_pane"] as? String, "w1:p2")
        XCTAssertEqual(inPane.params["from_workspace"] as? String, "w1")
        XCTAssertTrue(TerminalControl.Origin(pane: nil, workspace: nil).params.isEmpty)
    }

    func testWhereTheAppIsListening() {
        XCTAssertEqual(TerminalControl.socketPath(session: "octet", home: "/h"), "/h/Library/Application Support/Octet/terminal.sock")
        XCTAssertEqual(TerminalControl.socketPath(session: nil, home: "/h"), "/h/Library/Application Support/Octet/terminal.sock")
        XCTAssertEqual(TerminalControl.socketPath(session: "test", home: "/h"), "/h/Library/Application Support/Octet/sessions/test/terminal.sock")
        XCTAssertEqual(TerminalControl.environment(session: "octet", home: "/h"),
                       ["OCTET_TERMINAL_SOCKET": "/h/Library/Application Support/Octet/terminal.sock"])
        XCTAssertEqual(TerminalControl.resolveSocket(environment: ["OCTET_TERMINAL_SOCKET": "/x/terminal.sock"]), "/x/terminal.sock")
        // A pane from before the variable existed: its server's session says.
        XCTAssertTrue(TerminalControl.resolveSocket(environment: ["HERDR_SOCKET_PATH": "/h/Library/Application Support/Octet/sessions/dev/herdr.sock"])
            .hasSuffix("/sessions/dev/terminal.sock"))
    }

    func testLineCountsAreKeptInRange() {
        XCTAssertEqual(TerminalControl.clampLines(nil), 80)
        XCTAssertEqual(TerminalControl.clampLines(20), 20)
        XCTAssertEqual(TerminalControl.clampLines(20.0), 20)
        XCTAssertEqual(TerminalControl.clampLines("120"), 120)
        XCTAssertEqual(TerminalControl.clampLines(100_000), 500)
        XCTAssertEqual(TerminalControl.clampLines(0), 80)
        XCTAssertEqual(TerminalControl.clampLines(-5), 80)
        XCTAssertEqual(TerminalControl.clampLines("many"), 80)
    }

    func testTheScreenIsTrimmedToItsLastLines() {
        let screen = "one  \ntwo\nthree\t\nfour\n\n\n   \n"
        let all = TerminalControl.lastLines(screen, count: 500)
        XCTAssertEqual(all.text, "one\ntwo\nthree\nfour")
        XCTAssertEqual(all.total, 4)
        let last = TerminalControl.lastLines(screen, count: 2)
        XCTAssertEqual(last.text, "three\nfour")
        XCTAssertEqual(last.total, 4)
        XCTAssertEqual(TerminalControl.lastLines("", count: 5).text, "")
        XCTAssertEqual(TerminalControl.lastLines("a\r\nb\r\n", count: 5).text, "a\nb")
    }

    func testTheToolIsOfferedOnlyInsideOctet() throws {
        let tools = try result(TerminalMCP.respond(to: rpc("tools/list"), origin: inPane, call: { _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.map { $0["name"] as? String }, ["read_sidebar_terminal"])
        let none = try result(TerminalMCP.respond(to: rpc("tools/list"), origin: nil, call: { _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(none?.count, 0)
        let initialized = try result(TerminalMCP.respond(to: rpc("initialize", params: ["protocolVersion": "2025-03-26"]), origin: inPane, call: { _ in [:] }))
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-03-26")
        XCTAssertTrue((initialized["instructions"] as? String)?.contains("read_sidebar_terminal") == true)
        XCTAssertNil(try result(TerminalMCP.respond(to: rpc("initialize"), origin: nil, call: { _ in [:] }))["instructions"])
        // A notification gets no answer.
        let notification = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]), as: UTF8.self)
        XCTAssertNil(TerminalMCP.respond(to: notification, origin: inPane, call: { _ in [:] }))
    }

    func testReadingAsksTheAppAndFormatsTheAnswer() throws {
        var asked: [String: Any] = [:]
        let reply = TerminalMCP.respond(
            to: rpc("tools/call", params: ["name": "read_sidebar_terminal", "arguments": ["lines": 9999]]), origin: inPane,
            call: { params in
                asked = params
                return ["text": "error: port 3000 in use", "lines": 1, "total_lines": 40, "title": "npm run dev", "shell_running": true]
            })
        let content = try XCTUnwrap(try result(reply)["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "[sidebar terminal · npm run dev · last 1 of 40 lines]\nerror: port 3000 in use")
        XCTAssertEqual(asked["lines"] as? Int, 500)
        XCTAssertEqual(asked["from_pane"] as? String, "w1:p2")
        XCTAssertEqual(asked["from_workspace"] as? String, "w1")
    }

    func testFailuresReachTheAgentAsErrors() throws {
        let off = try result(TerminalMCP.respond(
            to: rpc("tools/call", params: ["name": "read_sidebar_terminal"]), origin: inPane,
            call: { _ in throw TerminalControl.Failure(message: "The sidebar terminal isn't open.") }))
        XCTAssertEqual(off["isError"] as? Bool, true)
        XCTAssertEqual(((off["content"] as? [[String: Any]])?.first?["text"] as? String), "The sidebar terminal isn't open.")
        let outside = try result(TerminalMCP.respond(to: rpc("tools/call", params: ["name": "read_sidebar_terminal"]), origin: nil, call: { _ in [:] }))
        XCTAssertEqual(outside["isError"] as? Bool, true)
        let unknown = try result(TerminalMCP.respond(to: rpc("tools/call", params: ["name": "type_into_terminal"]), origin: inPane, call: { _ in [:] }))
        XCTAssertEqual(unknown["isError"] as? Bool, true)
    }

    func testFormatSaysWhatItIs() {
        XCTAssertEqual(TerminalMCP.format(["text": "a\nb", "lines": 2, "total_lines": 2]), "[sidebar terminal · 2 lines]\na\nb")
        XCTAssertEqual(TerminalMCP.format(["text": "", "lines": 0, "total_lines": 0]), "[sidebar terminal · 0 lines]\n(nothing on screen yet)")
        XCTAssertTrue(TerminalMCP.format(["text": "x", "lines": 1, "shell_running": false]).hasPrefix("[sidebar terminal · the shell has exited"))
    }
}
