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
