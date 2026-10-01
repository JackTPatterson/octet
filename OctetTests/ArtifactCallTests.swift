import XCTest

final class ArtifactCallTests: XCTestCase {
    func testAPublishReadsItsLinkFromTheResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octet-artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("report.html")
        try Data("<!doctype html><html><head><title>Q3 &amp; Q4 Report</title></head></html>".utf8).write(to: page)

        let call = try XCTUnwrap(ArtifactCall(
            tool: "Artifact",
            input: ["file_path": page.path, "icon": "chart", "description": "Revenue by quarter."],
            result: "Published https://claude.ai/code/artifact/4f1c2d9e-aaaa-bbbb-cccc-0123456789ab (private). Subscribed."))
        XCTAssertEqual(call.action, .publish)
        XCTAssertEqual(call.url?.absoluteString, "https://claude.ai/code/artifact/4f1c2d9e-aaaa-bbbb-cccc-0123456789ab")
        XCTAssertEqual(call.title, "Q3 & Q4 Report")
        XCTAssertEqual(call.detail, "Revenue by quarter.")
        XCTAssertEqual(call.summary, "Published Q3 & Q4 Report")
    }

    func testTheCallsOwnLinkAndTitleWin() throws {
        let call = try XCTUnwrap(ArtifactCall(
            tool: "Artifact",
            input: ["action": "open", "url": "https://claude.ai/artifact/abc123", "title": "Roadmap"],
            result: "See https://claude.ai/artifact/other"))
        XCTAssertEqual(call.action, .open)
        XCTAssertEqual(call.url?.absoluteString, "https://claude.ai/artifact/abc123")
        XCTAssertEqual(call.summary, "Opened Roadmap")
    }

    func testOnlyArtifactToolsCount() {
        XCTAssertNil(ArtifactCall(tool: "WebFetch", input: ["url": "https://claude.ai/artifact/x"], result: nil))
        XCTAssertEqual(ArtifactCall(tool: "ArtifactComments", input: [:], result: nil)?.action, .comments)
        // A page with no title falls back to its file name, and a missing file to nothing worse.
        XCTAssertEqual(ArtifactCall(tool: "Artifact", input: ["file_path": "/nonexistent/page.html"], result: nil)?.title, "page.html")
        // Other claude.ai pages aren't artifact links.
        XCTAssertNil(ArtifactCall.firstLink(in: "https://claude.ai/settings"))
    }

    func testPageTitles() {
        XCTAssertEqual(ArtifactCall.pageTitle(in: "<TITLE lang=en>  Plan  </TITLE>"), "Plan")
        XCTAssertNil(ArtifactCall.pageTitle(in: "<title></title>"))
        XCTAssertNil(ArtifactCall.pageTitle(in: "<h1>No title</h1>"))
    }
}
