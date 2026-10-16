import XCTest

final class PeerPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21

    // MARK: Status lines

    func testOnlineSaysHowManyAgents() {
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 3, issue: nil, lastSeen: nil, now: now),
                       .init(text: "Online · 3 agents", tone: .online))
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 1, issue: nil, lastSeen: nil, now: now).text, "Online · 1 agent")
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 0, issue: nil, lastSeen: nil, now: now).text, "Online · No agents")
        XCTAssertEqual(PeerPresentation.status(online: true, agents: nil, issue: nil, lastSeen: nil, now: now).text, "Online")
    }

    func testOfflineSaysWhenItWasLastSeen() {
        let status = PeerPresentation.status(online: false, agents: 2, issue: nil, lastSeen: now.addingTimeInterval(-2 * 3600), now: now)
        XCTAssertEqual(status, .init(text: "Last seen 2h ago", tone: .idle))
        XCTAssertEqual(PeerPresentation.status(online: false, agents: nil, issue: nil, lastSeen: nil, now: now).text, "Not seen yet")
    }

    func testAnIssueWinsOverOnlineButAStaleOfflineDoesNot() {
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 2, issue: .refused, lastSeen: nil, now: now),
                       .init(text: "Declined", tone: .error))
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 2, issue: .offline, lastSeen: nil, now: now).text,
                       "Online · 2 agents")
        XCTAssertEqual(PeerPresentation.status(online: false, agents: nil, issue: .offline, lastSeen: now.addingTimeInterval(-90), now: now).text,
                       "Last seen 1m ago")
        XCTAssertEqual(PeerPresentation.status(online: true, agents: nil, issue: .versionTooOld, lastSeen: nil, now: now).tone, .warning)
    }

    func testAnOlderOctetThereIsFlagged() {
        let status = PeerPresentation.status(online: true, agents: 1, issue: nil, lastSeen: nil,
                                             remoteVersion: "0.1.0", localVersion: "0.2.0", now: now)
        XCTAssertEqual(status, .init(text: "Online · 1 agent · Octet 0.1.0", tone: .warning))
        XCTAssertEqual(PeerPresentation.status(online: true, agents: 1, issue: nil, lastSeen: nil,
                                               remoteVersion: "0.2.0", localVersion: "0.2.0", now: now).tone, .online)
    }

    func testLastSeenIsCoarse() {
        XCTAssertEqual(PeerPresentation.lastSeenText(now.addingTimeInterval(-20), now: now), "Last seen just now")
        XCTAssertEqual(PeerPresentation.lastSeenText(now.addingTimeInterval(-5 * 60), now: now), "Last seen 5m ago")
        XCTAssertEqual(PeerPresentation.lastSeenText(now.addingTimeInterval(-23 * 3600), now: now), "Last seen 23h ago")
        XCTAssertEqual(PeerPresentation.lastSeenText(now.addingTimeInterval(-3 * 86_400), now: now), "Last seen 3 days ago")
        XCTAssertEqual(PeerPresentation.lastSeenText(now.addingTimeInterval(30), now: now), "Last seen just now")
        XCTAssertTrue(PeerPresentation.lastSeenText(now.addingTimeInterval(-40 * 86_400), now: now).hasPrefix("Last seen Aug"))
    }

    func testLastSeenYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!
        let yesterdayEvening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 7))!
        XCTAssertEqual(PeerPresentation.lastSeenText(yesterdayEvening, now: morning.addingTimeInterval(3600), calendar: calendar),
                       "Last seen yesterday")
    }

    func testLatencyAndElapsed() {
        XCTAssertEqual(PeerPresentation.latency(0.0004), "<1 ms")
        XCTAssertEqual(PeerPresentation.latency(0.012), "12 ms")
        XCTAssertEqual(PeerPresentation.latency(1.24), "1.2 s")
        XCTAssertEqual(PeerPresentation.elapsed(since: now.addingTimeInterval(-45), now: now), "45s")
        XCTAssertEqual(PeerPresentation.elapsed(since: now.addingTimeInterval(-185), now: now), "3m")
        XCTAssertEqual(PeerPresentation.elapsed(since: now.addingTimeInterval(-4800), now: now), "1h 20m")
        XCTAssertEqual(PeerPresentation.elapsed(since: now.addingTimeInterval(-7200), now: now), "2h")
    }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(PeerPresentation.isOlder("0.9.2", than: "0.10.0"))
        XCTAssertFalse(PeerPresentation.isOlder("0.10.0", than: "0.9.2"))
        XCTAssertFalse(PeerPresentation.isOlder("1.2", than: "1.2.0"))
        XCTAssertTrue(PeerPresentation.isOlder("1.2", than: "1.2.1"))
        XCTAssertFalse(PeerPresentation.isOlder("1.3.0-beta", than: "1.3.0"))
    }

    func testAddressesAreTypeable() {
        XCTAssertEqual(PeerPresentation.address(host: "Studio.local.", port: 52100), "Studio.local:52100")
        XCTAssertEqual(PeerPresentation.address(host: "fe80::1", port: 52100), "[fe80::1]:52100")
        XCTAssertNil(PeerPresentation.address(host: "studio.local", port: nil))
        XCTAssertNil(PeerPresentation.address(host: " ", port: 1))
    }

    // MARK: Issues

    func testIssuesAreSortedByWhatToDo() {
        typealias Issue = PeerPresentation.Issue
        XCTAssertEqual(Issue(code: "unavailable", message: "Studio isn't reachable. Is Octet open there, with other Macs allowed?"), .offline)
        XCTAssertEqual(Issue(code: "declined", message: "The person at Studio declined."), .refused)
        XCTAssertEqual(Issue(code: nil, message: "The person at Studio declined."), .refused)
        XCTAssertEqual(Issue(code: "bad_request", message: "Unknown request."), .versionTooOld)
        XCTAssertEqual(Issue(code: nil, message: "Unknown request."), .versionTooOld)
        XCTAssertEqual(Issue(code: "bad_request", message: "A task needs agent_type, folder and task."),
                       .other("A task needs agent_type, folder and task."))
        XCTAssertEqual(Issue(code: "unavailable", message: "No answer within 20 s."), .timedOut)
        XCTAssertEqual(Issue(code: nil, message: "Other Macs is off. Turn it on in Octet's Settings › Other Macs."), .off)
        XCTAssertEqual(Issue(code: nil, message: "Studio answered with a different identity than it paired with."), .identityChanged)
        XCTAssertEqual(Issue(code: nil, message: "That Mac isn't paired with this one."), .notPaired)
    }

    func testIssueAdviceNamesTheMachine() {
        XCTAssertTrue(PeerPresentation.Issue.offline.advice(machine: "Studio").contains("Open Octet on Studio"))
        XCTAssertTrue(PeerPresentation.Issue.versionTooOld.advice(machine: "Studio").contains("Update Octet there"))
        XCTAssertEqual(PeerPresentation.Issue.other("Boom.").advice(machine: "Studio"), "Boom.")
    }

    func testTaskAndAgentStatusWords() {
        XCTAssertEqual(PeerPresentation.taskStatus("working"), .init(text: "Working", tone: .online))
        XCTAssertEqual(PeerPresentation.taskStatus("closed").text, "Tab closed there")
        XCTAssertEqual(PeerPresentation.taskStatus("blocked").tone, .warning)
        XCTAssertEqual(PeerPresentation.taskStatus("paused").text, "Paused")
        XCTAssertEqual(PeerPresentation.agentStatus("blocked"), "Needs input")
        XCTAssertEqual(PeerPresentation.agentStatus("zzz"), "Unknown")
    }

    func testPairingFailuresArePlain() {
        XCTAssertEqual(PeerPresentation.pairingFailure("The pairing was declined.", machine: "Studio"),
                       "Studio didn't pair: someone said no, or the codes didn't match.")
        XCTAssertTrue(PeerPresentation.pairingFailure("POSIXErrorCode(rawValue: 61): Connection refused", machine: nil)
            .hasPrefix("Nothing answered at that address"))
        XCTAssertEqual(PeerPresentation.pairingFailure("Something odd", machine: "Studio"), "Something odd")
    }

    // MARK: Pairing steps

    func testPairingWalksChooseCompareDone() {
        var step = PeerPairingStep.choose
        XCTAssertEqual(step.stage, 0)
        step = .connecting(machine: "Studio")
        XCTAssertEqual(step.stage, 1)
        step = step.receivedCode(machine: "Studio", code: "123 456", fingerprint: "ABCD-1234", incoming: false)
        XCTAssertEqual(step, .confirm(machine: "Studio", code: "123 456", fingerprint: "ABCD-1234", incoming: false))
        XCTAssertTrue(step.awaitsAnswer)
        step = step.answered(true)
        XCTAssertEqual(step, .waiting(machine: "Studio"))
        XCTAssertFalse(step.awaitsAnswer)
        step = step.finished(machine: nil, error: nil)
        XCTAssertEqual(step, .paired(machine: "Studio"))
        XCTAssertTrue(step.isFinished)
        XCTAssertEqual(step.stage, 2)
    }

    func testASecondCodeDoesNotReplaceTheOneBeingCompared() {
        let step = PeerPairingStep.confirm(machine: "Studio", code: "111 111", fingerprint: "A", incoming: true)
        XCTAssertEqual(step.receivedCode(machine: "Laptop", code: "222 222", fingerprint: "B", incoming: true), step)
    }

    func testSayingNoOrFailingEndsInFailed() {
        let step = PeerPairingStep.confirm(machine: "Studio", code: "111 111", fingerprint: "A", incoming: true)
        XCTAssertEqual(step.answered(false), .failed(machine: "Studio", reason: "You didn't pair with Studio."))
        let failed = PeerPairingStep.waiting(machine: "Studio").finished(machine: nil, error: "The pairing was declined.")
        XCTAssertEqual(failed, .failed(machine: "Studio", reason: "Studio didn't pair: someone said no, or the codes didn't match."))
        XCTAssertEqual(PeerPairingStep.choose.answered(true), .choose)
    }
}
