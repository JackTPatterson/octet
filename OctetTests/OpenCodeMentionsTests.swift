import XCTest

final class OpenCodeMentionsTests: XCTestCase {
    private let files: Set<String> = ["/work/src/app.ts", "/work/README.md", "/etc/hosts"]

    private func parts(_ text: String) -> [[String: Any]] {
        OpenCodeMentions.fileParts(in: text, cwd: "/work", isFile: files.contains)
    }

    func testMentionsOfFilesBecomeFileParts() {
        let found = parts("Look at @src/app.ts and @README.md, then @/etc/hosts.")
        XCTAssertEqual(found.compactMap { $0["filename"] as? String }, ["app.ts", "README.md", "hosts"])
        XCTAssertEqual(found.first?["url"] as? String, "file:///work/src/app.ts")
        let source = found.first?["source"] as? [String: Any]
        XCTAssertEqual(source?["path"] as? String, "src/app.ts")
        let span = source?["text"] as? [String: Any]
        XCTAssertEqual(span?["value"] as? String, "@src/app.ts")
        XCTAssertEqual(span?["start"] as? Int, 8)
        XCTAssertEqual(span?["end"] as? Int, 19)
    }

    func testOtherMentionsAreLeftAlone() {
        XCTAssertTrue(parts("Ask @reviewer, mail me@example.com, or see @missing.txt").isEmpty)
        XCTAssertEqual(parts("@README.md and @README.md again").count, 1)
    }
}
