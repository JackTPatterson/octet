import XCTest

final class PeerProtocolTests: XCTestCase {
    func testTrustDecidesWhatNeedsSomeoneToSayYes() {
        XCTAssertTrue(PeerTrust.ask.needsApproval(.send))
        XCTAssertTrue(PeerTrust.ask.needsApproval(.delegate))
        XCTAssertFalse(PeerTrust.ask.needsApproval(.agents))
        XCTAssertFalse(PeerTrust.ask.needsApproval(.read))
        XCTAssertFalse(PeerTrust.messages.needsApproval(.send))
        XCTAssertTrue(PeerTrust.messages.needsApproval(.delegate))
        XCTAssertFalse(PeerTrust.messagesAndTasks.needsApproval(.delegate))
    }

    func testAMessageSaysWhoSentItAndHowToAnswer() {
        let from = PeerProtocol.Sender(machine: "Studio", agent: "w2:p1", agentName: "Codex")
        let prompt = PeerProtocol.prompt("Run the tests", from: from, allowed: .approved, here: "Laptop")
        XCTAssertTrue(prompt.hasPrefix("[Message from Codex on Studio, delivered by Octet]\n\nRun the tests"))
        XCTAssertTrue(prompt.contains("The person at Laptop approved delivering this message."))
        XCTAssertTrue(prompt.contains("machine \"Studio\" and agent \"w2:p1\""))
        let script = PeerProtocol.prompt("hi", from: .init(machine: "Studio", agent: nil, agentName: nil), allowed: .trusted, here: "Laptop")
        XCTAssertEqual(script, "[Message from Studio, delivered by Octet]\n\nhi\n\n(The person at Laptop lets Studio send messages without asking.)")
        XCTAssertTrue(PeerProtocol.taskPrompt("Fix it", from: from).hasSuffix("\n\nFix it"))
    }

    func testTheSenderIsTheMachineTheChannelProved() {
        let claimed = PeerProtocol.Sender(["machine": "Someone Else", "agent": "w1:p1"], machine: "Studio")
        XCTAssertEqual(claimed.machine, "Studio")
        XCTAssertEqual(claimed.agent, "w1:p1")
    }

    func testMessagesRoundTripAndAgentsParse() throws {
        let request = PeerProtocol.request(id: "1", method: .send, params: ["text": "hi"])
        let decoded = try XCTUnwrap(PeerProtocol.decode(PeerProtocol.encode(request)))
        XCTAssertEqual(decoded["method"] as? String, "agent.send")
        XCTAssertEqual(PeerProtocol.Agent(["id": "w1:p1", "agent": "claude"])?.status, "unknown")
        XCTAssertNil(PeerProtocol.Agent(["agent": "claude"]))
        XCTAssertEqual(PeerProtocol.tail("a  \nb\nc\n\n  \n", lines: 2), "b\nc")
        XCTAssertEqual(PeerProtocol.tail("\n\na\n\n\n\nb\n", lines: 10), "a\n\nb")
        // layout.apply's answer, as the session server sends it.
        let applied: [String: Any] = ["type": "layout_apply", "layout": ["tab_id": "w1:t3", "focused_pane_id": "w1:p3",
                                                                         "root": ["type": "pane", "pane_id": "w1:p3"]]]
        XCTAssertEqual(PeerProtocol.paneId(inLayoutResult: applied), "w1:p3")
        XCTAssertNil(PeerProtocol.paneId(inLayoutResult: ["type": "ok"]))
    }
}
