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

    /// A pane, dragged out of its split by its handle, into a window of its
    /// own: the same move as a tab torn off, one pane at a time.
    static func tearOff(paneId: String, store: SessionStore, frame: CGRect?) {
        guard let pane = store.snapshot.panes.first(where: { $0.paneId == paneId }) else { return }
        let tab = store.snapshot.tabs.first { $0.tabId == pane.tabId }
        var destination: [String: Any] = ["type": "new_workspace"]
        if let tab {
            let label = TabAutoName.display(label: tab.label, number: tab.number)
            destination["label"] = label
        }
        store.call("pane.move", ["pane_id": paneId, "destination": destination, "focus": false],
                   failure: "Couldn't move the pane to a new window") { created in
            guard let workspace = created.workspaceId else { return }
            WindowOpener.open?(OctetWindowSpec(workspaceId: workspace, frame: frame))
        }
    }

    /// A pane dragged out of its split onto `window`'s strip: a tab of its
    /// own in that window's workspace, in the gap it was dropped in.
    static func movePane(_ paneId: String, toNewTabIn window: WindowContext, atStripGap gap: Int?) {
        guard let target = window.focusedWorkspace?.workspaceId else { return }
        window.store.call("pane.move", ["pane_id": paneId, "destination": ["type": "new_tab", "workspace_id": target], "focus": false],
                          failure: "Couldn't move the pane to a new tab") { created in
            guard let moved = created.tabId else { return }
            guard let gap else { return window.focusTab(moved) }
            window.placeArrivedTab(moved, atGap: gap) { window.focusTab(moved) }
        }
    }

    /// Keep a dragged tab in Octet but give its running pane a workspace and
    /// tab list of its own. The pane moves without restarting its process.
    static func tabToWorkspace(_ tabId: String, in window: WindowContext) {
        let store = window.store
        guard let pane = store.onlyPane(ofTab: tabId) else {
            ToastCenter.shared.info("A split tab can't move as one workspace yet",
                                    detail: "Move its panes into separate tabs first.")
            return
        }
        let tab = store.snapshot.tabs.first { $0.tabId == tabId }
        let label = tab.map { TabAutoName.display(label: $0.label, number: $0.number) }
        var destination: [String: Any] = ["type": "new_workspace"]
        if let label { destination["label"] = label; destination["tab_label"] = label }
        store.call("pane.move", ["pane_id": pane.paneId, "destination": destination, "focus": false],
                   failure: "Couldn't move the tab to a workspace") { created in
            guard let workspaceId = created.workspaceId else { return }
            window.focusWorkspace(workspaceId)
        }
    }

    /// A tab dropped on a split zone moves into another tab group in the same
    /// workspace. Its engine tab and every pane keep their identity.
    static func splitTab(_ tabId: String, beside window: WindowContext, at edge: SplitEdge) {
        let store = window.store
        guard let tab = store.snapshot.tabs.first(where: { $0.tabId == tabId }),
              let targetWorkspace = window.focusedWorkspace?.workspaceId else { return }
        let owner = window.splitParent ?? window
        if tab.workspaceId == targetWorkspace {
            // A group cannot be left without a tab. Make a replacement shell
            // first, then move the original tab as a whole into the new group.
            if owner.focusedWorkspaceTabs.count == 1,
               owner.focusedWorkspaceTabs.first?.tabId == tabId {
                let cwd = store.snapshot.directory(ofWorkspace: targetWorkspace) ?? NSHomeDirectory()
                store.call("tab.create", ["workspace_id": targetWorkspace, "cwd": cwd, "focus": false],
                           failure: "Couldn't create the split") { created in
                    guard created.tabId != nil else { return }
                    owner.splitTabGroup(tabId, at: edge)
                }
            } else {
                owner.splitTabGroup(tabId, at: edge)
            }
            return
        }
        guard let pane = store.onlyPane(ofTab: tabId) else {
            ToastCenter.shared.info("A tab with multiple panes can't move between workspaces yet",
                                    detail: "Move its panes into separate tabs first.")
            return
        }
        let destination: [String: Any] = ["type": "new_tab", "workspace_id": targetWorkspace]
        store.call("pane.move", ["pane_id": pane.paneId, "destination": destination, "focus": false],
                   failure: "Couldn't create the split") { created in
            guard let movedTab = created.tabId else { return }
            owner.splitTabGroup(movedTab, at: edge)
        }
    }

    /// A workspace into a window of its own, at `frame` when it was dropped
    /// somewhere, else cascaded from `window`. Nothing moves in the engine: the
    /// new window shows the workspace and it becomes that window's alone,
    /// out of `window`'s sidebar; `window` moves to its neighbour, and keeps
    /// its other workspaces and everything running in them.
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
        // The window keeps its other workspaces; with none, there'd be
        // nothing left for it to show.
        if !window.ownWorkspaces.contains(where: { $0.workspaceId != workspaceId }) {
            ToastCenter.shared.info("This window has no other workspace to show",
                                    detail: "Open another workspace here first, or use New Window (⌥⌘N).")
            return false
        }
        WindowOpener.open?(OctetWindowSpec(workspaceId: workspaceId, frame: frame ?? cascaded(from: window)))
        return true
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
        // Closed outright, as the close button does: `performClose` from here
        // can leave the window ordered out rather than closed, a hidden window
        // the next one opened gets lost in.
        for window in registry.windows where window !== keep && !window.isEmbeddedSplit {
            window.mergingAway = true
            window.closing = true
            window.nsWindow?.close()
        }
    }

    /// A tab dragged from one window's tab bar into another's: into that
    /// window's workspace, at the gap of its strip it was dropped in (the
    /// end when nil).
    static func moveTab(_ tabId: String, into window: WindowContext, atStripGap gap: Int?) {
        let store = window.store
        guard let target = window.focusedWorkspace?.workspaceId,
              let tab = store.snapshot.tabs.first(where: { $0.tabId == tabId }) else { return }
        guard tab.workspaceId != target else {
            window.acceptTabIntoGroup(tabId)
            guard let gap else { return store.moveTab(tabId, toGap: store.snapshot.tabs(inWorkspace: target).count) }
            return window.moveVisualTab(TabStripOrder.terminalPrefix + tabId, toGap: gap)
        }
        guard let pane = store.onlyPane(ofTab: tabId) else {
            ToastCenter.shared.info("A split tab can't move between windows yet",
                                    detail: "Move its panes out first (Pane › Move Pane to New Tab).")
            return
        }
        // The tab arrives last; from there it goes to the gap it was dropped in.
        store.call("pane.move", ["pane_id": pane.paneId, "destination": ["type": "new_tab", "workspace_id": target], "focus": false],
                   failure: "Couldn't move the tab") { created in
            guard let moved = created.tabId else { return }
            let arrive = {
                window.acceptTabIntoGroup(moved)
                window.focusTab(moved)
                window.bringForward()
            }
            // Steered only once the order is final: the keys count positions.
            guard let gap else { return arrive() }
            window.placeArrivedTab(moved, atGap: gap, then: arrive)
        }
    }
}
