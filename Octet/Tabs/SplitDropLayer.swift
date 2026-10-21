import AppKit
import SwiftUI

/// What's being dragged, while it is: a tab, a workspace card, a pane by
/// its handle, or one of Octet's own tabs. `DragSource` says how the drag
/// ended, so nothing here guesses from the mouse button.
///
/// Let go outside every Octet window, a tab, a pane or a workspace gets a
/// window of its own, the preview of which follows the cursor out there:
/// how a browser tab is torn off. Escape, or ⌘Tab away, cancels instead.
@MainActor
final class TabDrag: ObservableObject {
    static let shared = TabDrag()

    enum Item: Equatable {
        case tab(String)
        case workspace(String)
        case pane(String)
        /// A conversation, editor or container-log tab, by its strip id.
        case stripTab(String)
    }

    @Published private(set) var item: Item?
    private weak var store: SessionStore?
    private weak var source: WindowContext?
    /// The window the drag started in.
    var sourceWindow: WindowContext? { source }
    private var spring: (target: String, timer: Timer)?
    /// Whether a release out of every window makes it a window of its own.
    private var tearable = false

    var tabId: String? { if case .tab(let id) = item { id } else { nil } }
    /// A workspace being dragged instead of a tab, which the tab bars and
    /// split zones don't take.
    var workspaceId: String? { if case .workspace(let id) = item { id } else { nil } }
    var paneId: String? { if case .pane(let id) = item { id } else { nil } }
    var stripTabId: String? { if case .stripTab(let id) = item { id } else { nil } }
    /// What the strip calls the dragged tab, for the gap it's dropped in.
    var stripId: String? {
        switch item {
        case .tab(let id): TabStripOrder.terminalPrefix + id
        case .stripTab(let id): id
        default: nil
        }
    }

