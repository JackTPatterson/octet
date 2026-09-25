import XCTest

final class CopyTidyTests: XCTestCase {
    func testClaudesBulletAndIndentComeOffButCodeKeepsItsShape() {
        let copied = """
        ⏺ Here's the fix for the greeting:   
          
          func greet() -> String {
              excited ? "Hi!" : "Hi"
          }
        """
        XCTAssertEqual(CopyTidy.tidy(copied), """
        Here's the fix for the greeting:

        func greet() -> String {
            excited ? "Hi!" : "Hi"
        }
        """)
    }

    func testToolOutputUnderItsHook() {
        XCTAssertEqual(CopyTidy.tidy("  ⎿  Found 3 files\n     src/a.swift\n     src/b.swift  "),
                       "Found 3 files\nsrc/a.swift\nsrc/b.swift")
    }

    func testBoxEdgesComeOffOnlyWhenEveryLineHasThem() {
        XCTAssertEqual(CopyTidy.tidy("│ > fix the tests      │\n│   and the linter     │"), "> fix the tests\n  and the linter")
        XCTAssertEqual(CopyTidy.tidy("a │ b\nc"), "a │ b\nc")
    }

    func testOrdinaryTextIsLeftAlone() {
        XCTAssertEqual(CopyTidy.tidy("git status\n•not a marker"), "git status\n•not a marker")
        XCTAssertEqual(CopyTidy.tidy("  - one\n    - two"), "- one\n  - two")
    }

    func testMarkdownReadsAsPlainText() {
        let markdown = """
        ## Plan
        Use **bold** and `code` and [the docs](https://example.com).
        ```swift
        let a = 1
        ```
        - item
        """
        XCTAssertEqual(MarkdownPlain.plain(markdown), """
        Plan
        Use bold and code and the docs.
        let a = 1
        - item
        """)
    }
}
