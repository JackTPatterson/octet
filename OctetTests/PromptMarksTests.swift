import XCTest

final class PromptMarksTests: XCTestCase {
    /// The session server's own output, from a live run.
    private let response: [String: Any] = [
        "type": "pane_marks", "pane_id": "w1:p1", "total_rows": 75, "viewport_rows": 40,
        "marks": [
            ["prompt_row": 2, "output_row": 3, "end_row": 4, "exit_code": 0, "started_at_ms": 1790379223085,
             "finished_at_ms": 1790379223085, "command": "echo hi"],
            ["prompt_row": 5, "output_row": 6, "end_row": 6, "exit_code": 1, "started_at_ms": 1000, "finished_at_ms": 1340,
             "command": "false"],
            ["prompt_row": 7, "output_row": 8, "end_row": 68, "exit_code": 0, "started_at_ms": 3897, "finished_at_ms": 4212,
             "command": "seq 1 60"],
            ["prompt_row": 69, "output_row": NSNull(), "end_row": NSNull(), "exit_code": NSNull(),
             "started_at_ms": NSNull(), "finished_at_ms": NSNull(), "command": NSNull()],
        ],
    ]

    func testReadsMarksAndFindsTheLastFinishedCommand() throws {
        let marks = try XCTUnwrap(PromptMarks(response: response))
        XCTAssertEqual(marks.promptRows, [2, 5, 7, 69])
        XCTAssertEqual(marks.lastFinished?.command, "seq 1 60")
        XCTAssertEqual(marks.marks[1].duration ?? 0, 0.34, accuracy: 0.001)
        XCTAssertFalse(marks.marks[3].finished)
    }

    func testSummaries() throws {
        let marks = try XCTUnwrap(PromptMarks(response: response))
        XCTAssertEqual(PromptMarks.summary(marks.marks[1]), "✗ 1 · 340ms")
        XCTAssertEqual(PromptMarks.summary(marks.marks[2]), "✓ 315ms")
        XCTAssertEqual(PromptMarks.format(75), "1m 15s")
        XCTAssertEqual(PromptMarks.format(3.24), "3.2s")
    }

    func testCopiesACommandsOutputRows() throws {
        let marks = try XCTUnwrap(PromptMarks(response: response))
        var lines = Array(repeating: "", count: 75)
        lines[2] = "$ echo hi"; lines[3] = "hi   "
        for n in 8..<68 { lines[n] = String(n - 7) }
        XCTAssertEqual(PromptMarks.output(of: marks.marks[0], in: lines), "hi")
        XCTAssertEqual(PromptMarks.output(of: marks.marks[2], in: lines)?.split(separator: "\n").count, 60)
        XCTAssertNil(PromptMarks.output(of: marks.marks[1], in: lines))  // no output
    }
}
