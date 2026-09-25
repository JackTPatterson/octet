import XCTest

final class WorktreeSetupTests: XCTestCase {
    /// A trimmed `worktree.create` result, as the session server returns it.
    private let result: [String: Any] = [
        "type": "worktree_created",
        "workspace": ["workspace_id": "w6", "worktree": [
            "repo_root": "/src/repo", "checkout_path": "/wt/repo/feat-x", "is_linked_worktree": true,
        ]],
        "root_pane": ["pane_id": "w6:p1", "cwd": "/wt/repo/feat-x"],
        "worktree": ["path": "/wt/repo/feat-x", "branch": "feat-x"],
    ]

    func testReadsWhereTheWorktreeAndItsPaneAre() {
        XCTAssertEqual(WorktreeSetup.parse(result),
                       WorktreeSetup.Created(repoRoot: "/src/repo", checkoutPath: "/wt/repo/feat-x", paneId: "w6:p1"))
        XCTAssertNil(WorktreeSetup.parse(["type": "ok"]))
        // Opening the main checkout isn't a new worktree.
        XCTAssertNil(WorktreeSetup.parse(["workspace": ["worktree": ["repo_root": "/src/repo", "checkout_path": "/src/repo"]]]))
    }

    func testCopiesTheProjectsEnvFilesButNotDependenciesOrLookalikes() {
        let ignored = [".env", ".env.local", "apps/web/.env.development.local", "node_modules/x/.env",
                       "packages/a/dist/.env", ".envrc", "config/env.json", ".environment", "api/.env"]
        XCTAssertEqual(WorktreeSetup.envFiles(ignored: ignored),
                       [".env", ".env.local", "api/.env", "apps/web/.env.development.local"])
    }

    func testOctetsScriptWinsOverConductors() {
        let conductor = Data(#"{"scripts":{"setup":"  bun install && cp $CONDUCTOR_ROOT_PATH/.env .  ","run":"bun dev"}}"#.utf8)
        let both = WorktreeSetup.script(in: "/wt", isExecutable: { $0 == "/wt/.octet/setup" }, read: { _ in conductor })
        XCTAssertEqual(both, .file(".octet/setup"))
        let onlyConductor = WorktreeSetup.script(in: "/wt", isExecutable: { _ in false },
                                                 read: { $0 == "/wt/conductor.json" ? conductor : nil })
        XCTAssertEqual(onlyConductor, .command("bun install && cp $CONDUCTOR_ROOT_PATH/.env ."))
        XCTAssertNil(WorktreeSetup.script(in: "/wt", isExecutable: { _ in false }, read: { _ in Data("{}".utf8) }))
        XCTAssertNil(WorktreeSetup.script(in: "/wt", isExecutable: { _ in false }, read: { _ in nil }))
    }

    func testEachWorktreeGetsItsOwnBlockOfPortsAndKeepsIt() {
        XCTAssertEqual(WorktreeSetup.port(for: "/a", assigned: [:]), 3100)
        XCTAssertEqual(WorktreeSetup.port(for: "/b", assigned: ["/a": 3100]), 3110)
        XCTAssertEqual(WorktreeSetup.port(for: "/c", assigned: ["/a": 3100, "/b": 3120]), 3110)
        XCTAssertEqual(WorktreeSetup.port(for: "/b", assigned: ["/a": 3100, "/b": 3120]), 3120)
        let full = Dictionary(uniqueKeysWithValues: stride(from: 3100, through: 3990, by: 10).map { ("/\($0)", $0) })
        XCTAssertNil(WorktreeSetup.port(for: "/new", assigned: full))
    }

    func testTheTypedLineSaysWhereItIsAndWhatItRuns() {
        let created = WorktreeSetup.Created(repoRoot: "/src/my repo", checkoutPath: "/wt/feat-x", paneId: "w6:p1")
        let quote = { (value: String) in "'" + value + "'" }
        XCTAssertEqual(WorktreeSetup.commandLine(.file(".octet/setup"), created: created, port: 3110, quote: quote),
                       "export OCTET_ROOT_PATH='/src/my repo' OCTET_WORKTREE_PATH='/wt/feat-x' OCTET_PORT=3110; ./.octet/setup")
        XCTAssertEqual(WorktreeSetup.commandLine(.command("bun install"), created: created, port: nil, quote: quote),
                       "export OCTET_ROOT_PATH='/src/my repo' OCTET_WORKTREE_PATH='/wt/feat-x'; bun install")
    }

    /// A real repository and a real `git worktree`, the way the session
    /// server makes one.
    func testCopiesIgnoredEnvFilesIntoARealWorktreeWithoutOverwriting() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo").path, worktree = base.appendingPathComponent("feat-x").path
        try FileManager.default.createDirectory(atPath: repo + "/apps/web", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/node_modules/x", withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
        }
        func write(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        try git("init", "-q")
        try write(repo + "/.gitignore", ".env*\nnode_modules\n")
        try write(repo + "/.env.example", "TRACKED=1\n")
        try git("add", "-f", ".gitignore", ".env.example")
        try git("commit", "-qm", "init")
        try write(repo + "/.env", "SECRET=1\n")
        try write(repo + "/.env.local", "LOCAL=1\n")
        try write(repo + "/apps/web/.env.development.local", "WEB=1\n")
        try write(repo + "/node_modules/x/.env", "DEP=1\n")
        try git("worktree", "add", "-q", "-b", "feat-x", worktree)
        // One the worktree already has stays as it is.
        try write(worktree + "/.env.local", "MINE=1\n")

        let copied = WorktreeSetup.copyEnvFiles(from: repo, to: worktree)

        XCTAssertEqual(copied, [".env", "apps/web/.env.development.local"])
        XCTAssertEqual(try String(contentsOfFile: worktree + "/.env", encoding: .utf8), "SECRET=1\n")
        XCTAssertEqual(try String(contentsOfFile: worktree + "/apps/web/.env.development.local", encoding: .utf8), "WEB=1\n")
        XCTAssertEqual(try String(contentsOfFile: worktree + "/.env.local", encoding: .utf8), "MINE=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + "/node_modules/x/.env"))
        // A second run finds nothing left to copy.
        XCTAssertEqual(WorktreeSetup.copyEnvFiles(from: repo, to: worktree), [])
    }
}
