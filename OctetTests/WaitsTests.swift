import XCTest

final class WaitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func parse(_ text: String) -> WaitCondition? {
        WaitCondition.parse(text, now: now, calendar: calendar, home: "/Users/me")
    }

    func testPullRequestsInTheirUsualSpellings() {
        XCTAssertEqual(parse("https://github.com/acme/api/pull/142"), .pullRequest(repo: "acme/api", number: 142, event: .merged))
        XCTAssertEqual(parse("acme/api#142 approved"), .pullRequest(repo: "acme/api", number: 142, event: .approved))
        XCTAssertEqual(parse("pr:acme/api#7 checks pass"), .pullRequest(repo: "acme/api", number: 7, event: .checksPass))
        XCTAssertEqual(parse("acme/api#7 when CI is done"), .pullRequest(repo: "acme/api", number: 7, event: .checksDone))
        XCTAssertEqual(parse("https://github.com/acme/api/pull/9 closed"), .pullRequest(repo: "acme/api", number: 9, event: .closed))
    }

    func testReleasesPackagesPagesFilesAndCommands() {
        XCTAssertEqual(parse("release:acme/cli"), .release(repo: "acme/cli", tag: nil))
        XCTAssertEqual(parse("release:acme/cli v2.0.0"), .release(repo: "acme/cli", tag: "v2.0.0"))
        XCTAssertEqual(parse("https://github.com/acme/cli/releases/tag/v3"), .release(repo: "acme/cli", tag: "v3"))
        XCTAssertEqual(parse("npm:react@19.1.0"), .package(registry: .npm, name: "react", version: "19.1.0"))
        XCTAssertEqual(parse("npm:@scope/kit@2.0.0"), .package(registry: .npm, name: "@scope/kit", version: "2.0.0"))
        XCTAssertEqual(parse("npm:@scope/kit"), .package(registry: .npm, name: "@scope/kit", version: nil))
        XCTAssertEqual(parse("pypi:requests==3.0"), .package(registry: .pypi, name: "requests", version: "3.0"))
        XCTAssertEqual(parse("https://status.acme.dev"), .url("https://status.acme.dev", page: .up))
        XCTAssertEqual(parse("url:https://acme.dev/changelog changes"), .url("https://acme.dev/changelog", page: .changes))
        XCTAssertEqual(parse("url:https://acme.dev contains: \"v2 is live\""), .url("https://acme.dev", page: .contains("v2 is live")))
        XCTAssertEqual(parse("file:~/Downloads/cert.p12"), .file("/Users/me/Downloads/cert.p12"))
        XCTAssertEqual(parse("command:dig +short api.acme.dev | grep -q ."), .command("dig +short api.acme.dev | grep -q ."))
        XCTAssertEqual(parse("Apple approves the app"), .manual("Apple approves the app"))
        XCTAssertNil(parse("   "))
    }

    func testDates() {
        XCTAssertEqual(parse("in 3 days"), .date(now.addingTimeInterval(3 * 86_400)))
        XCTAssertEqual(parse("in 90 minutes"), .date(now.addingTimeInterval(90 * 60)))
        XCTAssertEqual(parse("date:2026-11-03"), .date(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!))
        XCTAssertEqual(parse("2026-11-03 14:30"), .date(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 30))!))
        guard case .date(let tomorrow) = parse("tomorrow") else { return XCTFail("tomorrow") }
        XCTAssertEqual(calendar.component(.hour, from: tomorrow), 9)
        XCTAssertGreaterThan(tomorrow, now)
        XCTAssertEqual(parse("date:someday"), .manual("date:someday"))
    }

    private func pr(state: String, review: String? = nil, checks: GitHubPullRequest.Checks = .none) -> GitHubPullRequest {
        GitHubPullRequest(number: 1, title: "t", state: state, url: URL(string: "https://github.com/a/b/pull/1")!,
                          isDraft: false, reviewDecision: review, checks: checks)
    }

    func testPullRequestEvents() {
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "MERGED"), event: .merged), .met("Merged"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "CLOSED"), event: .merged), .met("Closed without merging"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "OPEN", checks: .pending), event: .merged), .notYet("Checks running"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "OPEN", review: "APPROVED"), event: .approved), .met("Approved"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "OPEN", checks: .passing), event: .checksPass), .met("Checks passed"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "OPEN", checks: .failing), event: .checksPass), .notYet("Checks failing"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "OPEN", checks: .failing), event: .checksDone), .met("Checks failed"))
        XCTAssertEqual(WaitEvaluation.pullRequest(pr(state: "CLOSED"), event: .closed), .met("Closed"))
    }

    func testNewReleasesAndVersionsAreMeasuredFromWhenTheWaitWasSet() {
        // First check: remembers what's there.
        var result = WaitEvaluation.release(tags: ["v1.2", "v1.1"], wanted: nil, baseline: nil)
        XCTAssertEqual(result.check, .notYet("Latest is v1.2"))
        XCTAssertEqual(result.baseline, "v1.2")
        XCTAssertEqual(WaitEvaluation.release(tags: ["v1.2"], wanted: nil, baseline: "v1.2").check, .notYet("Latest is v1.2"))
        XCTAssertEqual(WaitEvaluation.release(tags: ["v1.3", "v1.2"], wanted: nil, baseline: "v1.2").check, .met("v1.3 released"))
        XCTAssertEqual(WaitEvaluation.release(tags: ["v1.3"], wanted: "v2.0", baseline: nil).check, .notYet("Latest is v1.3"))
        XCTAssertEqual(WaitEvaluation.release(tags: ["v2.0", "v1.3"], wanted: "v2.0", baseline: nil).check, .met("v2.0 released"))
        // No releases yet: the first one is new.
        result = WaitEvaluation.release(tags: [], wanted: nil, baseline: nil)
        XCTAssertEqual(result.baseline, "")
        XCTAssertEqual(WaitEvaluation.release(tags: ["v0.1"], wanted: nil, baseline: "").check, .met("v0.1 released"))

        XCTAssertEqual(WaitEvaluation.package(versions: ["1.0", "1.1"], latest: "1.1", wanted: "2.0", baseline: nil).check,
                       .notYet("Latest is 1.1"))
        XCTAssertEqual(WaitEvaluation.package(versions: ["1.0", "2.0"], latest: "2.0", wanted: "2.0", baseline: nil).check, .met("2.0 published"))
        XCTAssertEqual(WaitEvaluation.package(versions: [], latest: "1.1", wanted: nil, baseline: nil).baseline, "1.1")
        XCTAssertEqual(WaitEvaluation.package(versions: [], latest: "1.2", wanted: nil, baseline: "1.1").check, .met("1.2 published"))
    }

    func testRegistryDocuments() {
        let npm = Data(#"{"dist-tags":{"latest":"2.1.0"},"versions":{"2.0.0":{},"2.1.0":{}}}"#.utf8)
        XCTAssertEqual(WaitEvaluation.npmVersions(npm)?.latest, "2.1.0")
        XCTAssertEqual(WaitEvaluation.npmVersions(npm)?.versions, ["2.0.0", "2.1.0"])
        let pypi = Data(#"{"info":{"version":"3.0"},"releases":{"2.9":[],"3.0":[]}}"#.utf8)
        XCTAssertEqual(WaitEvaluation.pypiVersions(pypi)?.latest, "3.0")
        let releases = Data(#"[{"tag_name":"v2","draft":true},{"tag_name":"v1.9","draft":false}]"#.utf8)
        XCTAssertEqual(WaitEvaluation.releaseTags(releases), ["v1.9"])
        XCTAssertNil(WaitEvaluation.npmVersions(Data("nope".utf8)))
    }

    func testPages() {
        XCTAssertEqual(WaitEvaluation.page(status: 200, body: nil, page: .up, baseline: nil).check, .met("Up (200)"))
        XCTAssertEqual(WaitEvaluation.page(status: 503, body: nil, page: .up, baseline: nil).check, .notYet("Answers 503"))
        XCTAssertEqual(WaitEvaluation.page(status: nil, body: nil, page: .up, baseline: nil).check, .notYet("Not reachable"))
        let body = Data("Version 2 is LIVE".utf8)
        XCTAssertEqual(WaitEvaluation.page(status: 200, body: body, page: .contains("v2"), baseline: nil).check, .notYet("Not there yet (200)"))
        XCTAssertEqual(WaitEvaluation.page(status: 200, body: body, page: .contains("version 2 is live"), baseline: nil).check,
                       .met("Shows “version 2 is live”"))
        let first = WaitEvaluation.page(status: 200, body: body, page: .changes, baseline: nil)
        XCTAssertEqual(first.check, .notYet("Watching (200)"))
        XCTAssertEqual(WaitEvaluation.page(status: 200, body: body, page: .changes, baseline: first.baseline).check, .notYet("Unchanged"))
        XCTAssertEqual(WaitEvaluation.page(status: 200, body: Data("v3".utf8), page: .changes, baseline: first.baseline).check, .met("Changed"))
    }

    func testChecksComeOftenAtFirstThenLessAndBackOffOnFailure() {
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 60, failures: 0), 300)
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 5 * 3600, failures: 0), 900)
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 3 * 86_400, failures: 0), 3600)
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 30 * 86_400, failures: 0), 4 * 3600)
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 60, failures: 2), 1200)
        XCTAssertEqual(WaitSchedule.interval(waitingFor: 30 * 86_400, failures: 9), 12 * 3600)
        let later = now.addingTimeInterval(86_400 * 30)
        XCTAssertEqual(WaitSchedule.next(after: now, waitingSince: now, failures: 0, condition: .date(later)), later)
    }

    private var origin: Wait.Origin { Wait.Origin(cwd: "/repo", branch: "main", agent: "claude", sessionId: "s1") }

    func testAWaitBecomesReadyWhenItsConditionIsMet() {
        var wait = Wait(title: "", condition: .pullRequest(repo: "a/b", number: 3, event: .merged),
                        next: "Remove the old endpoint", origin: origin, now: now)
        XCTAssertEqual(wait.title, "a/b#3 is merged")
        XCTAssertTrue(wait.isDue(now: now))
        XCTAssertEqual(wait.statusLine(now: now), "Not checked yet")
        wait.record(.notYet("Open"), now: now)
        XCTAssertFalse(wait.isDue(now: now))
        XCTAssertTrue(wait.isDue(now: now.addingTimeInterval(301)))
        XCTAssertEqual(wait.statusLine(now: now.addingTimeInterval(600)), "Open · checked 10m ago")
        wait.record(.failed("gh not signed in"), now: now)
        XCTAssertEqual(wait.failures, 1)
        wait.record(.met("Merged"), now: now)
        XCTAssertEqual(wait.state, .ready)
        XCTAssertEqual(wait.readyAt, now)
        XCTAssertFalse(wait.isDue(now: now.addingTimeInterval(99_999)))
        XCTAssertEqual(wait.statusLine(now: now), "Merged")
        XCTAssertFalse(wait.isSnooze)
    }

    func testOnlyAPersonCanSayAManualOneHappenedAndLongWaitsAskIfStillWanted() {
        var manual = Wait(title: "App Store review", condition: .manual("Apple approves the build"), next: "Release it",
                          origin: origin, now: now)
        XCTAssertFalse(manual.isDue(now: now.addingTimeInterval(99 * 86_400)))
        XCTAssertFalse(manual.needsAnswer(now: now.addingTimeInterval(86_400)))
        XCTAssertTrue(manual.needsAnswer(now: now.addingTimeInterval(3 * 86_400)))
        manual.confirm(now: now.addingTimeInterval(3 * 86_400))
        XCTAssertFalse(manual.needsAnswer(now: now.addingTimeInterval(4 * 86_400)))
        manual.markReady(now: now)
        XCTAssertEqual(manual.state, .ready)

        let long = Wait(title: "x", condition: .release(repo: "a/b", tag: nil), next: "y", origin: origin, now: now)
        XCTAssertFalse(long.needsAnswer(now: now.addingTimeInterval(20 * 86_400)))
        XCTAssertTrue(long.needsAnswer(now: now.addingTimeInterval(22 * 86_400)))

        let snooze = Wait(title: "", condition: .date(now.addingTimeInterval(3600)), next: "", origin: origin, now: now)
        XCTAssertTrue(snooze.isSnooze)
        XCTAssertFalse(snooze.isDue(now: now))
        XCTAssertTrue(snooze.isDue(now: now.addingTimeInterval(3600)))
    }

    func testWaitsSurviveARoundTrip() throws {
        let wait = Wait(title: "t", condition: .url("https://a.dev", page: .contains("ok")), next: "n", origin: origin,
                        createdBy: "Claude", brief: "b", autoContinue: true, now: now)
        let data = try JSONEncoder().encode([wait])
        XCTAssertEqual(try JSONDecoder().decode([Wait].self, from: data), [wait])
    }

    func testRepliesThatLeaveWorkWaitingAreNoticed() {
        let found = WaitSuggestion.detect("All done for now. Once https://github.com/acme/api/pull/142 is merged, we can remove the old /v1/users endpoint.")
        XCTAssertEqual(found?.next, "Remove the old /v1/users endpoint")
        XCTAssertEqual(found?.condition, .pullRequest(repo: "acme/api", number: 142, event: .merged))

        let approval = WaitSuggestion.detect("I opened acme/api#9. We need to wait for the PR to be approved before deploying to production.")
        XCTAssertEqual(approval?.waitingFor, "the PR to be approved")
        XCTAssertEqual(approval?.next, "Deploying to production")
        XCTAssertEqual(approval?.condition, .pullRequest(repo: "acme/api", number: 9, event: .approved))

        let release = WaitSuggestion.detect("When the new SDK is released, you can bump the dependency and drop the shim.")
        XCTAssertEqual(release?.waitingFor, "the new SDK is released")
        XCTAssertNil(release?.condition)

        // Steps the agent takes itself are not waits.
        XCTAssertNil(WaitSuggestion.detect("Once the tests pass locally, we can commit."))
        XCTAssertNil(WaitSuggestion.detect("After you restart the server, you should see the new page."))
        XCTAssertNil(WaitSuggestion.detect("Done."))
    }
}

