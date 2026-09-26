import XCTest

final class PhonePushTests: XCTestCase {
    private func event(_ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(id: "e", kind: kind, agent: "claude", paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1",
                   label: "api", workedFor: nil, at: Date())
    }

    func testANeedsYouNoticeGoesOutUrgent() throws {
        let request = try XCTUnwrap(PhonePush.request(server: "", topic: "octet-7fq2k", event: event(.needsInput), agentName: "Claude Code"))
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/octet-7fq2k")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Title"), "Claude Code needs you")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Priority"), "high")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), "Claude Code needs you in api")
    }

    func testOwnServerAndBadTopics() throws {
        let own = try XCTUnwrap(PhonePush.request(server: "https://ntfy.example.com", topic: "t", event: event(.finished), agentName: "Codex"))
        XCTAssertEqual(own.url?.absoluteString, "https://ntfy.example.com/t")
        XCTAssertEqual(own.value(forHTTPHeaderField: "Priority"), "default")
        XCTAssertNil(PhonePush.request(server: "", topic: "", event: event(.finished), agentName: "x"))
        XCTAssertNil(PhonePush.request(server: "", topic: "../admin", event: event(.finished), agentName: "x"))
        XCTAssertNil(PhonePush.request(server: "file:///etc", topic: "t", event: event(.finished), agentName: "x"))
    }
}
