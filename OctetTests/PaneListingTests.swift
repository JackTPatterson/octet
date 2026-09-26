import XCTest

final class PaneListingTests: XCTestCase {
    func testListsPanesWithTheOneInFrontMarked() {
        let snapshot: [String: Any] = [
            "focused_pane_id": "w1:p2",
            "panes": [
                ["pane_id": "w1:p1", "agent": "claude", "agent_status": "working", "cwd": "/a", "foreground_cwd": "/a/src"],
                ["pane_id": "w1:p2", "agent_status": "unknown", "cwd": "/b"],
                ["agent": "no id"],
            ],
        ]
        XCTAssertEqual(PaneListing.lines(snapshot: snapshot), ["w1:p1\tclaude\tworking\t/a/src\t", "w1:p2\t-\tunknown\t/b\t*"])
    }

    func testTrimsTheBlankRowsBelowTheText() {
        XCTAssertEqual(PaneListing.trimmed("$ ls   \nfile  \n\n   \n\n"), "$ ls\nfile")
    }
}
