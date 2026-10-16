import XCTest

final class PullRequestDetailTests: XCTestCase {
    /// The shape `gh pr view --json …` gives (gh 2.87), trimmed, with a
    /// warning ahead of it as LoginShell's merged stderr would put it.
    private let sample = ##"""
    A new release of gh is available: 2.87.2 → 2.88.0
    {"number":42,"title":"Add the PR plane","url":"https://github.com/o/r/pull/42",
     "body":"## Changes\n\n- one","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",
     "mergeStateStatus":"BEHIND","reviewDecision":"REVIEW_REQUIRED","additions":130,"deletions":26,
     "changedFiles":2,"createdAt":"2026-10-16T16:01:39Z","updatedAt":"2026-10-16T16:12:03Z",
     "mergedAt":null,"closedAt":null,"headRefName":"feat/pr","baseRefName":"main",
     "author":{"id":"x","is_bot":false,"login":"jack","name":"Jack"},
     "labels":[{"id":"L","name":"bug","description":"","color":"d73a4a"}],
     "reviewRequests":[{"__typename":"User","login":"ana"},{"__typename":"Team","name":"core","slug":"core"}],
     "latestReviews":[{"author":{"login":"ana"},"state":"COMMENTED","body":"","submittedAt":"2026-10-16T16:05:00Z"},
                      {"author":{"login":"bo"},"state":"APPROVED","body":"LGTM","submittedAt":"2026-10-16T16:06:00Z"}],
     "statusCheckRollup":[
       {"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://x/1","workflowName":"CI"},
       {"__typename":"CheckRun","name":"Lint","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://x/2","workflowName":"CI"},
       {"__typename":"StatusContext","context":"deploy/preview","state":"FAILURE","targetUrl":"https://x/3"},
       {"__typename":"CheckRun","name":"Docs","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":"","workflowName":"CI"}],
     "comments":[{"author":{"login":"cy"},"body":"First line\n\nSecond line\nThird","createdAt":"2026-10-16T16:03:00Z","url":"https://x/c"}],
     "reviews":[{"author":{"login":"ana"},"state":"COMMENTED","body":"","submittedAt":"2026-10-16T16:05:00Z"},
                {"author":{"login":"bo"},"state":"APPROVED","body":"LGTM","submittedAt":"2026-10-16T16:06:00Z"}],
     "commits":[{"oid":"ba24b3e1fa7200fa","messageHeadline":"Build 20","authoredDate":"2026-10-16T16:00:00Z",
                 "committedDate":"2026-10-16T16:01:24Z","authors":[{"login":"jack","name":"Jack"}]},
                {"oid":"cc11","messageHeadline":"Fix","authoredDate":"2026-10-16T16:04:00Z",
                 "committedDate":"2026-10-16T16:04:00Z","authors":[{"login":"","name":"Someone"}]}],
     "files":[{"path":"a.swift","additions":100,"deletions":20},{"path":"b.swift","additions":30,"deletions":6}],
     "autoMergeRequest":null,"headRepositoryOwner":{"id":"y","login":"jack"},"isCrossRepository":false}
    """##

    private func detail() throws -> PullRequestDetail {
        try XCTUnwrap(PullRequestDetail.parse(sample))
    }

    // MARK: - Parsing

    func testParsesGhViewPastALeadingWarning() throws {
        let pr = try detail()
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.title, "Add the PR plane")
        XCTAssertEqual(pr.url?.absoluteString, "https://github.com/o/r/pull/42")
        XCTAssertEqual(pr.tone, .open)
        XCTAssertTrue(pr.isOpen)
        XCTAssertTrue(pr.isBehind)
        XCTAssertEqual(pr.author, "jack")
        XCTAssertEqual(pr.labels, [PullRequestLabel(name: "bug", color: "d73a4a")])
        XCTAssertEqual(pr.reviewRequests, ["ana", "core"])
        XCTAssertEqual(pr.checks.count, 4)
        XCTAssertEqual(pr.comments.first?.author, "cy")
        XCTAssertEqual(pr.commits.map(\.shortSha), ["ba24b3e", "cc11"])
        XCTAssertEqual(pr.commits.last?.author, "Someone")
        XCTAssertEqual(pr.files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertNil(pr.autoMerge)
        XCTAssertNil(pr.mergedAt)
        XCTAssertEqual(pr.changedFiles, 2)
        XCTAssertEqual(pr.updatedAt, ISO8601DateFormatter().date(from: "2026-10-16T16:12:03Z"))
    }

    func testParsesAutoMergeAndTones() throws {
        var text = sample.replacingOccurrences(of: #""autoMergeRequest":null"#,
                                               with: #""autoMergeRequest":{"mergeMethod":"SQUASH","enabledBy":{"login":"jack"}}"#)
        XCTAssertEqual(PullRequestDetail.parse(text)?.autoMerge, .squash)
        text = sample.replacingOccurrences(of: #""isDraft":false"#, with: #""isDraft":true"#)
        XCTAssertEqual(PullRequestDetail.parse(text)?.tone, .draft)
        XCTAssertEqual(PullRequestTone(state: "MERGED", isDraft: true), .merged)
        XCTAssertEqual(PullRequestTone(state: "closed", isDraft: false), .closed)
    }

    func testNothingParsesFromAnError() {
        XCTAssertNil(PullRequestDetail.parse(#"no pull requests found for branch "x""#))
        XCTAssertNil(PullRequestDetail.parse(""))
        XCTAssertNil(PullRequestDetail.parse(#"{"title":"no number"}"#))
    }

    func testParsesRepositoryAndLabels() throws {
        let repo = try XCTUnwrap(PullRequestRepository.parse(
            #"{"mergeCommitAllowed":false,"nameWithOwner":"o/r","rebaseMergeAllowed":true,"squashMergeAllowed":true,"url":"https://github.com/o/r","viewerPermission":"ADMIN"}"#))
        XCTAssertEqual(repo.nameWithOwner, "o/r")
        XCTAssertEqual(repo.allowedMethods, [.squash, .rebase])
        XCTAssertEqual(repo.viewerPermission, "ADMIN")
        let labels = PullRequestLabel.parseList(#"[{"color":"f143ab","name":"accessibility"},{"color":"d73a4a","name":"bug"}]"#)
        XCTAssertEqual(labels.map(\.name), ["accessibility", "bug"])
    }

    func testParsesTheList() throws {
        let list = try XCTUnwrap(PullRequestSummary.parseList(##"""
        [{"number":7,"title":"One","author":{"login":"a"},"isDraft":true,"state":"OPEN","headRefName":"x",
          "updatedAt":"2026-10-16T16:12:03Z","additions":3,"deletions":1,"reviewDecision":"",
          "statusCheckRollup":[{"__typename":"CheckRun","name":"B","status":"QUEUED","conclusion":""}]},
         {"number":8,"title":"Two","author":{"login":"b"},"isDraft":false,"state":"OPEN","headRefName":"y",
          "updatedAt":"2026-10-16T16:12:03Z","additions":0,"deletions":0,"reviewDecision":"APPROVED","statusCheckRollup":[]}]
        """##))
        XCTAssertEqual(list.map(\.number), [7, 8])
        XCTAssertEqual(list[0].tone, .draft)
        XCTAssertEqual(list[0].checks.tone, .pending)
        XCTAssertEqual(list[1].checks.tone, .none)
        XCTAssertEqual(PullRequestSummary.parseList("[]"), [])
        XCTAssertNil(PullRequestSummary.parseList("gh: Not Found"))
    }

    // MARK: - Checks

    func testCheckStates() throws {
        let checks = try detail().checks
        XCTAssertEqual(checks.map(\.state), [.passed, .running, .failed, .skipped])
        XCTAssertEqual(checks[2].name, "deploy/preview")
        XCTAssertEqual(checks[2].workflow, "")
        XCTAssertEqual(checks[0].workflow, "CI")
        XCTAssertEqual(checks[2].url?.absoluteString, "https://x/3")
        XCTAssertNil(checks[3].url)
        let cancelled = PullRequestCheck.parse(["name": "X", "status": "COMPLETED", "conclusion": "CANCELLED"], index: 0)
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(PullRequestCheck.parse(["name": "X", "status": "COMPLETED", "conclusion": "TIMED_OUT"], index: 0)?.state, .failed)
        XCTAssertEqual(PullRequestCheck.parse(["context": "ci/x", "state": "PENDING"], index: 0)?.state, .running)
    }

    func testChecksSummaryText() throws {
        func summary(_ states: [PullRequestCheck.State]) -> PullRequestChecksSummary {
            PullRequestChecksSummary(states.enumerated().map {
                PullRequestCheck(name: "c\($0)", workflow: "", state: $1, url: nil, index: $0)
            })
        }
        XCTAssertEqual(summary([]).text, "No checks reported")
        XCTAssertEqual(summary([]).tone, .none)
        XCTAssertEqual(summary([.passed, .skipped, .neutral]).text, "All checks passed")
        XCTAssertEqual(summary([.passed, .skipped]).heading, "All checks have passed")
        XCTAssertEqual(summary([.passed, .failed, .running, .cancelled, .passed]).text, "2 of 5 failing")
        XCTAssertEqual(summary([.failed]).heading, "Some checks were not successful")
        XCTAssertEqual(summary([.passed, .running, .running]).text, "2 of 3 running")
        XCTAssertEqual(summary([.running]).heading, "Some checks haven't completed yet")
        XCTAssertEqual(try detail().checksSummary.text, "1 of 4 failing")
    }

    func testChecksOrderFailingThenRunningThenCompleted() throws {
        let ordered = PullRequestChecksSummary.ordered(try detail().checks)
        XCTAssertEqual(ordered.map(\.name), ["deploy/preview", "Lint", "Build", "Docs"])
    }

    // MARK: - Primary control

    func testPrimaryControl() throws {
        var pr = try detail()
        // A check is failing: merge when they pass.
        XCTAssertEqual(pr.primary(method: .squash), .autoMerge(.squash))
        pr.checks = pr.checks.filter { $0.state == .passed }
        XCTAssertEqual(pr.primary(method: .squash), .merge(.squash))
        pr.checks = []
        XCTAssertEqual(pr.primary(method: .merge), .merge(.merge), "no checks: nothing to wait for")
        pr.autoMerge = .rebase
        XCTAssertEqual(pr.primary(method: .merge), .autoMergeArmed(.rebase))
        pr.isDraft = true
        XCTAssertEqual(pr.primary(method: .merge), .readyForReview)
        pr.mergeable = "CONFLICTING"
        XCTAssertEqual(pr.primary(method: .merge), .resolveConflicts)
        pr.state = "CLOSED"
        XCTAssertEqual(pr.primary(method: .merge), .closed)
        pr.state = "MERGED"
        XCTAssertEqual(pr.primary(method: .merge), .merged)
    }

    // MARK: - Merge method

    func testMergeMethodResolution() {
        let all = PullRequestMergeMethod.allCases
        XCTAssertEqual(PullRequestMergeMethod.resolve(chosen: .rebase, last: .squash, allowed: all), .rebase)
        XCTAssertEqual(PullRequestMergeMethod.resolve(chosen: nil, last: .squash, allowed: all), .squash)
        XCTAssertEqual(PullRequestMergeMethod.resolve(chosen: nil, last: nil, allowed: all), .merge)
        // Choices the repository doesn't allow are passed over.
        XCTAssertEqual(PullRequestMergeMethod.resolve(chosen: .merge, last: .rebase, allowed: [.squash]), .squash)
        XCTAssertEqual(PullRequestMergeMethod.resolve(chosen: nil, last: .merge, allowed: [.squash, .rebase]), .squash)
        XCTAssertNil(PullRequestMergeMethod.resolve(chosen: nil, last: nil, allowed: []))
        XCTAssertEqual(PullRequestMergeMethod.squash.title, "Squash and Merge")
        XCTAssertEqual(PullRequestMergeMethod.rebase.flag, "--rebase")
        XCTAssertEqual(PullRequestMergeMethod(github: "MERGE"), .merge)
    }

    // MARK: - Timeline

    func testTimelineIsInTimeOrder() throws {
        let pr = try detail()
        let items = pr.timeline(newestFirst: false)
        // Opened 16:01:39, commit 16:01:24 is before it (pushed first),
        // comment 16:03, commit 16:04, approval 16:06. The empty
        // "commented" review is only inline comments, so it's left out.
        XCTAssertEqual(items.map(\.text), ["Build 20", "Opened", "First line Second line", "Fix", "Approved"])
        XCTAssertEqual(items.first?.kind, .commit(sha: "ba24b3e1fa7200fa"))
        XCTAssertEqual(items.last?.kind, .review(.approved))
        XCTAssertEqual(pr.timeline(newestFirst: true).map(\.text), items.map(\.text).reversed())
    }

    func testMergedShowsOnlyTheMerge() throws {
        var pr = try detail()
        pr.state = "MERGED"
        pr.mergedAt = ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")
        pr.closedAt = pr.mergedAt
        let kinds = pr.timeline(newestFirst: true).map(\.kind)
        XCTAssertEqual(kinds.first, .merged)
        XCTAssertFalse(kinds.contains(.closed))
        pr.state = "CLOSED"
        XCTAssertEqual(pr.timeline(newestFirst: true).first?.kind, .closed)
    }

    func testTimelineTiesKeepOpenedFirst() throws {
        var pr = try detail()
        pr.commits = [PullRequestDetail.Commit(oid: "a", headline: "Same moment", author: "j", date: pr.createdAt)]
        pr.comments = []
        pr.reviews = []
        XCTAssertEqual(pr.timeline(newestFirst: false).map(\.text), ["Opened", "Same moment"])
    }

    func testConversationAndReviewers() throws {
        let pr = try detail()
        XCTAssertEqual(pr.conversation.map(\.author), ["cy", "bo"])
        // Ana is asked (again), so she reads as requested; Bo approved.
        XCTAssertEqual(pr.reviewers, [
            .init(login: "ana", verdict: nil), .init(login: "core", verdict: nil), .init(login: "bo", verdict: .approved),
        ])
        XCTAssertEqual(PullRequestDetail.firstLines("a\n\n b \nc", lines: 2), "a b")
    }

    // MARK: - Failures

    func testFailureClassification() {
        XCTAssertEqual(PullRequestLoadFailure.classify(status: 1, output: #"no pull requests found for branch "x""#), .noPullRequest)
        XCTAssertEqual(PullRequestLoadFailure.classify(status: 127, output: "zsh:1: command not found: gh"), .ghMissing)
        XCTAssertEqual(PullRequestLoadFailure.classify(status: 4, output: "To get started with GitHub CLI, please run:  gh auth login"), .signedOut)
        XCTAssertEqual(PullRequestLoadFailure.classify(status: 1, output: "failed to run git: fatal: not a git repository (or any of the parent directories): .git"), .notRepository)
        XCTAssertEqual(PullRequestLoadFailure.classify(status: 1, output: "\nHTTP 502\nmore"), .other("HTTP 502"))
        XCTAssertEqual(PullRequestLoadFailure.ghMissing.remedy, "Install the GitHub CLI: brew install gh")
        XCTAssertEqual(PullRequestLoadFailure.signedOut.remedy, "Sign in with gh auth login")
    }

    func testAgo() {
        let now = Date()
        XCTAssertEqual(PullRequestJSON.ago(now.addingTimeInterval(-3_700), now: now), "1h ago")
        XCTAssertEqual(PullRequestJSON.ago(now, now: now), "just now")
        XCTAssertEqual(PullRequestJSON.ago(nil, now: now), "")
    }
}
