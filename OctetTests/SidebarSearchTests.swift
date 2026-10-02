import XCTest

final class SidebarSearchTests: XCTestCase {
    private let snapshot = EngineSnapshot(
        workspaces: [EngineWorkspace(workspaceId: "w1", number: 1, label: "Checkout", focused: true, paneCount: 1,
                                     tabCount: 1, activeTabId: "w1:t1", agentStatus: .working,
                                     worktree: EngineWorktree(repoRoot: "/r/shop", branch: "fix-retry", path: "/r/shop-fix"))],
        tabs: [EngineTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: "dev server", focused: true,
                         paneCount: 1, agentStatus: .working)],
        panes: [EnginePane(paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1", focused: true, cwd: "/Users/me/Developer/shop",
                           foregroundCwd: nil, agentStatus: .working, terminalTitle: "vite")],
        agents: [EngineAgent(paneId: "w1:p1", tabId: "w1:t1", workspaceId: "w1", agent: "codex", name: nil,
                             displayAgent: nil, agentStatus: .working)],
        focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: "w1:p1"
    )

    private func finds(_ query: String) -> Bool {
        let fields = SidebarSearch.fields(of: snapshot.workspaces[0], in: snapshot, group: "shop", branch: "fix-retry",
                                          extra: ["Refactor the cart"])
        return SidebarSearch.matches(query, fields: fields)
    }

    func testAWorkspaceIsFoundByWhatItShowsOrRuns() {
        XCTAssertTrue(finds("checkout"))   // its name
        XCTAssertTrue(finds("RETRY"))      // its branch, any case
        XCTAssertTrue(finds("dev server")) // a tab
        XCTAssertTrue(finds("Developer/shop"))
        XCTAssertTrue(finds("vite"))       // a pane's title
        XCTAssertTrue(finds("codex"))      // the agent in it
        XCTAssertTrue(finds("cart"))       // a conversation's title
        XCTAssertTrue(finds(""))
    }

    func testEveryWordMustBeFoundSomewhere() {
        XCTAssertTrue(finds("shop codex"))
        XCTAssertFalse(finds("shop claude"))
        XCTAssertFalse(finds("nothing"))
    }

    func testAccentsDontMatter() {
        XCTAssertTrue(SidebarSearch.matches("cafe", fields: ["Café menu"]))
    }
}