    /// A terminal tab dragged from `window`'s strip.
    func begin(_ tabId: String, store: SessionStore, from window: WindowContext?) {
        start(.tab(tabId), store: store, source: window)
        // Only a tab that can move whole gets a window of its own.
        tearable = store.onlyPane(ofTab: tabId) != nil
        if tearable, let tab = store.snapshot.tabs.first(where: { $0.tabId == tabId }) {
            let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tabId))?.agent
            TearOffPreview.shared.prepare(title: TabAutoName.display(label: tab.label, number: tab.number),
                                          agent: agent, size: windowSize)
        }
    }

    /// A workspace card dragged from `window`'s sidebar.
    func begin(workspace workspaceId: String, from window: WindowContext) {
        let store = window.store
        start(.workspace(workspaceId), store: store, source: window)
        tearable = store.snapshot.workspaces.contains { $0.workspaceId == workspaceId }
        if tearable, let workspace = store.snapshot.workspaces.first(where: { $0.workspaceId == workspaceId }) {
            let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspaceId))?.agent
            TearOffPreview.shared.prepare(title: workspace.label, agent: agent, size: windowSize)
        }
    }

    /// A pane dragged by its handle, out of a split.
    func begin(pane paneId: String, from window: WindowContext) {
        let store = window.store
        start(.pane(paneId), store: store, source: window)
        tearable = store.snapshot.panes.contains { $0.paneId == paneId }
        if tearable, let pane = store.snapshot.panes.first(where: { $0.paneId == paneId }) {
            let agent = store.snapshot.agents.first { $0.paneId == paneId }?.agent
            let tab = store.snapshot.tabs.first { $0.tabId == pane.tabId }
            TearOffPreview.shared.prepare(title: tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal",
                                          agent: agent, size: windowSize)
        }
    }

    /// A conversation, editor or log tab: it moves along the strip and
    /// beside the terminal, but stays in its window.
    func begin(stripTab id: String, from window: WindowContext) {
        start(.stripTab(id), store: window.store, source: window)
        tearable = false
    }

    private func start(_ item: Item, store: SessionStore, source: WindowContext?) {
        self.item = item
        self.store = store
        self.source = source
    }

    private var windowSize: CGSize {
        source?.nsWindow?.frame.size ?? NSApp.keyWindow?.frame.size ?? CGSize(width: 1280, height: 820)
    }

    /// Held over `target` for `delay`, `action` runs once, as Finder's
    /// spring-loaded folders open: how a dragged pane brings a tab forward
    /// to be split into. Nil, or another target, starts over.
    func springLoad(_ target: String?, after delay: TimeInterval = 0, action: @escaping () -> Void = {}) {
        guard spring?.target != target else { return }
        spring?.timer.invalidate()
        spring = nil
        guard let target else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard TabDrag.shared.item != nil else { return }
                action()
            }
        }
        // `.common` includes the event-tracking mode a drag runs the loop in.
        RunLoop.main.add(timer, forMode: .common)
        spring = (target, timer)
    }

    /// The pointer moved, on screen: the preview follows it outside Octet.
    func moved(to point: CGPoint) {
        if tearable, !overWindow(point) { TearOffPreview.shared.follow(point) } else { TearOffPreview.shared.hide() }
    }

    /// The drag is over: dropped on a target, cancelled, or let go somewhere
    /// nothing took it, which tears it off when that's outside every window.
    func ended(_ end: DragEnd) {
        let item = self.item
        let store = self.store, source = self.source
        self.item = nil
        self.source = nil
        springLoad(nil)
        guard case .released(let point) = end, let item, let store, tearable, !overWindow(point) else {
            return TearOffPreview.shared.hide()
        }
        let landing = TearOffPreview.shared.target ?? WindowActions.tearOffFrame(at: point, size: windowSize)
        switch item {
        case .tab(let tabId):
            TearOffPreview.shared.land(in: landing)
            WindowActions.tearOff(tabId: tabId, store: store, frame: landing)
        case .workspace(let workspaceId):
            guard let source else { return TearOffPreview.shared.hide() }
            TearOffPreview.shared.land(in: landing)
            WindowActions.moveWorkspaceToNewWindow(workspaceId, from: source, frame: landing)
        case .pane(let paneId):
            TearOffPreview.shared.land(in: landing)
            WindowActions.tearOff(paneId: paneId, store: store, frame: landing)
        case .stripTab:
            TearOffPreview.shared.hide()
        }
    }

    /// The windows on screen, front to back, read at most ten times a
    /// second however often the pointer moves.
    private var windows: (at: Date, list: [[String: Any]])?

    private func windowList() -> [[String: Any]] {
        if let windows, Date().timeIntervalSince(windows.at) < 0.1 { return windows.list }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = (Date(), list)
        return list
    }

    /// How far past a window's edge a release still counts as over it: a
    /// drop aimed at the edge zone that overshoots by a little keeps the tab
    /// in that window, rather than opening another.
    static let edgeGrace: CGFloat = 48

    /// Whether `point` (screen, origin bottom left) is over one of Octet's
    /// windows, which takes the drop itself. The window under the point is
    /// the front one there, whichever app it's from: an Octet window behind
    /// another app's, or on another Space, doesn't count, and nor do the
    /// Notch, popovers and panels, which sit above the normal window level.
    private func overWindow(_ point: CGPoint) -> Bool {
        let ours = WindowRegistry.shared.windows.compactMap(\.nsWindow).filter { $0.isVisible && $0.isOnActiveSpace }
        let numbers = Set(ours.map(\.windowNumber))
        let preview = TearOffPreview.shared.window?.windowNumber
        // The common case, answered by the window server for this one point:
        // the window under it, skipping the preview, is one of ours. The full
        // list below is only for what that can't settle (a panel or another
        // app's window there), and it is the costly part of every pointer move.
        let top = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: preview ?? 0)
        if numbers.contains(top) { return true }
        // Window bounds come with the origin at the top left of the main display.
        let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        for info in windowList() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int, number != preview,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.contains(flipped) else { continue }
            return numbers.contains(number)
        }
        // Nothing there but the desktop: close by an Octet window still counts.
        return ours.contains { $0.frame.insetBy(dx: -Self.edgeGrace, dy: -Self.edgeGrace).contains(point) }
    }
}

