import XCTest

/// The PR Code tab's viewed marks and line comments: every gh command it
/// builds and every answer it reads. Fixtures are trimmed from real
/// read-only `gh api` output (gh 2.87.2) for JackTPatterson/octet#36 and
/// cli/cli#14673; nothing here runs gh.
final class PullRequestCodeReviewTests: XCTestCase {
    // MARK: - Anchors

    private func line(_ kind: ReviewDiff.Line.Kind, old: Int?, new: Int?) -> ReviewDiff.Line {
        ReviewDiff.Line(kind: kind, oldNumber: old, newNumber: new, text: "  let x = 1", index: 0)
    }

    func testAddedAndContextLinesAreRightByNewNumberRemovedAreLeftByOld() {
        XCTAssertEqual(PullRequestLineAnchor(path: "a.go", line: line(.added, old: nil, new: 12)),
                       PullRequestLineAnchor(path: "a.go", line: 12, side: .right))
        XCTAssertEqual(PullRequestLineAnchor(path: "a.go", line: line(.context, old: 9, new: 11)),
                       PullRequestLineAnchor(path: "a.go", line: 11, side: .right))
        XCTAssertEqual(PullRequestLineAnchor(path: "a.go", line: line(.removed, old: 10, new: nil)),
                       PullRequestLineAnchor(path: "a.go", line: 10, side: .left))
        XCTAssertNil(PullRequestLineAnchor(path: "a.go", line: line(.removed, old: nil, new: nil)))
    }

    // MARK: - Viewed marks

