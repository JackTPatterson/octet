import XCTest
@testable import Octet

final class PromptAuditTests: XCTestCase {
    private func roles(_ line: String) -> [(String, ShellSyntax.Role)] {
        ShellSyntax.spans(in: line).map { (String(line[$0.range]), $0.role) }
    }

    // MARK: Highlighting

    func testBraceExpansionStaysInsideItsWord() {
        let result = roles("echo ${HOME}/x {a,b}")
        XCTAssertEqual(result.map(\.0), ["echo", "${HOME}/x", "{a,b}"])
        XCTAssertEqual(result[0].1, .builtin)
        XCTAssertEqual(result[1].1, .variable)
    }

    func testStandaloneBracesAreStillGrouping() {
        let result = roles("{ ls; }")
        XCTAssertEqual(result.map(\.0), ["{", "ls", ";", "}"])
        XCTAssertEqual(result[1].1, .command)
    }

    func testDescriptorRedirectIsOneToken() {
        let result = roles("make 2>&1 | tee out.log")
        XCTAssertEqual(result.map(\.0), ["make", "2>&1", "|", "tee", "out.log"])
        XCTAssertEqual(result[1].1, .redirect)
        XCTAssertEqual(result[3].1, .command)
    }

    func testRedirectToFileStillTakesAPath() {
        let result = roles("echo hi > out.txt")
        XCTAssertEqual(result.last?.1, .path)
    }

    func testAssignmentsAfterExport() {
        XCTAssertEqual(roles("export TOKEN=abc").last?.1, .assignment)
        XCTAssertEqual(roles("echo TOKEN=abc").last?.1, .argument)
    }

    func testFlagValueIsSplitOut() {
        let result = roles("tool --config=/etc/app.toml --name=\"x y\"")
        XCTAssertEqual(result.map(\.0), ["tool", "--config=", "/etc/app.toml", "--name=", "\"x y\""])
        XCTAssertEqual(result[1].1, .flag)
        XCTAssertEqual(result[2].1, .path)
        XCTAssertEqual(result[4].1, .string)
    }

    // MARK: Completion context

    func testWordAfterAPipeCompletesAsACommand() {
        let line = "git log | gre"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertTrue(context.isCommandPosition)
        XCTAssertEqual(context.token, "gre")
    }

    func testSubcommandAfterAndAndBelongsToItsOwnCommand() {
        let line = "make && git ch"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertEqual(context.command, "git")
        XCTAssertEqual(context.previousWord, "git")
        XCTAssertEqual(context.token, "ch")
    }

    func testSeparatorStuckToTheWordEndsThePreviousOne() {
        let line = "cd x;ls"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertTrue(context.isCommandPosition)
        XCTAssertEqual(context.token, "ls")
    }

    func testDescriptorRedirectDoesNotStartACommand() {
        let line = "make 2>&1 --ver"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertEqual(context.command, "make")
    }

    func testQuotedSeparatorDoesNotCount() {
        let line = "echo \"a | b\" fil"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertEqual(context.command, "echo")
    }

    // MARK: Files and branches

    private func temporaryFolder() throws -> String {
        let path = NSTemporaryDirectory() + "prompt-audit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testDotfilesAppearOnceADotIsTyped() throws {
        let folder = try temporaryFolder()
        FileManager.default.createFile(atPath: folder + "/.env", contents: nil)
        FileManager.default.createFile(atPath: folder + "/readme.md", contents: nil)
        XCTAssertEqual(Completions.entries(for: "", cwd: folder).map(\.name), ["readme.md"])
        XCTAssertEqual(Completions.entries(for: ".e", cwd: folder).map(\.name), [".env", "readme.md"])
    }

    func testBranchesIncludePackedAndRemoteOnes() throws {
        let folder = try temporaryFolder()
        let git = folder + "/.git"
        try FileManager.default.createDirectory(atPath: git + "/refs/heads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: git + "/refs/remotes/origin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: git + "/refs/heads/main", contents: nil)
        FileManager.default.createFile(atPath: git + "/refs/remotes/origin/feature", contents: nil)
        try "# pack-refs\nabc123 refs/heads/packed-branch\nabc123 refs/remotes/origin/main\n^def456\n"
            .write(toFile: git + "/packed-refs", atomically: true, encoding: .utf8)
        XCTAssertEqual(Completions.branches(in: folder), ["main", "packed-branch", "feature"])
    }

    func testBranchesFromALinkedWorktree() throws {
        let main = try temporaryFolder()
        let gitDirectory = main + "/.git"
        try FileManager.default.createDirectory(atPath: gitDirectory + "/refs/heads", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: gitDirectory + "/worktrees/wt", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gitDirectory + "/refs/heads/trunk", contents: nil)
        try "../..\n".write(toFile: gitDirectory + "/worktrees/wt/commondir", atomically: true, encoding: .utf8)
        let worktree = try temporaryFolder()
        try "gitdir: \(gitDirectory)/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(Completions.branches(in: worktree), ["trunk"])
    }

