import XCTest

final class DelegationTests: XCTestCase {
    private let pane = DelegationControl.Origin(pane: "w1:p1", session: "/s/herdr.sock", depth: 0)

    private func respond(_ request: [String: Any], origin: DelegationControl.Origin?,
                         call: (DelegationControl.Method, [String: Any]) throws -> [String: Any] = { _, _ in [:] }) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let reply = try XCTUnwrap(DelegationMCP.respond(to: line, origin: origin, call: call))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return json["result"] as? [String: Any] ?? [:]
    }

    func testToolsOnlyInsideOctetAndNotForADelegate() throws {
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        XCTAssertEqual((try respond(list, origin: pane)["tools"] as? [Any])?.count, 3)
        XCTAssertEqual((try respond(list, origin: nil)["tools"] as? [Any])?.count, 0)
        let delegate = DelegationControl.Origin(pane: "w1:p2", session: "/s/herdr.sock", depth: 1)
        XCTAssertEqual((try respond(list, origin: delegate)["tools"] as? [Any])?.count, 0)
        let initialize = try respond(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": [:]], origin: pane)
        XCTAssertNotNil(initialize["instructions"])
    }

    func testDelegatingWaitsForTheAnswerByDefault() throws {
        var calls: [DelegationControl.Method] = []
        let result = try respond(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                  "params": ["name": "delegate_to_agent", "arguments": ["agent": "codex", "task": "check retries"]]],
                                 origin: pane) { method, params in
            calls.append(method)
            XCTAssertEqual(params["from_pane"] as? String, "w1:p1")
            return method == .delegate ? ["task": "t1", "status": "running"]
                : ["task": "t1", "status": "done", "verdict": "fail", "result": "- retry.ts:12 no backoff\nVERDICT: FAIL"]
        }
        XCTAssertEqual(calls, [.delegate, .wait])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("- retry.ts:12 no backoff\nVERDICT: FAIL"), "the answer comes first")
        XCTAssertNil(result["isError"])
    }

    func testADelegateCantDelegateAgain() throws {
        let delegate = DelegationControl.Origin(pane: "w1:p2", session: "/s/herdr.sock", depth: 1)
        let result = try respond(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                  "params": ["name": "delegate_to_agent", "arguments": ["agent": "claude", "task": "x"]]],
                                 origin: delegate) { _, _ in
            XCTFail("the app isn't asked")
            return [:]
        }
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testTheDepthComesFromTheEnvironment() {
        let environment = [EngineProtocol.paneIdVariable: "w1:p1", EngineProtocol.socketPathVariable: "/s/herdr.sock",
                           DelegationControl.depthVariable: "1"]
        XCTAssertEqual(DelegationControl.Origin.current(environment)?.depth, 1)
        XCTAssertNil(DelegationControl.Origin.current([:]), "outside Octet there's no origin")
    }

    func testCommands() throws {
        let review = try XCTUnwrap(DelegationPlan.command(agent: "codex", executable: "/bin/codex", mode: .review,
                                                          promptFile: "/d/p", resultFile: "/d/r", doneFile: "/d/done"))
        XCTAssertEqual(review, "OCTET_DELEGATION_DEPTH=1 '/bin/codex' exec review --uncommitted --skip-git-repo-check -o '/d/r' - < '/d/p'; echo $? > '/d/done'")
        let task = try XCTUnwrap(DelegationPlan.command(agent: "codex", executable: "/bin/codex", mode: .task,
                                                        promptFile: "/d/p", resultFile: "/d/r", doneFile: "/d/done"))
        XCTAssertTrue(task.contains("exec -s workspace-write"))
        let claude = try XCTUnwrap(DelegationPlan.command(agent: "claude", executable: "/bin/claude", mode: .review,
                                                          promptFile: "/d/p", resultFile: "/d/r", doneFile: "/d/done"))
        XCTAssertTrue(claude.contains("-p --permission-mode plan < '/d/p' | tee '/d/r'"), "Claude reviews in plan mode, which can't edit")
        XCTAssertNil(DelegationPlan.command(agent: "pi", executable: "/bin/pi", mode: .review, promptFile: "", resultFile: "", doneFile: ""))
    }

    func testAReviewPromptAsksForAVerdict() {
        let prompt = DelegationPlan.prompt(task: "the retry logic", mode: .review, caller: "Claude Code")
        XCTAssertTrue(prompt.contains("Claude Code asked you"))
        XCTAssertTrue(prompt.contains("the retry logic"))
        XCTAssertTrue(prompt.contains("VERDICT: PASS"))
    }

    func testVerdicts() {
        XCTAssertEqual(DelegationVerdict.read("Looks good.\n**VERDICT: PASS**"), DelegationVerdict(outcome: .pass, findings: []))
        XCTAssertEqual(DelegationVerdict.read("- a.ts:3 off by one\n* b.ts: unused\nVERDICT: FAIL"),
                       DelegationVerdict(outcome: .fail, findings: ["a.ts:3 off by one", "b.ts: unused"]))
        XCTAssertEqual(DelegationVerdict.read("no verdict here").outcome, .unknown)
    }
}
