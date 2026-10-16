import XCTest

final class ReleaseNotesTests: XCTestCase {
    func testHTMLBecomesMarkdownBlocks() {
        let html = """
        <html><head><style>body { color: white }</style></head><body>
        <h2>What's new</h2>
        <ul>
          <li>A <strong>calmer</strong> status bar</li>
          <li>See <a href="https://example.com/notes">the notes</a> &amp; <code>octet --help</code></li>
        </ul>
        <p>Thanks to
           everyone.<br>More soon.</p>
        </body></html>
        """
        XCTAssertEqual(ReleaseNotes.markdown(fromHTML: html), """
        ## What's new

        - A **calmer** status bar
        - See [the notes](https://example.com/notes) & `octet --help`

        Thanks to everyone.
        More soon.
        """)
    }

    func testPreformattedTextKeepsItsLines() {
        let html = "<p>Run:</p><pre><code>brew upgrade\noctet &lt;dir&gt;</code></pre>"
        XCTAssertEqual(ReleaseNotes.markdown(fromHTML: html), "Run:\n\n```\nbrew upgrade\noctet <dir>\n```")
    }

    func testMarkdownAndPlainTextPassThrough() {
        XCTAssertEqual(ReleaseNotes.markdown("  # Hi\n- one  \n", format: "markdown"), "# Hi\n- one")
        XCTAssertEqual(ReleaseNotes.markdown("1 < 2", format: "plain-text"), "1 < 2")
        XCTAssertEqual(ReleaseNotes.markdown("<b>bold</b>", format: nil), "**bold**")
        XCTAssertEqual(ReleaseNotes.markdown("<b>bold</b>", format: "text/html"), "**bold**")
    }

    func testVersionsThatReadTheSameShowTheirBuild() {
        XCTAssertEqual(ReleaseNotes.versionLabel(display: "0.1.0", build: "19", comparedTo: "0.1.0"), "0.1.0 (19)")
        XCTAssertEqual(ReleaseNotes.versionLabel(display: "0.2.0", build: "20", comparedTo: "0.1.0"), "0.2.0")
        XCTAssertEqual(ReleaseNotes.versionLabel(display: "", build: "21", comparedTo: "0.1.0"), "21")
    }

    func testEntities() {
        XCTAssertEqual(ReleaseNotes.decodeEntities("&#8594; &#x2014; &amp;lt;"), "\u{2192} \u{2014} &lt;")
    }
}