    func testBranchesOfferedForMoreGitCommands() {
        let line = "git diff ma"
        let context = CompletionContext.at(caret: line.count, in: line)
        let results = Completions.suggestions(for: context, branches: ["main", "dev"])
        XCTAssertEqual(results.first?.value, "main")
        XCTAssertEqual(results.first?.kind, .branch)
    }

    func testScriptsUseTheProjectsPackageManager() throws {
        let json = Data(#"{"scripts":{"dev":"vite"}}"#.utf8)
        XCTAssertEqual(ProjectCommands.parseNpmScripts(json).first?.command, "npm run dev")
        XCTAssertEqual(ProjectCommands.parseNpmScripts(json, runner: "pnpm run").first?.command, "pnpm run dev")
    }

    // MARK: Quotes, escapes and spaces

    func testQuotedWordIsReadWhole() {
        let line = "cd \"My Do"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertEqual(context.token, "My Do")
        XCTAssertEqual(context.openQuote, "\"")
        XCTAssertEqual(context.range, 3..<line.count)
        XCTAssertEqual(context.command, "cd")
    }

    func testEscapedSpaceKeepsOneWord() {
        let line = "cat my\\ f"
        let context = CompletionContext.at(caret: line.count, in: line)
        XCTAssertEqual(context.token, "my f")
        XCTAssertNil(context.openQuote)
    }

    func testInsertionIsEscapedOrQuotedToMatchHowItWasTyped() {
        let plain = CompletionContext.at(caret: 6, in: "cat my")
        XCTAssertEqual(plain.insertion(for: Completion(value: "my file (1).txt", kind: .file)), "my\\ file\\ \\(1\\).txt")
        XCTAssertEqual(plain.insertion(for: Completion(value: "~notes/", kind: .directory)), "\\~notes/".replacingOccurrences(of: "\\~", with: "~"))
        let quoted = CompletionContext.at(caret: 7, in: "cat \"my")
        XCTAssertEqual(quoted.insertion(for: Completion(value: "my file.txt", kind: .file)), "\"my file.txt\"")
        XCTAssertEqual(quoted.insertion(for: Completion(value: "my folder/", kind: .directory)), "\"my folder/")
        XCTAssertEqual(plain.insertion(for: Completion(value: "main", kind: .branch)), "main")
    }

    func testFilesWithSpacesAreFound() throws {
        let folder = try temporaryFolder()
        FileManager.default.createFile(atPath: folder + "/my file.txt", contents: nil)
        let line = "cat my\\ f"
        let context = CompletionContext.at(caret: line.count, in: line)
        let entries = Completions.entries(for: context.token, cwd: folder)
        XCTAssertEqual(entries.map(\.name), ["my file.txt"])
        let results = Completions.suggestions(for: context, entries: entries)
        XCTAssertEqual(results.first.map { context.insertion(for: $0) }, "my\\ file.txt")
    }

    // MARK: History order

    func testFrecentHistoryLeadsAndKeepsItsOrder() {
        let line = "gi"
        let context = CompletionContext.at(caret: line.count, in: line)
        let results = Completions.suggestions(
            for: context, commands: ["git", "gist", "gimp"],
            history: ["git status", "git stash", "git switch main"], historyIsRanked: true)
        XCTAssertEqual(results.prefix(3).map(\.value), ["git status", "git stash", "git switch main"])
        XCTAssertTrue(results.dropFirst(3).allSatisfy { $0.kind == .command })
    }

    func testFrecencyCountsRepeatsAndRecency() {
        var history = CommandHistory()
        let now = Date()
        for _ in 0..<12 { history.add(.init(command: "swift test", at: now.addingTimeInterval(-86_400 * 20))) }
        history.add(.init(command: "swift build", at: now))
        history.add(.init(command: "ls", at: now.addingTimeInterval(-86_400 * 300)))
        history.hidden = ["ls"]
        let order = history.frecencyOrdered()
        XCTAssertEqual(order.first, "swift test")
        XCTAssertFalse(order.contains("ls"))
    }

    func testFolderHabitsAreCounted() {
        var sequences = CommandSequences(history: [])
        sequences.add(command: "npm run dev", in: "/work/app")
        sequences.add(command: "npm run dev", in: "/work/app")
        XCTAssertEqual(sequences.count(of: "npm run dev", in: "/work/app"), 2)
        XCTAssertEqual(sequences.count(of: "npm run dev", in: "/work/other"), 0)
    }

    // MARK: Strings

    func testVariablesInsideDoubleQuotesGetTheirOwnSpans() {
        let line = "echo \"hi $USER and ${HOME}x\" '$no'"
        let result = roles(line)
        XCTAssertEqual(result.map(\.0), ["echo", "\"hi ", "$USER", " and ", "${HOME}", "x\"", "'$no'"])
        XCTAssertEqual(result[2].1, .variable)
        XCTAssertEqual(result[1].1, .string)
        XCTAssertEqual(result[6].1, .string)
        // Laid end to end, they never overlap.
        let spans = ShellSyntax.spans(in: line)
        for pair in zip(spans, spans.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.range.upperBound, pair.1.range.lowerBound) }
    }
}
