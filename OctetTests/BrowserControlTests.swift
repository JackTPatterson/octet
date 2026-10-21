import XCTest

final class BrowserControlTests: XCTestCase {
    private func rpc(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
    }

    private func result(_ line: String?) throws -> [String: Any] {
        let reply = try XCTUnwrap(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private let inPane = BrowserControl.Origin(pane: "w1:p2", workspace: "w1")
    private lazy var folder: String = {
        let path = NSTemporaryDirectory() + "browser-control-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    func testOnlyAProcessOctetStartedIsInOctet() {
        XCTAssertNil(BrowserControl.Origin.current([:]))
        XCTAssertNil(BrowserControl.Origin.current([EngineProtocol.paneIdVariable: "p1"]))
        XCTAssertEqual(BrowserControl.Origin.current([EngineProtocol.paneIdVariable: "p1", EngineProtocol.socketPathVariable: "/s",
                                                      EngineProtocol.workspaceIdVariable: "w1"]),
                       BrowserControl.Origin(pane: "p1", workspace: "w1"))
        XCTAssertEqual(BrowserControl.Origin.current([BrowserControl.socketVariable: "/b"]), BrowserControl.Origin(pane: nil, workspace: nil))
    }

    func testWhereTheAppIsListening() {
        XCTAssertEqual(BrowserControl.socketPath(session: nil, home: "/h"), "/h/Library/Application Support/Octet/browser.sock")
        XCTAssertEqual(BrowserControl.socketPath(session: "dev", home: "/h"), "/h/Library/Application Support/Octet/sessions/dev/browser.sock")
        XCTAssertEqual(BrowserControl.resolveSocket(environment: [BrowserControl.socketVariable: "/x.sock"]), "/x.sock")
    }

    /// The same tools as chrome-devtools MCP, by name.
    func testTheToolsAreChromeDevToolsMCPs() throws {
        let tools = try XCTUnwrap(try result(BrowserMCP.respond(to: rpc("tools/list"), origin: inPane, cwd: folder, call: { _, _ in [:] }))["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["click", "close_page", "drag", "emulate", "evaluate_script", "fill", "fill_form", "get_console_message",
                               "get_css_styles", "get_network_request", "handle_dialog", "hover", "lighthouse_audit", "list_console_messages",
                               "list_network_requests", "list_pages", "navigate_page", "new_page", "performance_analyze_insight",
                               "performance_start_trace", "performance_stop_trace", "press_key", "resize_page", "select_page",
                               "take_screenshot", "take_snapshot", "type_text", "upload_file", "wait_for"])
        // pageId is optional here: it defaults to the agent's own page.
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertFalse((schema["required"] as? [String] ?? []).contains("pageId") && tool["name"] as? String != "select_page" && tool["name"] as? String != "close_page")
        }
        let none = try result(BrowserMCP.respond(to: rpc("tools/list"), origin: nil, cwd: folder, call: { _, _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(none?.count, 0)
        XCTAssertNotNil(try result(BrowserMCP.respond(to: rpc("initialize"), origin: inPane, cwd: folder, call: { _, _ in [:] }))["instructions"])
        XCTAssertNil(try result(BrowserMCP.respond(to: rpc("initialize"), origin: nil, cwd: folder, call: { _, _ in [:] }))["instructions"])
    }

    func testACallAsksTheAppWithItsArguments() throws {
        var asked: (String, [String: Any])?
        let reply = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "click", "arguments": ["uid": "ab_3"]]),
                                                  origin: inPane, cwd: folder, call: { tool, arguments in
            asked = (tool, arguments)
            return ["text": "Clicked button \"Save\""]
        }))
        XCTAssertEqual(asked?.0, "click")
        XCTAssertEqual(asked?.1["uid"] as? String, "ab_3")
        XCTAssertEqual(text(reply), "Clicked button \"Save\"")
        XCTAssertNil(reply["isError"])
    }

    func testFailuresReachTheAgentAsErrors() throws {
        let failed = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "take_snapshot"]), origin: inPane, cwd: folder, call: { _, _ in
            throw BrowserControl.Failure(message: "No page.")
        }))
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual(text(failed), "No page.")
        let outside = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "take_snapshot"]), origin: nil, cwd: folder, call: { _, _ in [:] }))
        XCTAssertEqual(outside["isError"] as? Bool, true)
        let unknown = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "install_extension"]), origin: inPane, cwd: folder, call: { _, _ in
            XCTFail("an unknown tool mustn't reach the app")
            return [:]
        }))
        XCTAssertEqual(unknown["isError"] as? Bool, true)
    }

    func testAScreenshotComesBackAsAnImageOrGoesToAFile() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let answer: [String: Any] = ["text": "Took a screenshot.", "image": ["data": png, "mimeType": "image/png"]]
        let inline = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "take_screenshot"]), origin: inPane, cwd: folder, call: { _, _ in answer }))
        let content = try XCTUnwrap(inline["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/png")

        let saved = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "take_screenshot", "arguments": ["filePath": "shots/page.png"]]),
                                                  origin: inPane, cwd: folder, call: { _, _ in answer }))
        XCTAssertEqual((saved["content"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(FileManager.default.contents(atPath: folder + "/shots/page.png"), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(text(saved).contains(folder + "/shots/page.png"))
    }

    func testASnapshotCanGoToAFile() throws {
        let reply = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "take_snapshot", "arguments": ["filePath": "snap.txt"]]),
                                                  origin: inPane, cwd: folder, call: { _, _ in ["text": "uid=a_1 RootWebArea \"x\"", "summary": "Snapshot (1 lines)."] }))
        XCTAssertEqual(String(decoding: FileManager.default.contents(atPath: folder + "/snap.txt") ?? Data(), as: UTF8.self), "uid=a_1 RootWebArea \"x\"")
        XCTAssertFalse(text(reply).contains("RootWebArea"))
    }

    func testUploadsAreReadHereAndSentAsBase64() throws {
        FileManager.default.createFile(atPath: folder + "/a.txt", contents: Data("hello".utf8))
        var sent: [[String: Any]] = []
        _ = BrowserMCP.respond(to: rpc("tools/call", params: ["name": "upload_file", "arguments": ["uid": "u_1", "filePaths": ["a.txt"]]]),
                               origin: inPane, cwd: folder, call: { _, arguments in
            sent = arguments["files"] as? [[String: Any]] ?? []
            return ["text": "Uploaded"]
        })
        XCTAssertEqual(sent.first?["name"] as? String, "a.txt")
        XCTAssertEqual(sent.first?["type"] as? String, "text/plain")
        XCTAssertEqual(sent.first?["data"] as? String, Data("hello".utf8).base64EncodedString())

        let missing = try result(BrowserMCP.respond(to: rpc("tools/call", params: ["name": "upload_file", "arguments": ["uid": "u_1", "filePaths": ["nope.bin"]]]),
                                                    origin: inPane, cwd: folder, call: { _, _ in XCTFail("nothing to send"); return [:] }))
        XCTAssertEqual(missing["isError"] as? Bool, true)
    }

    func testPathsResolveAgainstTheAgentsFolder() {
        XCTAssertEqual(BrowserMCP.resolve("out/x.png", cwd: "/w"), "/w/out/x.png")
        XCTAssertEqual(BrowserMCP.resolve("/tmp/x.png", cwd: "/w"), "/tmp/x.png")
        XCTAssertEqual(BrowserMCP.resolve("~/x.png", cwd: "/w"), NSHomeDirectory() + "/x.png")
    }
}
