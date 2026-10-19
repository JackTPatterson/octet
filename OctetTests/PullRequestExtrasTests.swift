import XCTest

final class PullRequestExtrasTests: XCTestCase {
    // MARK: Reviewers

    func testReviewRequestsKeepTeamsApart() {
        let json = #"[{"__typename":"User","login":"ana"},{"__typename":"Team","name":"Core","slug":"core"}]"#
        let items = PullRequestJSON.array(in: json) ?? []
        XCTAssertEqual(PullRequestReviewTarget.parseRequests(items), [
            PullRequestReviewTarget(name: "ana", isTeam: false), PullRequestReviewTarget(name: "core", isTeam: true)])
    }

    func testCandidatesParse() {
        XCTAssertEqual(PullRequestReviewTarget.parseUsers(#"[{"login":"a","id":1},{"login":"b"}]"#).map(\.name), ["a", "b"])
        XCTAssertEqual(PullRequestReviewTarget.parseTeams(#"[{"slug":"core","name":"Core"}]"#),
                       [PullRequestReviewTarget(name: "core", isTeam: true)])
        XCTAssertEqual(PullRequestReviewTarget.parseUsers("Not Found"), [])
    }

    func testRequestArgumentsAndBody() {
        XCTAssertEqual(PullRequestReviewTarget.requestArguments(repository: "o/r", number: 7, adding: true),
                       ["gh", "api", "-X", "POST", "repos/o/r/pulls/7/requested_reviewers", "--input", "-"])
        XCTAssertEqual(PullRequestReviewTarget.requestArguments(repository: "o/r", number: 7, adding: false)[3], "DELETE")
        let user = try? JSONSerialization.jsonObject(with: PullRequestReviewTarget.requestBody(.init(name: "ana", isTeam: false)))
        XCTAssertEqual(user as? [String: [String]], ["reviewers": ["ana"]])
        let team = try? JSONSerialization.jsonObject(with: PullRequestReviewTarget.requestBody(.init(name: "core", isTeam: true)))
        XCTAssertEqual(team as? [String: [String]], ["team_reviewers": ["core"]])
    }

    func testReviewerToggleAddsThenRemoves() {
        let ana = PullRequestReviewTarget(name: "ana", isTeam: false)
        let added = PullRequestReviewTarget.toggled([], ana)
        XCTAssertEqual(added, [ana])
        XCTAssertEqual(PullRequestReviewTarget.toggled(added, ana), [])
        // A user and a team with one name are two requests.
        XCTAssertEqual(PullRequestReviewTarget.toggled(added, .init(name: "ana", isTeam: true)).count, 2)
    }

    func testDetailKeepsReviewTargets() {
        let json = ##"{"number":1,"reviewRequests":[{"login":"ana"},{"slug":"core","name":"Core"}]}"##
        let detail = PullRequestDetail.parse(json)
        XCTAssertEqual(detail?.reviewTargets.map(\.isTeam), [false, true])
        XCTAssertEqual(detail?.reviewRequests, ["ana", "Core"])
    }

    // MARK: Reactions

    private let groups = PullRequestReactionCount.parse(PullRequestJSON.array(in: """
        [{"content":"ROCKET","users":{"totalCount":1},"viewerHasReacted":false},
         {"content":"THUMBS_UP","users":{"totalCount":3},"viewerHasReacted":true},
         {"content":"EYES","users":{"totalCount":0},"viewerHasReacted":false}]
        """))

    func testReactionGroupsParseInGitHubOrderWithoutEmpties() {
        XCTAssertEqual(groups.map(\.reaction), [.thumbsUp, .rocket])
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertTrue(groups[0].mine)
    }

    func testToggleRemovesYoursAndAddsNew() {
        let taken = PullRequestReactionCount.toggled(groups, .thumbsUp)
        XCTAssertEqual(taken.first?.count, 2)
        XCTAssertEqual(taken.first?.mine, false)
        let added = PullRequestReactionCount.toggled(groups, .rocket)
        XCTAssertEqual(added.last?.count, 2)
        XCTAssertEqual(added.last?.mine, true)
        let fresh = PullRequestReactionCount.toggled(groups, .heart)
        XCTAssertEqual(fresh.map(\.reaction), [.thumbsUp, .heart, .rocket])
    }

    func testToggleTwiceRestoresAndLastReactionDisappears() {
        // Rollback is the same toggle's result put back, but toggling twice agrees.
        XCTAssertEqual(PullRequestReactionCount.toggled(PullRequestReactionCount.toggled(groups, .heart), .heart), groups)
        let alone = [PullRequestReactionCount(reaction: .eyes, count: 1, mine: true)]
        XCTAssertEqual(PullRequestReactionCount.toggled(alone, .eyes), [])
    }

    func testReactionMutationArguments() {
        let add = PullRequestReactionCount.arguments(subjectId: "IC_1", reaction: .hooray, adding: true)
        XCTAssertTrue(add[4].contains("addReaction"))
        XCTAssertEqual(Array(add[5...]), ["-f", "id=IC_1", "-f", "content=HOORAY"])
        XCTAssertTrue(PullRequestReactionCount.arguments(subjectId: "x", reaction: .eyes, adding: false)[4].contains("removeReaction"))
    }

    func testCommentsCarryNodeIdAndReactionsIntoTimeline() {
        let json = ##"""
        {"number":1,"comments":[{"id":"IC_9","author":{"login":"a"},"body":"hi","createdAt":"2026-10-16T16:01:39Z",
         "reactionGroups":[{"content":"HEART","users":{"totalCount":2},"viewerHasReacted":false}]}],
         "reviews":[{"id":"PRR_1","author":{"login":"b"},"state":"APPROVED","body":"ok","submittedAt":"2026-10-17T16:01:39Z"}]}
        """##
        let items = PullRequestDetail.parse(json)?.conversation ?? []
        XCTAssertEqual(items.map(\.subjectId), ["IC_9", "PRR_1"])
        XCTAssertEqual(items.first?.reactions.first?.reaction, .heart)
    }

    // MARK: Stacks

    private func layer(_ number: Int, _ head: String, _ base: String, state: String = "OPEN") -> PullRequestStackLayer {
        PullRequestStackLayer(number: number, title: "PR \(number)", headRefName: head, baseRefName: base, isDraft: false, state: state)
    }

    func testStackIsFoundFromAnyLayer() {
        let all = [layer(3, "c", "b"), layer(1, "a", "main"), layer(2, "b", "a"), layer(9, "x", "main")]
        for member in all.prefix(3) {
            let stack = PullRequestStack.build(current: member, among: all)
            XCTAssertEqual(stack?.layers.map(\.number), [1, 2, 3])
            XCTAssertEqual(stack?.current.number, member.number)
            XCTAssertEqual(stack?.size, 3)
        }
        let middle = PullRequestStack.build(current: all[2], among: all)
        XCTAssertEqual(middle?.position, 2)
        XCTAssertEqual(middle?.below?.number, 1)
        XCTAssertEqual(middle?.above?.number, 3)
        XCTAssertEqual(middle?.trunk, "main")
    }

    func testAloneOrClosedParentIsNoStack() {
        let all = [layer(1, "a", "main"), layer(2, "b", "main"), layer(3, "c", "a", state: "MERGED")]
        XCTAssertNil(PullRequestStack.build(current: all[0], among: all))
        XCTAssertNil(PullRequestStack.build(current: all[1], among: all))
        XCTAssertNil(PullRequestStack.build(current: layer(4, "d", "c"), among: all))
    }

    func testCyclesAndForksTerminate() {
        let cycle = [layer(1, "a", "b"), layer(2, "b", "a")]
        XCTAssertEqual(PullRequestStack.build(current: cycle[0], among: cycle)?.size, 2)
        // Two PRs on one branch: the older continues the chain.
        let fork = [layer(1, "a", "main"), layer(5, "e", "a"), layer(2, "b", "a")]
        XCTAssertEqual(PullRequestStack.build(current: fork[0], among: fork)?.layers.map(\.number), [1, 2])
    }

    func testStackListParses() {
        let list = PullRequestStackLayer.parseList(#"[{"number":4,"title":"t","headRefName":"h","baseRefName":"b","isDraft":true,"state":"OPEN"}]"#)
        XCTAssertEqual(list?.first?.number, 4)
        XCTAssertEqual(list?.first?.tone, .draft)
    }
}
