import XCTest

final class LiveScrollTests: XCTestCase {
    private func scroll(_ offset: Int, _ max: Int) -> PaneScroll {
        PaneScroll(offsetFromBottom: offset, maxOffsetFromBottom: max, viewportRows: 50)
    }

    func testAPaneAtTheBottomIsLiveHoweverMuchArrives() {
        var tracker = LiveScrollTracker()
        tracker.update(scroll(0, 100))
        tracker.update(scroll(0, 400))
        XCTAssertTrue(tracker.isLive)
        XCTAssertEqual(tracker.newLines, 0)
    }

    /// The session server's own numbers: scrolled up 40, then 26 lines of
    /// output push the view 26 further from the bottom.
    func testOutputBelowAScrolledBackViewIsCounted() {
        var tracker = LiveScrollTracker()
        tracker.update(scroll(0, 253))
        tracker.update(scroll(40, 253))
        XCTAssertFalse(tracker.isLive)
        XCTAssertEqual(tracker.label, "Jump to live")
        tracker.update(scroll(66, 279))
        XCTAssertEqual(tracker.newLines, 26)
        XCTAssertEqual(tracker.label, "26 new lines")
        tracker.update(scroll(67, 280))
        XCTAssertEqual(tracker.label, "27 new lines")
    }

    func testScrollingDownReadsSomeOfThem() {
        var tracker = LiveScrollTracker()
        tracker.update(scroll(0, 100))
        tracker.update(scroll(40, 100))
        tracker.update(scroll(70, 130))
        XCTAssertEqual(tracker.newLines, 30)
        tracker.update(scroll(10, 130))
        XCTAssertEqual(tracker.newLines, 10)
        tracker.update(scroll(1, 130))
        XCTAssertEqual(tracker.label, "1 new line")
    }

    func testReachingTheBottomClearsTheCountAndLeavingAgainStartsFresh() {
        var tracker = LiveScrollTracker()
        tracker.update(scroll(0, 100))
        tracker.update(scroll(40, 100))
        tracker.update(scroll(60, 120))
        tracker.update(scroll(0, 120))
        XCTAssertTrue(tracker.isLive)
        XCTAssertEqual(tracker.newLines, 0)
        tracker.update(scroll(5, 120))
        XCTAssertEqual(tracker.newLines, 0)
    }

    func testAFirstReportAlreadyScrolledBackShowsThePillWithoutACount() {
        var tracker = LiveScrollTracker()
        tracker.update(scroll(30, 300))
        XCTAssertFalse(tracker.isLive)
        XCTAssertEqual(tracker.newLines, 0)
    }

    func testReadsTheSessionServersScrollEvent() throws {
        let line = #"{"data":{"pane_id":"w4:p2","scroll":{"max_offset_from_bottom":285,"offset_from_bottom":16,"viewport_rows":51},"workspace_id":"w4"},"event":"pane.scroll_changed"}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let event = try XCTUnwrap(PaneScroll.parseEvent(object))
        XCTAssertEqual(event.paneId, "w4:p2")
        XCTAssertEqual(event.scroll, PaneScroll(offsetFromBottom: 16, maxOffsetFromBottom: 285, viewportRows: 51))
        XCTAssertNil(PaneScroll.parseEvent(["event": "pane.updated", "data": ["pane_id": "w4:p2"]]))
    }

    func testSnapshotLayoutsGivePaneFrames() throws {
        let json = #"""
        {"workspaces":[],"tabs":[],"panes":[],"agents":[],
         "layouts":[{"workspace_id":"w4","tab_id":"w4:t1","zoomed":false,
           "area":{"x":0,"y":0,"width":155,"height":51},"focused_pane_id":"w4:p1",
           "panes":[{"pane_id":"w4:p1","focused":true,"rect":{"x":0,"y":0,"width":78,"height":51}},
                    {"pane_id":"w4:p2","focused":false,"rect":{"x":78,"y":0,"width":77,"height":51}}],
           "splits":[]}]}
        """#
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: Data(json.utf8))
        let layout = try XCTUnwrap(snapshot.layouts.first)
        XCTAssertEqual(layout.tabId, "w4:t1")
        let frame = try XCTUnwrap(layout.frame(ofPane: "w4:p2", in: CGSize(width: 1550, height: 510)))
        XCTAssertEqual(frame, CGRect(x: 780, y: 0, width: 770, height: 510))
        XCTAssertNil(layout.frame(ofPane: "gone", in: CGSize(width: 10, height: 10)))
    }

    func testAnUnreadableLayoutDoesntCostTheSnapshot() throws {
        let json = #"{"workspaces":[],"tabs":[],"panes":[],"agents":[],"layouts":[{"nonsense":true}],"focused_pane_id":"w1:p1"}"#
        let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.layouts, [])
        XCTAssertEqual(snapshot.focusedPaneId, "w1:p1")
    }

    func testClosedTabsKeepOnlyVisibleLayouts() {
        let holding = EngineWorkspace(workspaceId: "w9", number: 9, label: ClosedTabs.workspaceLabel, focused: false,
                                      paneCount: 1, tabCount: 1, activeTabId: "w9:t1", agentStatus: .idle, worktree: nil)
        let tab = { (id: String, ws: String) in
            EngineTab(tabId: id, workspaceId: ws, number: 1, label: "1", focused: false, paneCount: 1, agentStatus: .idle)
        }
        let rect = EngineLayout.Rect(x: 0, y: 0, width: 10, height: 10)
        let snapshot = EngineSnapshot(workspaces: [holding], tabs: [tab("w1:t1", "w1"), tab("w9:t1", "w9")], panes: [],
                                      agents: [], focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil,
                                      layouts: [EngineLayout(tabId: "w1:t1", area: rect, panes: []),
                                                EngineLayout(tabId: "w9:t1", area: rect, panes: [])])
        XCTAssertEqual(ClosedTabs.visible(snapshot).layouts.map(\.tabId), ["w1:t1"])
    }
}
