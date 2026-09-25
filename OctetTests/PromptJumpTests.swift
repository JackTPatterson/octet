import XCTest

final class PromptJumpTests: XCTestCase {
    private let lines = [
        "me@mac ~ % seq 1 3", "1", "2", "3",
        "me@mac ~ % cd proj", "me@mac proj % ls", "a.txt", "b.txt",
        "me@mac proj % ",
    ]

    func testFindsPromptsShapedLikeTheCurrentOne() {
        XCTAssertEqual(PromptJump.promptRows(lines), [0, 4, 5, 8])
        XCTAssertEqual(PromptJump.promptRows(["❯ make", "ok", "❯ "]), [0, 2])
        XCTAssertEqual(PromptJump.promptRows(["some output", "no prompt here"]), [])
    }

    func testUpAndDownMoveBetweenPromptsAndDownPastTheLastIsLive() {
        let rows = PromptJump.promptRows(lines)
        // 9 rows, 3 visible: at the bottom the top row is 6.
        XCTAssertEqual(PromptJump.offset(.up, rows: rows, currentOffset: 0, total: 9, viewport: 3), 1)   // row 5 on top
        XCTAssertEqual(PromptJump.offset(.up, rows: rows, currentOffset: 1, total: 9, viewport: 3), 2)   // row 4
        XCTAssertEqual(PromptJump.offset(.up, rows: rows, currentOffset: 2, total: 9, viewport: 3), 6)   // row 0
        XCTAssertNil(PromptJump.offset(.up, rows: rows, currentOffset: 6, total: 9, viewport: 3))
        XCTAssertEqual(PromptJump.offset(.down, rows: rows, currentOffset: 6, total: 9, viewport: 3), 2)
        XCTAssertEqual(PromptJump.offset(.down, rows: rows, currentOffset: 1, total: 9, viewport: 3), 0)
        XCTAssertNil(PromptJump.offset(.down, rows: rows, currentOffset: 0, total: 9, viewport: 3))
    }
}