final class WaitControlTests: XCTestCase {
    private func rpc(_ method: String, params: [String: Any] = [:]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]), as: UTF8.self)
    }

    private func result(_ line: String?) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(line).utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String? {
        (result["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    private let origin = WaitControl.Origin(pane: "w1:p1", workspace: "w1", conversation: nil, cwd: "/repo")

    func testOriginInsideOctetOnly() {
        XCTAssertEqual(WaitControl.Origin.current(["HERDR_PANE_ID": "w1:p1", "HERDR_SOCKET_PATH": "/s", "HERDR_WORKSPACE_ID": "w1"], cwd: "/repo"),
                       origin)
        XCTAssertEqual(WaitControl.Origin.current(["OCTET_CONVERSATION_ID": "c1"], cwd: "/r")?.conversation, "c1")
        XCTAssertNotNil(WaitControl.Origin.current(["OCTET_WAITS_SOCKET": "/s/waits.sock"], cwd: "/r"))
        XCTAssertNil(WaitControl.Origin.current([:], cwd: "/r"))
        XCTAssertNil(WaitControl.Origin.current(["HERDR_PANE_ID": "w1:p1"], cwd: "/r"))
        XCTAssertEqual(origin.params["cwd"] as? String, "/repo")
        XCTAssertEqual(origin.params["from_pane"] as? String, "w1:p1")
        XCTAssertEqual(WaitControl.socketPath(session: "dev", home: "/h"), "/h/Library/Application Support/Octet/sessions/dev/waits.sock")
    }

    func testToolsAreOfferedInsideOctet() throws {
        let tools = try result(WaitMCP.respond(to: rpc("tools/list"), origin: origin, call: { _, _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["wait_for", "list_waits", "cancel_wait"])
        let none = try result(WaitMCP.respond(to: rpc("tools/list"), origin: nil, call: { _, _ in [:] }))["tools"] as? [[String: Any]]
        XCTAssertEqual(none?.count, 0)
    }

    func testSettingAWaitPassesItsPartsAndTheOrigin() throws {
        var asked: [String: Any] = [:]
        var method: WaitControl.Method?
        let reply = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "wait_for", "arguments": ["until": "acme/api#3", "then": "Delete the flag", "title": "PR merged"]]),
            origin: origin,
            call: { called, params in
                method = called
                asked = params
                return ["condition": "acme/api#3 is merged", "checked_by_octet": true]
            }))
        XCTAssertEqual(method, .add)
        XCTAssertEqual(asked["until"] as? String, "acme/api#3")
        XCTAssertEqual(asked["then"] as? String, "Delete the flag")
        XCTAssertEqual(asked["title"] as? String, "PR merged")
        XCTAssertEqual(asked["from_pane"] as? String, "w1:p1")
        XCTAssertTrue(text(reply)?.hasPrefix("Wait set: acme/api#3 is merged. Octet checks this itself") == true)

        var called = false
        let missing = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "wait_for", "arguments": ["until": "acme/api#3"]]), origin: origin,
            call: { _, _ in called = true; return [:] }))
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertFalse(called)
    }

    func testListingAndCancelling() throws {
        let list = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "list_waits"]), origin: origin,
            call: { _, _ in ["waits": [["id": "w9", "waiting_for": "PR merged", "state": "waiting", "status": "Open", "next": "Ship it", "folder": "/repo"]]] }))
        XCTAssertEqual(text(list), "- [w9] PR merged (waiting: Open)\n  then: Ship it\n  in /repo")
        XCTAssertEqual(WaitMCP.formatList([:]), "No waits are set.")

        var cancelled: String?
        let cancel = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "cancel_wait", "arguments": ["id": "w9"]]), origin: origin,
            call: { _, params in cancelled = params["id"] as? String; return [:] }))
        XCTAssertEqual(text(cancel), "Removed.")
        XCTAssertEqual(cancelled, "w9")
        let failing = try result(WaitMCP.respond(
            to: rpc("tools/call", params: ["name": "list_waits"]), origin: origin,
            call: { _, _ in throw WaitControl.Failure(message: "off") }))
        XCTAssertEqual(failing["isError"] as? Bool, true)
    }

    func testDescribesAWaitForAnAgent() {
        let wait = Wait(title: "PR merged", condition: .pullRequest(repo: "a/b", number: 1, event: .merged), next: "n",
                        origin: Wait.Origin(cwd: "/repo"))
        let item = WaitControl.describe(wait)
        XCTAssertEqual(item["waiting_for"] as? String, "PR merged")
        XCTAssertEqual(item["link"] as? String, "https://github.com/a/b/pull/1")
        XCTAssertEqual(item["state"] as? String, "waiting")
    }
}
