import XCTest

final class MarkdownHTMLTests: XCTestCase {
    func testBlocksBecomeHTML() {
        let html = MarkdownHTML.body("# Build from source\n\nSome **bold**, *soft* and `a < b`.\n\n- one\n- two\n  - nested\n\n1. first\n2. second\n\n```swift\nlet x = 1 < 2\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---")
        XCTAssertTrue(html.contains("<h1 id=\"build-from-source\">Build from source</h1>"))
        XCTAssertTrue(html.contains("<p>Some <strong>bold</strong>, <em>soft</em> and <code>a &lt; b</code>.</p>"))
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two<ul>\n<li>nested</li></ul>\n</li></ul>"))
        XCTAssertTrue(html.contains("<ol>\n<li>first</li>\n<li>second</li></ol>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
        XCTAssertTrue(html.contains("<th>A</th><th>B</th>") && html.contains("<td>1</td><td>2</td>"))
        XCTAssertTrue(html.hasSuffix("<hr>\n"))
    }

    func testTheFilesOwnHTMLPassesThrough() {
        let html = MarkdownHTML.body("<div align=\"center\">\n\n<img src=\"logo.png\" width=\"58\">\n\n### Title\n\n</div>")
        XCTAssertEqual(html, "<div align=\"center\">\n<img src=\"logo.png\" width=\"58\">\n<h3 id=\"title\">Title</h3>\n</div>\n")
    }

    func testLinksImagesAndEntities() {
        XCTAssertEqual(MarkdownHTML.inline("[![CI](badge.svg)](https://ci.example) &nbsp;and AT&T"),
                       "<a href=\"https://ci.example\"><img src=\"badge.svg\" alt=\"CI\"></a> &nbsp;and AT&amp;T")
        XCTAssertEqual(MarkdownHTML.inline("see https://example.com/a_b_c."),
                       "see <a href=\"https://example.com/a_b_c\">https://example.com/a_b_c</a>.")
        XCTAssertEqual(MarkdownHTML.inline("<https://x.dev> and <kbd>⌘</kbd>"),
                       "<a href=\"https://x.dev\">https://x.dev</a> and <kbd>⌘</kbd>")
        XCTAssertEqual(MarkdownHTML.inline("snake_case_name stays"), "snake_case_name stays")
    }

    func testTasksAndAlerts() {
        let html = MarkdownHTML.body("- [x] done\n- [ ] todo\n\n> [!NOTE]\n> Octet is pre-1.0.")
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked> done"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled> todo"))
        XCTAssertTrue(html.contains("<div class=\"alert alert-note\"><p class=\"alert-title\">Note</p><p>Octet is pre-1.0.</p></div>"))
    }
}
