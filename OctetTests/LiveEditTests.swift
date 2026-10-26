import XCTest
@testable import Octet

final class LiveEditTests: XCTestCase {
    func testNothingChanged() {
        XCTAssertNil(LiveEdit.between(old: "a\nb", new: "a\nb"))
    }

    func testReplacementInTheMiddle() throws {
        let edit = try XCTUnwrap(LiveEdit.between(old: "let a = 1\nlet b = 2\nlet c = 3\n", new: "let a = 1\nlet b = 20\nlet c = 3\n"))
        // "2" became "20": the 0 is what was typed.
        XCTAssertEqual(edit.oldRange, NSRange(location: 19, length: 0))
        XCTAssertEqual(edit.newRange, NSRange(location: 19, length: 1))
        XCTAssertEqual(edit.hunks, [NSRange(location: 10, length: 10)])
        XCTAssertEqual(edit.cursor, 20)
    }

    func testAppendedLines() throws {
        let edit = try XCTUnwrap(LiveEdit.between(old: "one\n", new: "one\ntwo\nthree\n"))
        XCTAssertEqual(edit.newRange, NSRange(location: 4, length: 10))
        XCTAssertEqual(edit.cursor, 14)
    }

    func testDeletionLeavesAPlaceToPointAt() throws {
        let edit = try XCTUnwrap(LiveEdit.between(old: "a\nb\nc\n", new: "a\nc\n"))
        XCTAssertEqual(edit.newRange.length, 0)
        XCTAssertEqual(edit.hunks, [NSRange(location: 2, length: 0)])
    }

    func testSeveralSeparateChangesAreSeveralHunks() throws {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...10).map { "line \($0)" }
        lines[1] = "changed 2"
        lines[8] = "changed 9"
        let edit = try XCTUnwrap(LiveEdit.between(old: old, new: lines.joined(separator: "\n")))
        XCTAssertEqual(edit.hunks.count, 2)
        // The cursor rests at the end of the last line touched.
        XCTAssertEqual(edit.cursor, NSMaxRange(edit.hunks[1]))
    }

    func testCountsInUTF16() throws {
        let edit = try XCTUnwrap(LiveEdit.between(old: "😀 a", new: "😀 ab"))
        XCTAssertEqual(edit.newRange, NSRange(location: 4, length: 1))
        // A change inside an emoji's pair never splits it.
        let swapped = try XCTUnwrap(LiveEdit.between(old: "x😀y", new: "x😁y"))
        XCTAssertEqual(swapped.newRange, NSRange(location: 1, length: 2))
    }

    func testWhereAPendingEditWillLand() {
        XCTAssertEqual(LiveEdit.location(of: "beta", in: "alpha\nbeta\n"), 6)
        XCTAssertNil(LiveEdit.location(of: "gamma", in: "alpha\nbeta\n"))
        XCTAssertNil(LiveEdit.location(of: "", in: "alpha"))
    }
}
