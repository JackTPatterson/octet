import XCTest

final class TerminalFileLinkTests: XCTestCase {
    private let files: Set<String> = ["/work/app/src/main.swift", "/work/app/README.md", "/Users/me/notes.txt", "/work/app/odd:name"]
    private func resolve(_ link: String, cwd: String? = "/work/app") -> TerminalFileLink.Target? {
        TerminalFileLink.resolve(link, cwd: cwd, isFile: files.contains)
    }

    func testRelativePathsResolveAgainstTheShellsFolder() {
        XCTAssertEqual(resolve("src/main.swift"), .init(path: "/work/app/src/main.swift", line: nil))
        XCTAssertEqual(resolve("./README.md"), .init(path: "/work/app/README.md", line: nil))
        XCTAssertEqual(resolve("../app/README.md"), .init(path: "/work/app/README.md", line: nil))
        XCTAssertNil(resolve("README.md", cwd: nil))
    }

    func testLinesAsCompilersPrintThem() {
        XCTAssertEqual(resolve("src/main.swift:42"), .init(path: "/work/app/src/main.swift", line: 42))
        XCTAssertEqual(resolve("src/main.swift:42:7:"), .init(path: "/work/app/src/main.swift", line: 42))
        XCTAssertEqual(resolve("/work/app/src/main.swift(9,2)"), .init(path: "/work/app/src/main.swift", line: 9))
        // No folder before it: still a path, not a URL scheme.
        XCTAssertEqual(resolve("README.md:3"), .init(path: "/work/app/README.md", line: 3))
        // A name with a colon in it is taken as written.
        XCTAssertEqual(resolve("odd:name"), .init(path: "/work/app/odd:name", line: nil))
    }

    func testOtherLinksAreLeftAlone() {
        XCTAssertEqual(resolve("file:///work/app/README.md"), .init(path: "/work/app/README.md", line: nil))
        XCTAssertNil(resolve("https://example.com/README.md"))
        XCTAssertNil(resolve("mailto:me@example.com"))
        XCTAssertNil(resolve("src/missing.swift"))
        XCTAssertNil(resolve("src"))
    }
}

final class TerminalFileLinkWordTests: XCTestCase {
    func testTheWordUnderTheClick() {
        let line = "error: src/main.swift:42:7: missing return (see 'README.md')."
        XCTAssertEqual(TerminalFileLink.word(inLine: line, column: 10), "src/main.swift:42:7:")
        XCTAssertEqual(TerminalFileLink.word(inLine: line, column: 51), "README.md")
        XCTAssertNil(TerminalFileLink.word(inLine: line, column: 6))
        XCTAssertNil(TerminalFileLink.word(inLine: line, column: 400))
        XCTAssertEqual(TerminalFileLink.word(inLine: "edited notes.md.", column: 9), "notes.md")
    }

    func testDiffPathsLoseTheirSidePrefix() {
        let target = TerminalFileLink.resolve("b/src/main.swift", cwd: "/work/app") { $0 == "/work/app/src/main.swift" }
        XCTAssertEqual(target, .init(path: "/work/app/src/main.swift", line: nil))
    }
}