/// Drop zones over the terminal while a tab is dragged: hovering near a
/// pane's edge shows the half the tab would take, and dropping splits it in
/// there. A tab from another window dropped mid-pane joins as a tab. The
/// way editors take a dragged tab into a new group, and how iTerm and Warp
/// build splits by drag.
struct SplitDropLayer: View {
    /// The panes of the tab showing; nil until known.
    let layout: PaneLayout?
    /// Where the terminal draws them.
    var cells: CellGeometry?
    /// The dragged tab is from another window, so the middle takes it as a tab.
    var acceptsTab = false
    /// What a drop does, for the zone's label.
    var action: SplitAction = .split
    /// A pane dragged by its handle, rather than a tab.
    var moving: String?
    /// Whether a band along the whole tab's edge splits beside everything.
    var wholeTab = false
    let animation: Animation?
    let drop: (SplitTarget) -> Void
    @State private var target: SplitTarget?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Catches the drag over the whole terminal. Present only while
                // a tab is dragged, so it never takes an ordinary click.
                Color.clear.contentShape(Rectangle())
                if let target {
                    zone(target)
                        .transition(.opacity)
                }
            }
            .animation(animation, value: target)
            .onDrop(of: OctetDragKind.layout, delegate: SplitDropDelegate(
                size: proxy.size, layout: layout, cells: cells, acceptsTab: acceptsTab, action: action,
                moving: moving, wholeTab: wholeTab, target: $target, drop: drop))
        }
    }

    private func zone(_ target: SplitTarget) -> some View {
        DropZone(title: target.title, rect: target.highlight)
    }
}

private struct SplitDropDelegate: DropDelegate {
    let size: CGSize
    let layout: PaneLayout?
    let cells: CellGeometry?
    let acceptsTab: Bool
    let action: SplitAction
    let moving: String?
    let wholeTab: Bool
    @Binding var target: SplitTarget?
    let drop: (SplitTarget) -> Void

    // Taken even before the layout is known, so the drop never falls
    // through to the terminal underneath.
    func validateDrop(info: DropInfo) -> Bool { true }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // pane.layout is asynchronous: until it arrives the whole view counts
        // as one pane, so the outer split zones work as soon as the drag
        // reaches the terminal.
        let fallback = PaneLayout(area: CGRect(origin: .zero, size: size),
                                  panes: [.init(id: "", rect: CGRect(origin: .zero, size: size))])
        let found = SplitDrop.target(at: info.location, in: size, layout: layout ?? fallback, acceptsTab: acceptsTab,
                                     cells: layout == nil ? nil : cells, moving: moving, action: action, wholeTab: wholeTab)
        // Only a change redraws the zone: the pointer moves many times a frame.
        if found != target { target = found }
        // Mid-pane, or a move that changes nothing: the cursor says so.
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let target else { return false }
        drop(target)
        self.target = nil
        return true
    }
}

/// Drop zones over a workspace while another workspace card is dragged.
/// An edge adds an independent workspace surface with its own tab strip.
struct WorkspaceDropLayer: View {
    let workspaceId: String
    let window: WindowContext
    let animation: Animation?
    @State private var target: WorkspaceDropTarget?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let target {
                    zone(target, in: proxy.size)
                        .transition(.opacity)
                }
            }
            .animation(animation, value: target)
            .onDrop(of: [OctetDragKind.workspace.type], delegate: WorkspaceDropDelegate(size: proxy.size, showsIt: showsIt, splits: !showsIt,
                                                                 target: $target) { target in
                switch target {
                case .here: window.focusWorkspace(workspaceId)
                case .beside(let edge): split(edge)
                }
            })
        }
    }

    /// A workspace owns its own tabs, so an edge drop gives it an independent
    /// client and tab strip in the same window. No pane changes workspaces.
    private func split(_ edge: SplitEdge) {
        // A workspace owns its own tabs, so an edge drop gives it an independent
        // client and tab strip in the same window.
        window.splitWorkspace(workspaceId, at: edge)
    }

    /// Whether an edge drop opens a fresh shell: never, a workspace is shown
    /// as it is.
    private var opensShell: Bool { false }

    /// Dropped on the window already showing it, the middle has nothing to do.
    private var showsIt: Bool { window.focusedWorkspace?.workspaceId == workspaceId }

    private var label: String { window.store.snapshot.workspaces.first { $0.workspaceId == workspaceId }?.label ?? "" }

    private func zone(_ target: WorkspaceDropTarget, in size: CGSize) -> some View {
        DropZone(title: target.title(workspace: label, ownTab: opensShell), rect: target.highlight(in: size))
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    let size: CGSize
    let showsIt: Bool
    /// Whether an edge can take a different workspace.
    let splits: Bool
    @Binding var target: WorkspaceDropTarget?
    let drop: (WorkspaceDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        var found = WorkspaceDropTarget.at(info.location, in: size)
        if !splits, found != nil { found = .here }
        let next = showsIt && found == .here ? nil : found
        if next != target { target = next }
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let target else { return true }
        self.target = nil
        drop(target)
        return true
    }
}
