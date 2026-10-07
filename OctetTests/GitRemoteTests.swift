import XCTest

final class GitRemoteTests: XCTestCase {
    func testEveryWayARemoteIsSpelledIsItsWebPage() {
        let page = "https://github.com/JackTPatterson/octet"
        for remote in ["git@github.com:JackTPatterson/octet.git", "https://github.com/JackTPatterson/octet.git",
                       "https://jack@github.com/JackTPatterson/octet", "ssh://git@github.com/JackTPatterson/octet.git",
                       "ssh://git@ssh.github.com:443/JackTPatterson/octet.git", "https://github.com/JackTPatterson/octet/"] {
            XCTAssertEqual(GitRemote.webURL(remote)?.absoluteString, page, remote)
        }
        XCTAssertEqual(GitRemote.webURL("git@gitlab.com:group/sub/repo.git")?.absoluteString, "https://gitlab.com/group/sub/repo")
        // Local remotes have no page.
        XCTAssertNil(GitRemote.webURL("/Users/me/repos/octet.git"))
        XCTAssertNil(GitRemote.webURL("../octet"))
        XCTAssertNil(GitRemote.webURL(""))
    }

    func testPullRequestPagesPerHost() {
        XCTAssertEqual(GitRemote.pullRequestURL(remote: "git@github.com:a/b.git", branch: "feature/x", base: "origin/main")?.absoluteString,
                       "https://github.com/a/b/compare/main...feature/x?expand=1")
        XCTAssertEqual(GitRemote.pullRequestURL(remote: "git@github.com:a/b.git", branch: "x", base: nil)?.absoluteString,
                       "https://github.com/a/b/compare/x?expand=1")
        let gitlab = GitRemote.pullRequestURL(remote: "https://gitlab.com/a/b.git", branch: "x", base: "origin/main")
        XCTAssertEqual(gitlab?.path, "/a/b/-/merge_requests/new")
        XCTAssertTrue(gitlab?.query?.contains("source_branch%5D=x") == true || gitlab?.query?.contains("source_branch]=x") == true)
        XCTAssertEqual(GitRemote.pullRequestURL(remote: "git@bitbucket.org:a/b.git", branch: "x", base: "main")?.path, "/a/b/pull-requests/new")
        XCTAssertEqual(GitRemote.pullRequestURL(remote: "git@git.example.com:a/b.git", branch: "x", base: nil)?.absoluteString,
                       "https://git.example.com/a/b")
        XCTAssertEqual(GitRemote.shortBase("origin/main"), "main")
        XCTAssertEqual(GitRemote.shortBase("main"), "main")
    }

    func testPushPublishesABranchWithoutAnUpstream() {
        XCTAssertEqual(GitRemote.pushArguments(branch: "x", upstream: "origin/x", remotes: ["origin"]), ["push"])
        XCTAssertEqual(GitRemote.pushArguments(branch: "x", upstream: nil, remotes: ["upstream", "origin"]), ["push", "-u", "origin", "x"])
        XCTAssertEqual(GitRemote.pushArguments(branch: "x", upstream: nil, remotes: ["fork"]), ["push", "-u", "fork", "x"])
        XCTAssertNil(GitRemote.pushArguments(branch: "x", upstream: nil, remotes: []))
        XCTAssertNil(GitRemote.pushArguments(branch: nil, upstream: nil, remotes: ["origin"]))
    }

    func testCommitTakesTheStagedOrEverything() {
        let staged = AgentGit.FileChange(path: "a", kind: .modified, staged: true)
        let loose = AgentGit.FileChange(path: "b", kind: .untracked, staged: false)
        XCTAssertEqual(GitRemote.commitPlan(files: [staged, loose]).stageAll, false)
        XCTAssertEqual(GitRemote.commitPlan(files: [staged, loose]).count, 1)
        XCTAssertEqual(GitRemote.commitPlan(files: [loose, loose]).stageAll, true)
        XCTAssertEqual(GitRemote.commitPlan(files: [loose, loose]).count, 2)
    }

    func testGitErrorsInPlainWords() {
        XCTAssertTrue(GitRemote.explain("fatal: Not possible to fast-forward, aborting.").hasPrefix("The branch and its upstream"))
        XCTAssertTrue(GitRemote.explain(" ! [rejected]        main -> main (fetch first)\nerror: failed to push").hasPrefix("The remote has commits"))
        XCTAssertTrue(GitRemote.explain("git@github.com: Permission denied (publickey).").hasPrefix("Git couldn't sign in"))
        XCTAssertEqual(GitRemote.explain("hint: something\nfatal: bad revision 'x'"), "bad revision 'x'")
        XCTAssertEqual(GitRemote.explain("something odd"), "something odd")
    }
}
