import XCTest

final class ShellPassthroughTests: XCTestCase {
    func testOnlyALeadingBangIsACommand() {
        XCTAssertEqual(ShellPassthrough.command(in: "!git status"), "git status")
        XCTAssertEqual(ShellPassthrough.command(in: "  ! npm test \n"), "npm test")
        XCTAssertNil(ShellPassthrough.command(in: "!"))
        XCTAssertNil(ShellPassthrough.command(in: "! "))
        XCTAssertNil(ShellPassthrough.command(in: "run !this"))
        XCTAssertNil(ShellPassthrough.command(in: "/compact"))
    }

    func testOutputGoesWithTheNextMessage() {
        let runs = [ShellPassthrough.Run(command: "ls", output: "a\nb", status: 0),
                    ShellPassthrough.Run(command: "false", output: "", status: 1)]
        let sent = ShellPassthrough.outgoing("why did that fail?", runs: runs)
        XCTAssertTrue(sent.usedRuns)
        XCTAssertTrue(sent.text.hasPrefix("I ran these commands myself"))
        XCTAssertTrue(sent.text.contains("<bash-input>ls</bash-input>\n<bash-stdout>a\nb</bash-stdout>"))
        XCTAssertTrue(sent.text.contains("<bash-exit-code>1</bash-exit-code>"))
        XCTAssertFalse(sent.text.contains("<bash-exit-code>0"))
        XCTAssertTrue(sent.text.hasSuffix("\n\nwhy did that fail?"))

        // A slash command still works; the output waits.
        let command = ShellPassthrough.outgoing("/compact", runs: runs)
        XCTAssertEqual(command.text, "/compact")
        XCTAssertFalse(command.usedRuns)
        XCTAssertEqual(ShellPassthrough.outgoing("hi", runs: []).text, "hi")
    }

    func testLongOutputKeepsItsStartAndEnd() {
        let output = String(repeating: "a", count: 5000) + String(repeating: "z", count: 5000)
        let clipped = ShellPassthrough.clip(output, limit: 3000)
        XCTAssertTrue(clipped.hasPrefix("aaaa"))
        XCTAssertTrue(clipped.hasSuffix("zzzz"))
        XCTAssertTrue(clipped.contains("characters left out"))
        XCTAssertLessThan(clipped.count, 3100)
        XCTAssertEqual(ShellPassthrough.clip("short"), "short")
    }
}
