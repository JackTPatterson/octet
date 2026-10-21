import XCTest
@testable import Octet

final class IssueMCPTests: XCTestCase {
    func testListDefaultsAndCursorSelectors() throws {
        XCTAssertEqual(try IssueMCP.arguments(action: "list", values: ["tracker": "linear", "container": "team", "cursor": "opaque"]),
                       ["list", "--tracker", "linear", "--container", "team", "--cursor", "opaque", "--limit", "100"])
    }
    func testCurrentReadAndComments() throws {
        XCTAssertEqual(try IssueMCP.arguments(action: "read", values: ["current": true, "include-comments": true, "in": "/tmp/work"]),
                       ["read", "--in", "/tmp/work", "--current", "--include-comments"])
        XCTAssertThrowsError(try IssueMCP.arguments(action: "read", values: ["tracker": "jira"]))
        XCTAssertThrowsError(try IssueMCP.arguments(action: "read", values: ["current": true, "key": "ENG-1"]))
    }
    func testRejectsInvalidTypesAndCLIFlagInjection() {
        for values: [String: Any] in [
            ["tracker": "linear", "container": "--current"],
            ["tracker": "linear", "limit": true], ["tracker": "linear", "limit": 1.5],
            ["tracker": "linear", "limit": 1001], ["tracker": "unknown"],
            ["tracker": "linear", "scope": "deleted"], ["tracker": "linear", "token": "secret"]
        ] { XCTAssertThrowsError(try IssueMCP.arguments(action: "list", values: values)) }
        XCTAssertThrowsError(try IssueMCP.arguments(action: "read", values: ["current": 1]))
    }
    func testNotificationsNeverInvokeTools() async {
        let result = await IssueMCP.respond(to: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"issues_list","arguments":{"tracker":"jira"}}}"#) { _ in
            XCTFail("Notification must not invoke API"); return Data()
        }
        XCTAssertNil(result)
    }
    func testPaginationEnvelopeIsPreserved() async throws {
        let reply = await IssueMCP.respond(to: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"issues_list","arguments":{"tracker":"jira"}}}"#) { args in
            XCTAssertEqual(args, ["list", "--tracker", "jira", "--limit", "100"])
            return Data(#"{"issues":[],"truncated":true,"nextCursor":"next"}"#.utf8)
        }
        let json = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(reply).utf8)) as! [String: Any]
        let result = json["result"] as! [String: Any]
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["nextCursor"] as? String, "next")
    }
    func testToolErrorsAreReportedWithoutCrashingServer() async throws {
        let reply = await IssueMCP.respond(to: #"{"jsonrpc":"2.0","id":"r","method":"tools/call","params":{"name":"issues_read","arguments":{"current":true}}}"#) { _ in
            throw IssueTrackerError.unreadable("No linked issue")
        }
        let json = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(reply).utf8)) as! [String: Any]
        XCTAssertEqual((json["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
    func testAllAdvertisedToolsAreReadOnly() {
        XCTAssertEqual(IssueMCP.tools.count, 4)
        XCTAssertTrue(IssueMCP.tools.allSatisfy { ($0["annotations"] as? [String: Bool])?["readOnlyHint"] == true })
    }
    func testBoardUsesTransitionIDAndRejectsMissingAmbiguousOrSameStatus() throws {
        let done = TrackerStatus(id: "transition-42", name: "Done", closed: true)
        XCTAssertEqual(try IssueBoardMove.resolve(destination: "Done", current: "Open", allowed: [done]), done)
        XCTAssertThrowsError(try IssueBoardMove.resolve(destination: "Done", current: "Open", allowed: []))
        XCTAssertThrowsError(try IssueBoardMove.resolve(destination: "Done", current: "Done", allowed: [done]))
        XCTAssertThrowsError(try IssueBoardMove.resolve(destination: "Done", current: "Open", allowed: [done, .init(id: "other-action", name: "Done", closed: true)]))
    }
}
