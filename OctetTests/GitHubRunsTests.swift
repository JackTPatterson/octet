import XCTest

final class GitHubRunsTests: XCTestCase {
    private func run(_ id: Int, _ workflow: String, sha: String, status: String = "completed", conclusion: String = "success") -> [String: Any] {
        ["databaseId": id, "workflowName": workflow, "displayTitle": "Title", "status": status, "conclusion": conclusion,
         "headSha": sha, "event": "push", "url": "https://github.com/o/r/actions/runs/\(id)",
         "createdAt": "2026-09-28T10:00:00Z", "updatedAt": "2026-09-28T10:03:20Z"]
    }

    private func parse(_ runs: [[String: Any]]) -> [CIRun] {
        GitHubRuns.parseRuns(try! JSONSerialization.data(withJSONObject: runs))
    }

    func testHeadsRunsOnePerWorkflowNewestFirst() throws {
        // Newest first, as gh lists: a re-run of Tests supersedes its failure.
        let runs = parse([
            run(5, "Tests", sha: "head", status: "in_progress", conclusion: ""),
            run(4, "Lint", sha: "head"),
            run(3, "Tests", sha: "head", conclusion: "failure"),
            run(2, "Tests", sha: "older", conclusion: "failure"),
        ])
        let status = try XCTUnwrap(GitHubRuns.status(runs: runs, head: "head"))
        XCTAssertTrue(status.isHead)
        XCTAssertEqual(status.runs.map(\.id), [5, 4])
        XCTAssertEqual(status.overall, .running)
        XCTAssertEqual(status.finished, 1)
        XCTAssertEqual(runs.first?.updatedAt?.timeIntervalSince(runs.first!.createdAt!), 200)
    }

    func testAnUnpushedHeadFallsBackToTheLatestPushedCommit() throws {
        let runs = parse([run(2, "Tests", sha: "pushed", conclusion: "failure"), run(1, "Lint", sha: "pushed", conclusion: "cancelled")])
        let status = try XCTUnwrap(GitHubRuns.status(runs: runs, head: "local"))
        XCTAssertFalse(status.isHead)
        XCTAssertEqual(status.sha, "pushed")
        XCTAssertEqual(status.overall, .failed)
        XCTAssertNil(GitHubRuns.status(runs: [], head: "local"))
    }

    func testStatesAndOverall() {
        let states = parse([
            run(1, "a", sha: "s", status: "queued", conclusion: ""),
            run(2, "b", sha: "s", conclusion: "skipped"),
            run(3, "c", sha: "s", conclusion: "timed_out"),
            run(4, "d", sha: "s", conclusion: "neutral"),
        ]).map(\.state)
        XCTAssertEqual(states, [.queued, .skipped, .failed, .passed])
        let passed = GitHubRuns.status(runs: parse([run(1, "a", sha: "s"), run(2, "b", sha: "s", conclusion: "skipped")]), head: "s")
        XCTAssertEqual(passed?.overall, .passed)
    }

    func testFailedJobsNameTheStepAndThePromptSaysWhereToLook() throws {
        let jobs = ["jobs": [
            ["name": "build", "conclusion": "success", "steps": [["name": "Checkout", "conclusion": "success"]]],
            ["name": "test", "conclusion": "failure", "steps": [["name": "Setup", "conclusion": "success"],
                                                                ["name": "Run tests", "conclusion": "failure"]]],
            ["name": "lint", "conclusion": "timed_out"],
        ]]
        let failed = GitHubRuns.parseFailedJobs(try JSONSerialization.data(withJSONObject: jobs))
        XCTAssertEqual(failed, ["test › Run tests", "lint"])

        var status = try XCTUnwrap(GitHubRuns.status(runs: parse([run(7, "Tests", sha: "abcdef123", conclusion: "failure")]), head: "abcdef123"))
        status.runs[0].failedJobs = failed
        let prompt = GitHubRuns.fixPrompt(status, branch: "feat/x")
        XCTAssertTrue(prompt.contains("feat/x"))
        XCTAssertTrue(prompt.contains("abcdef1"))
        XCTAssertTrue(prompt.contains("Tests (test › Run tests; lint)"))
        XCTAssertTrue(prompt.contains("gh run view 7 --log-failed"))
    }
}