    /// `gh api graphql` for JackTPatterson/octet#36, verbatim.
    private let viewed36 = #"""
    {"data":{"repository":{"pullRequest":{"id":"PR_kwDOUfPV1c8AAAABI4YPbQ","files":{"nodes":[{"path":"Octet/Session/SessionStore.swift","viewerViewedState":"UNVIEWED"},{"path":"Octet/Sidebar/SidebarView.swift","viewerViewedState":"UNVIEWED"},{"path":"project.yml","viewerViewedState":"UNVIEWED"}]}}}}}
    """#

    func testViewedQueryArguments() throws {
        let argv = try XCTUnwrap(PullRequestViewedState.arguments(repository: "JackTPatterson/octet", number: 36))
        XCTAssertEqual(argv, [
            "gh", "api", "graphql",
            "-f", "query=query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id files(first:100){nodes{path viewerViewedState}}}}}",
            "-f", "owner=JackTPatterson", "-f", "name=octet", "-F", "number=36",
        ])
        XCTAssertNil(PullRequestViewedState.arguments(repository: "no-slash", number: 1))
        XCTAssertNil(PullRequestViewedState.arguments(repository: "/octet", number: 1))
    }

    func testParsesViewedStateFromRealOutput() throws {
        let state = try XCTUnwrap(PullRequestViewedState.parse(viewed36))
        XCTAssertEqual(state.pullRequestId, "PR_kwDOUfPV1c8AAAABI4YPbQ")
        XCTAssertEqual(state.viewed.count, 3)
        XCTAssertFalse(state.isViewed("project.yml"))
        XCTAssertFalse(state.isViewed("not/in/the/list.swift"))
    }

    func testViewedAndDismissedStates() throws {
        let text = viewed36
            .replacingOccurrences(of: #""Octet/Session/SessionStore.swift","viewerViewedState":"UNVIEWED""#,
                                  with: #""Octet/Session/SessionStore.swift","viewerViewedState":"VIEWED""#)
            .replacingOccurrences(of: #""project.yml","viewerViewedState":"UNVIEWED""#,
                                  with: #""project.yml","viewerViewedState":"DISMISSED""#)
        let state = try XCTUnwrap(PullRequestViewedState.parse("A new release of gh is available\n" + text))
        XCTAssertTrue(state.isViewed("Octet/Session/SessionStore.swift"))
        // Viewed, then changed since: GitHub shows it unviewed again.
        XCTAssertFalse(state.isViewed("project.yml"))
        let paths = ["Octet/Session/SessionStore.swift", "Octet/Sidebar/SidebarView.swift", "project.yml"]
        XCTAssertEqual(state.count(in: paths), 1)
        XCTAssertEqual(PullRequestViewedState.summary(viewed: state.count(in: paths), of: paths.count), "1 of 3 viewed")
    }

    func testViewedParseRejectsErrors() {
        XCTAssertNil(PullRequestViewedState.parse(#"{"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest with the number of 9."}],"data":{"repository":{"pullRequest":null}}}"#))
        XCTAssertNil(PullRequestViewedState.parse("gh: Not Found (HTTP 404)"))
    }

    func testMarkAndUnmarkViewedArguments() {
        XCTAssertEqual(PullRequestViewedState.markArguments(pullRequestId: "PR_kwDOUfPV1c8AAAABI4YPbQ", path: "project.yml", viewed: true), [
            "gh", "api", "graphql",
            "-f", "query=mutation($id:ID!,$path:String!){markFileAsViewed(input:{pullRequestId:$id,path:$path}){clientMutationId}}",
            "-f", "id=PR_kwDOUfPV1c8AAAABI4YPbQ", "-f", "path=project.yml",
        ])
        let unmark = PullRequestViewedState.markArguments(pullRequestId: "PR_x", path: "dir with space/1", viewed: false)
        XCTAssertEqual(unmark[4], "query=mutation($id:ID!,$path:String!){unmarkFileAsViewed(input:{pullRequestId:$id,path:$path}){clientMutationId}}")
        // -f, not -F: a path that looks like a number stays a string.
        XCTAssertEqual(Array(unmark[5...]), ["-f", "id=PR_x", "-f", "path=dir with space/1"])
    }

    // MARK: - Existing review comments

    /// `gh api repos/cli/cli/pulls/14673/comments`, trimmed to the fields
    /// read and a few comments: a thread with a reply, a line that moved
    /// (original_line 283, now 284), and outdated comments (line null).
    private let comments14673 = #"""
    [{"id": 4293684492, "in_reply_to_id": null, "path": "pkg/cmd/auth/auth.go", "line": 32, "side": "RIGHT", "original_line": 32, "subject_type": "line", "created_at": "2026-10-16T10:36:29Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4293684492", "user": {"login": "Copilot"}, "body": "🛑 Requirement: Re-enable command telemetry for login and refresh\n\nThe "},
     {"id": 4293684591, "in_reply_to_id": null, "path": "pkg/cmd/auth/login/login.go", "line": 284, "side": "RIGHT", "original_line": 283, "subject_type": "line", "created_at": "2026-10-16T10:36:29Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4293684591", "user": {"login": "Copilot"}, "body": "🛑 Requirement: Include token-based logins in auth telemetry\n\nThe --wit"},
     {"id": 4293684654, "in_reply_to_id": null, "path": "pkg/cmd/auth/shared/git_credential.go", "line": null, "side": "RIGHT", "original_line": 154, "subject_type": "line", "created_at": "2026-10-16T10:36:30Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4293684654", "user": {"login": "Copilot"}, "body": "🛑 Requirement: Preserve best-effort helper inspection\n\nA nil HelperCon"},
     {"id": 4293905257, "in_reply_to_id": 4293684492, "path": "pkg/cmd/auth/auth.go", "line": 32, "side": "RIGHT", "original_line": 32, "subject_type": "line", "created_at": "2026-10-16T10:57:59Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4293905257", "user": {"login": "babakks"}, "body": "We intentionally don't emit `command_invocation` for any `auth` subcom"},
     {"id": 4294412060, "in_reply_to_id": null, "path": "pkg/cmd/auth/shared/git_credential.go", "line": null, "side": "RIGHT", "original_line": 116, "subject_type": "line", "created_at": "2026-10-16T11:59:11Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4294412060", "user": {"login": "williammartin"}, "body": "<img width=\"1918\" height=\"88\" alt=\"Image\" src=\"https://github.com/user"},
     {"id": 4295604151, "in_reply_to_id": 4294412060, "path": "pkg/cmd/auth/shared/git_credential.go", "line": null, "side": "RIGHT", "original_line": 116, "subject_type": "line", "created_at": "2026-10-16T14:15:12Z", "html_url": "https://github.com/cli/cli/pull/14673#discussion_r4295604151", "user": {"login": "babakks"}, "body": "Already done. "}]
    """#

    func testReviewCommentsArguments() {
        XCTAssertEqual(PullRequestReviewComment.arguments(repository: "cli/cli", number: 14673),
                       ["gh", "api", "repos/cli/cli/pulls/14673/comments?per_page=100", "--paginate"])
    }

    func testParsesReviewCommentsFromRealOutput() throws {
        let comments = try XCTUnwrap(PullRequestReviewComment.parseList(comments14673))
        XCTAssertEqual(comments.count, 6)
        let first = comments[0]
        XCTAssertEqual(first.id, 4293684492)
        XCTAssertNil(first.inReplyTo)
        XCTAssertEqual(first.author, "Copilot")
        XCTAssertEqual(first.anchor, PullRequestLineAnchor(path: "pkg/cmd/auth/auth.go", line: 32, side: .right))
        XCTAssertEqual(first.createdAt, ISO8601DateFormatter().date(from: "2026-10-16T10:36:29Z"))
        XCTAssertEqual(first.url?.absoluteString, "https://github.com/cli/cli/pull/14673#discussion_r4293684492")
        XCTAssertEqual(comments[3].inReplyTo, 4293684492)
        // The current line, not where it was first written.
        XCTAssertEqual(comments[1].line, 284)
        XCTAssertNil(comments[2].anchor)
    }

    func testThreadsGroupByLineOldestFirstAndDropOutdated() throws {
        let comments = try XCTUnwrap(PullRequestReviewComment.parseList(comments14673))
        // Newest first in, oldest first out.
        let threads = PullRequestReviewComment.byAnchor(comments.reversed())
        XCTAssertEqual(threads.count, 2)
        let auth = try XCTUnwrap(threads[PullRequestLineAnchor(path: "pkg/cmd/auth/auth.go", line: 32, side: .right)])
        XCTAssertEqual(auth.map(\.author), ["Copilot", "babakks"])
        XCTAssertNil(threads[PullRequestLineAnchor(path: "pkg/cmd/auth/auth.go", line: 32, side: .left)])
    }

    func testLeftSideCommentsAnchorToRemovedLines() throws {
        // cli/cli's recent comments are all RIGHT; the same shape on LEFT.
        let text = comments14673.replacingOccurrences(of: #""line": 284, "side": "RIGHT""#, with: #""line": 284, "side": "LEFT""#)
        let comments = try XCTUnwrap(PullRequestReviewComment.parseList(text))
        let removed = ReviewDiff.Line(kind: .removed, oldNumber: 284, newNumber: nil, text: "x", index: 3)
        let anchor = try XCTUnwrap(PullRequestLineAnchor(path: "pkg/cmd/auth/login/login.go", line: removed))
        XCTAssertEqual(PullRequestReviewComment.byAnchor(comments)[anchor]?.map(\.id), [4293684591])
    }

    func testReviewCommentsParsePagesWarningsAndBrackets() throws {
        // An empty PR (octet#36's real answer).
        XCTAssertEqual(PullRequestReviewComment.parseList("[]"), [])
        // Pages back to back (older gh), behind a warning holding a "[".
        let page = #"[{"id":1,"path":"a","line":2,"side":"RIGHT","user":{"login":"x"},"body":"see [1] ] and \"]\""}]"#
        let two = PullRequestReviewComment.parseList("warning: [deprecated]\n" + page + page.replacingOccurrences(of: #""id":1"#, with: #""id":2"#))
        XCTAssertEqual(two?.map(\.id), [1, 2])
        XCTAssertEqual(two?.first?.body, #"see [1] ] and "]""#)
        XCTAssertNil(PullRequestReviewComment.parseList("gh: Not Found (HTTP 404)"))
    }

    // MARK: - Writing a review

    func testCanSubmit() {
        XCTAssertTrue(PullRequestReviewEvent.canSubmit(.approve, body: "", lineComments: 0))
        XCTAssertFalse(PullRequestReviewEvent.canSubmit(.requestChanges, body: " \n", lineComments: 3))
        XCTAssertTrue(PullRequestReviewEvent.canSubmit(.requestChanges, body: "Rename it", lineComments: 0))
        XCTAssertFalse(PullRequestReviewEvent.canSubmit(.comment, body: "", lineComments: 0))
        XCTAssertTrue(PullRequestReviewEvent.canSubmit(.comment, body: "", lineComments: 1))
    }

    func testReviewSubmissionArguments() {
        XCTAssertEqual(PullRequestReviewSubmission.arguments(repository: "JackTPatterson/octet", number: 36),
                       ["gh", "api", "repos/JackTPatterson/octet/pulls/36/reviews", "--method", "POST", "--input", "-"])
    }

    func testReviewSubmissionBody() throws {
        let comments = [
            PullRequestPendingComment(anchor: PullRequestLineAnchor(path: "project.yml", line: 4, side: .right), body: " Why this? \n"),
            PullRequestPendingComment(anchor: PullRequestLineAnchor(path: "Octet/Sidebar/SidebarView.swift", line: 120, side: .left),
                                      body: "Keep the \"old\" path/name"),
        ]
        let data = PullRequestReviewSubmission.body(event: .requestChanges, body: "  Two things  ", comments: comments)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"body":"Two things","comments":[{"body":"Keep the \"old\" path/name","line":120,"path":"Octet/Sidebar/SidebarView.swift","side":"LEFT"},{"body":"Why this?","line":4,"path":"project.yml","side":"RIGHT"}],"event":"REQUEST_CHANGES"}"#)
        let approve = try XCTUnwrap(JSONSerialization.jsonObject(with: PullRequestReviewSubmission.body(event: .approve, body: "", comments: [])) as? [String: Any])
        XCTAssertEqual(approve["event"] as? String, "APPROVE")
        XCTAssertEqual((approve["comments"] as? [Any])?.count, 0)
    }

    func testAgentPrompt() {
        let right = PullRequestPendingComment.agentPrompt(
            number: 36, anchor: PullRequestLineAnchor(path: "project.yml", line: 4, side: .right),
            code: "    MARKETING_VERSION: \"0.1.0\"", text: " Bump this \n")
        XCTAssertEqual(right, "On PR #36, about project.yml:4 `MARKETING_VERSION: \"0.1.0\"`:\n\nBump this")
        let left = PullRequestPendingComment.agentPrompt(
            number: 36, anchor: PullRequestLineAnchor(path: "a.swift", line: 9, side: .left), code: "  ", text: "Why removed?")
        XCTAssertEqual(left, "On PR #36, about a.swift:9 (removed line):\n\nWhy removed?")
    }
}
