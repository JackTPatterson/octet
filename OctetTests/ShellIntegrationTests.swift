import XCTest

/// Runs real zsh through the installed wrapper and reads the marks it writes.
final class ShellIntegrationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-si-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testTheWrapperNamesTheRealShellAndIsExecutable() throws {
        let wrapper = try ShellIntegration.install(in: base.appendingPathComponent("si"), shell: "/bin/zsh", login: true)
        let text = try String(contentsOfFile: wrapper, encoding: .utf8)
        XCTAssertTrue(text.contains("shell='/bin/zsh'"))
        XCTAssertTrue(text.contains("exec -l \"$shell\""))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper))
        XCTAssertTrue(ShellIntegration.wrapperScript(shell: "/bin/zsh", login: false, directory: "/x").contains("exec \"$shell\" \"$@\""))
        XCTAssertEqual(ShellIntegration.quote("it's"), "'it'\\''s'")
    }

    /// An interactive zsh started through the wrapper, with the user's own
    /// .zshrc (from a ZDOTDIR) still loading, marks its prompt and a failing
    /// command's status.
    func testZshMarksPromptsAndStatusAndStillLoadsTheUsersFiles() throws {
        let home = base.appendingPathComponent("home")
        let userDots = base.appendingPathComponent("dots")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDots, withIntermediateDirectories: true)
        try "export FROM_USER_RC=yes\n".write(to: userDots.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let wrapper = try ShellIntegration.install(in: base.appendingPathComponent("si"), shell: "/bin/zsh", login: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapper)
        // -i for an interactive shell reading its commands from stdin.
        process.arguments = ["-i"]
        process.environment = ["HOME": home.path, "ZDOTDIR": userDots.path, "TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data("echo rc=$FROM_USER_RC shell=$SHELL\nfalse\nexit\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("rc=yes"), text)
        XCTAssertTrue(text.contains("shell=/bin/zsh"), text)
        XCTAssertTrue(text.contains("\u{1b}]133;A\u{07}"), text)
        XCTAssertTrue(text.contains("\u{1b}]133;C\u{07}"), text)
        XCTAssertTrue(text.contains("\u{1b}]133;D;0\u{07}"), text)
        XCTAssertTrue(text.contains("\u{1b}]133;D;1\u{07}"), text)
    }
}

final class ShellAccountTests: XCTestCase {
    func testTheTableListsFoldersShallowFirstWithTheirWorktrees() {
        let work = AccountProfile(id: "w", name: "Work", agent: "claude", home: "~/.claude-work")
        let side = AccountProfile(id: "s", name: "Side", agent: "claude", home: "/acct/side")
        let table = ShellIntegration.accountTable(
            profiles: [work, side],
            assignments: [AccountAssignment(folder: "/src/api/sub", profileId: "s"), AccountAssignment(folder: "/src/api", profileId: "w")],
            worktrees: { $0 == "/src/api" ? ["/wt/api/feat"] : [] }, userHome: "/Users/me")
        XCTAssertEqual(table, """
        /src/api\tCLAUDE_CONFIG_DIR\t/Users/me/.claude-work
        /src/api/sub\tCLAUDE_CONFIG_DIR\t/acct/side
        /wt/api/feat\tCLAUDE_CONFIG_DIR\t/Users/me/.claude-work

        """)
    }

    /// A shell the session server starts in an assigned folder gets the
    /// account; the deeper folder wins; one started with an account keeps it.
    func testTheWrapperSetsTheFoldersAccount() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("octet-acct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appendingPathComponent("api"), deeper = project.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent("si")
        let wrapper = try ShellIntegration.install(in: dir, shell: "/bin/zsh", login: false)
        let table = ShellIntegration.accountTable(
            profiles: [AccountProfile(id: "w", name: "Work", agent: "claude", home: "/acct/work"),
                       AccountProfile(id: "s", name: "Side", agent: "claude", home: "/acct/side")],
            assignments: [AccountAssignment(folder: project.path, profileId: "w"),
                          AccountAssignment(folder: deeper.path, profileId: "s")])
        ShellIntegration.writeAccountTable(table, in: dir)

        func run(in folder: URL, env: [String: String] = [:]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: wrapper)
            process.arguments = ["-c", "echo \"$CLAUDE_CONFIG_DIR\""]
            process.currentDirectoryURL = folder
            process.environment = ["HOME": base.path, "PATH": "/usr/bin:/bin"].merging(env) { _, new in new }
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try run(in: project), "/acct/work")
        XCTAssertEqual(try run(in: deeper), "/acct/side")
        XCTAssertEqual(try run(in: base), "")
        XCTAssertEqual(try run(in: project, env: ["CLAUDE_CONFIG_DIR": "/signing-in"]), "/signing-in")
    }
}
