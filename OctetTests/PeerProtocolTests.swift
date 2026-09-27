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
        let prompt = PeerProtocol.prompt("Run the tests", from: from)
        XCTAssertTrue(prompt.hasPrefix("[Message from Codex on Studio, over Octet]\n\nRun the tests"))
        XCTAssertTrue(prompt.contains("machine \"Studio\" and agent \"w2:p1\""))
        let script = PeerProtocol.prompt("hi", from: .init(machine: "Studio", agent: nil, agentName: nil))
        XCTAssertEqual(script, "[Message from Studio, over Octet]\n\nhi")
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
    }
}
