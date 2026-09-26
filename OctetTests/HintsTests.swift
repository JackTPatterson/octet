import XCTest

final class HintsTests: XCTestCase {
    func testFindsLinksPathsAndHashesWithLabelsInReadingOrder() {
        let lines = [
            "⏺ Fixed it in src/app/Greeter.swift:42:7 (see https://example.com/docs/a?b=1).",
            "  commit 3f2a9c1e on main; also ./README.md and Package.swift",
            "  version 1.2.3 and 2026.09.25 aren't paths; deadbeef has no digits? 1234567 neither",
        ]
        let hints = Hints.find(in: lines)
        XCTAssertEqual(hints.map(\.text), ["src/app/Greeter.swift:42:7", "https://example.com/docs/a?b=1", "3f2a9c1e", "./README.md"])
        XCTAssertEqual(hints.map(\.kind), [.path, .url, .hash, .path])
        XCTAssertEqual(hints.map(\.label), ["a", "s", "d", "f"])
        XCTAssertEqual(hints[0].row, 0)
        XCTAssertEqual(hints[0].column, 14)
        XCTAssertEqual(hints[0].line, 42)
        XCTAssertEqual(hints[0].lineColumn, 7)
        XCTAssertEqual(hints[2].row, 1)
    }

    func testPathsResolveFromThePanesFolder() {
        let hints = Hints.find(in: ["src/a.swift:3 ~/notes/todo.md /etc/hosts.conf"])
        XCTAssertEqual(hints.map { Hints.file(of: $0, cwd: "/repo", home: "/Users/me") },
                       ["/repo/src/a.swift", "/Users/me/notes/todo.md", "/etc/hosts.conf"])
    }

    func testLabelsGrowToTwoLetters() {
        XCTAssertEqual(Hints.labels(count: 3), ["a", "s", "d"])
        XCTAssertEqual(Hints.labels(count: 28).prefix(2), ["aa", "as"])
        XCTAssertEqual(Hints.labels(count: 28).count, 28)
    }

    func testImagesAndPDFsAreFoundByNameAndPreviewed() {
        let hints = Hints.find(in: ["Saved screenshot.png and report.PDF; see notes.txt"])
        XCTAssertEqual(hints.map(\.text), ["screenshot.png", "report.PDF"])
        XCTAssertTrue(Hints.prefersPreview("out/chart.svg"))
        XCTAssertTrue(Hints.prefersPreview("report.PDF"))
        XCTAssertFalse(Hints.prefersPreview("src/app.swift:12"))
        XCTAssertFalse(Hints.prefersPreview("Makefile"))
    }
}
