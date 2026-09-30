import AppKit

/// The window mechanics browsers, editors and terminals share, on Octet's
/// engine: dragging a tab or a workspace out makes a window, "Move Tab to New
/// Window" and "Move Workspace to New Window" do the same from the menu, and
/// "Merge All Windows" folds them back.
///
/// An Octet window shows one workspace, so a tab gets a window of its own by
/// moving into a workspace of its own, which the new window then shows. The
/// tab's process moves with it untouched: it's the same pane, somewhere else.
@MainActor
enum WindowActions {
    /// ⌥⌘N: a window with a new workspace, the way an editor's new window
    /// starts empty rather than showing what another already has.
    static func newWindow(store: SessionStore) {
        store.call("workspace.create", ["focus": false, "cwd": NSHomeDirectory()],
                   failure: "Couldn't open a new window") { created in
            guard let workspace = created.workspaceId else { return }
            WindowOpener.open?(OctetWindowSpec(workspaceId: workspace))
        }
    }

    /// Where a tab let go at `point` opens: the cursor on the new window's
    /// tab, as where it was held, and the whole window on that screen.
    static func tearOffFrame(at point: CGPoint, size: CGSize) -> CGRect {
        var frame = CGRect(x: point.x - 60, y: point.y - size.height + 20, width: size.width, height: size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    /// A tab into a window of its own, at `frame` when it was dropped
    /// somewhere, else cascaded from where it came from.
    static func tearOff(tabId: String, store: SessionStore, frame: CGRect?) {
        guard let pane = store.onlyPane(ofTab: tabId) else {
            // The engine moves panes one at a time; a split tab would arrive
            // as separate tabs, which isn't the tab you dragged.
            ToastCenter.shared.info("A split tab can't move to its own window yet",
                                    detail: "Move its panes out first (Pane › Move Pane to New Tab).")
            return
        }
        let tab = store.snapshot.tabs.first { $0.tabId == tabId }
        let label = tab.map { TabAutoName.display(label: $0.label, number: $0.number) }
        var destination: [String: Any] = ["type": "new_workspace"]
        if let label {
            destination["label"] = label
            destination["tab_label"] = label
        }
        store.call("pane.move", ["pane_id": pane.paneId, "destination": destination, "focus": false],
                   failure: "Couldn't move the tab to a new window") { created in
            guard let workspace = created.workspaceId else { return }
            WindowOpener.open?(OctetWindowSpec(workspaceId: workspace, frame: frame))
        }
    }

    /// A workspace into a window of its own, at `frame` when it was dropped
    /// somewhere, else cascaded from `window`. Nothing moves in the engine: the
    /// new window shows the workspace, and the window that showed it moves to
    /// its neighbour, since two windows never show the same workspace.
    /// Whether a window now shows it apart from `window`.
    @discardableResult
    static func moveWorkspaceToNewWindow(_ workspaceId: String, from window: WindowContext, frame: CGRect? = nil) -> Bool {
        let registry = WindowRegistry.shared
        // Already alone in a window: that's the one it has.
        if let other = registry.window(showing: workspaceId), other !== window {
            if let frame { other.nsWindow?.setFrame(frame, display: true, animate: true) }
            other.bringForward()
            return true
        }
        let store = window.store
        let showsIt = window.focusedWorkspace?.workspaceId == workspaceId
        let shownElsewhere = registry.shownWorkspaceIds(except: window)
        if showsIt, !store.snapshot.workspaces.contains(where: {
            $0.workspaceId != workspaceId && !shownElsewhere.contains($0.workspaceId)
        }) {
            ToastCenter.shared.info("This window has no other workspace to show",
                                    detail: "Open another workspace here first, or use New Window (⌥⌘N).")
            return false
        }
        WindowOpener.open?(OctetWindowSpec(workspaceId: workspaceId, frame: frame ?? cascaded(from: window)))
        return true
    }

    /// A workspace card dropped by an edge of `window`: the window splits in
    /// two, the workspace in a window on that side, the way a tab dropped by
    /// a pane's edge splits the pane.
    static func openBeside(_ workspaceId: String, from window: WindowContext, edge: SplitEdge) {
        guard let nsWindow = window.nsWindow else {
            moveWorkspaceToNewWindow(workspaceId, from: window)
            return
        }
        // A full-screen window can't share its space; the new one cascades.
        if nsWindow.styleMask.contains(.fullScreen) {
            moveWorkspaceToNewWindow(workspaceId, from: window)
            return
        }
        let halves = WorkspaceDropTarget.split(nsWindow.frame, at: edge)
        guard moveWorkspaceToNewWindow(workspaceId, from: window, frame: halves.new) else { return }
        nsWindow.setFrame(halves.kept, display: true, animate: true)
    }

    static func moveFocusedWorkspaceToNewWindow(from window: WindowContext) {
        guard let workspace = window.focusedWorkspace?.workspaceId else { return }
        moveWorkspaceToNewWindow(workspace, from: window)
    }

    static func moveFocusedTabToNewWindow(from window: WindowContext) {
        guard let tab = window.displayedFocusedTabId else { return }
        tearOff(tabId: tab, store: window.store, frame: cascaded(from: window))
    }

    /// Offset from the window it left, the way a browser cascades.
    static func cascaded(from window: WindowContext) -> CGRect? {
        window.nsWindow.map { $0.frame.offsetBy(dx: 28, dy: -28) }
    }

    /// Every other window closes. Nothing in them stops: their workspaces
    /// stay in the sidebar, where the window left can show them.
    static func mergeAllWindows() {
        let registry = WindowRegistry.shared
        guard let keep = registry.key else { return }
        for window in registry.windows where window !== keep { window.nsWindow?.performClose(nil) }
    }

    /// A tab dragged from one window's tab bar into another's: into that
    /// window's workspace, at the gap it was dropped in.
    static func moveTab(_ tabId: String, into window: WindowContext, at gap: Int) {
        let store = window.store
        guard let target = window.focusedWorkspace?.workspaceId,
              let tab = store.snapshot.tabs.first(where: { $0.tabId == tabId }) else { return }
        guard tab.workspaceId != target else { return store.moveTab(tabId, toGap: gap) }
        guard let pane = store.onlyPane(ofTab: tabId) else {
            ToastCenter.shared.info("A split tab can't move between windows yet",
                                    detail: "Move its panes out first (Pane › Move Pane to New Tab).")
            return
        }
        // The tab arrives last; from there it goes to the gap it was dropped in.
        let arrivedAt = store.snapshot.tabs(inWorkspace: target).count
        store.call("pane.move", ["pane_id": pane.paneId, "destination": ["type": "new_tab", "workspace_id": target], "focus": false],
                   failure: "Couldn't move the tab") { created in
            guard let moved = created.tabId else { return }
            // Steered only once the order is final: the keys count positions.
            let arrive = {
                window.focusTab(moved)
                window.bringForward()
            }
            guard gap < arrivedAt else { return arrive() }
            store.call("tab.move", ["tab_id": moved, "insert_index": gap], failure: "Couldn't move the tab") { _ in arrive() }
        }
    }
}
