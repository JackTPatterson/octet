import AppKit
import SwiftUI

/// The tab being dragged, while it is. SwiftUI says when a drag starts
/// (`onDrag`) but not when it ends somewhere that isn't a drop target, so
/// this watches the mouse button and clears itself once it's let go.
///
/// Dragged outside every Octet window, a preview of the window it would make
/// follows the cursor; let go there and the tab gets that window: how a
/// browser tab is torn off.
@MainActor
final class TabDrag: ObservableObject {
    static let shared = TabDrag()
    @Published private(set) var tabId: String?
    private weak var store: SessionStore?
    /// A tab bar or a split zone took the drop.
    private var didLand = false
    private var watch: Timer?

    func begin(_ tabId: String, store: SessionStore) {
        self.tabId = tabId
        self.store = store
        didLand = false
        // Only a tab that can move whole gets a window of its own.
        tearable = store.onlyPane(ofTab: tabId) != nil
        if tearable, let tab = store.snapshot.tabs.first(where: { $0.tabId == tabId }) {
            let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tabId))?.agent
            let size = NSApp.keyWindow?.frame.size ?? CGSize(width: 1280, height: 820)
            TearOffPreview.shared.prepare(title: TabAutoName.display(label: tab.label, number: tab.number),
                                          agent: agent, size: size)
        }
        watch?.invalidate()
        // Every frame, so the preview keeps up with the cursor.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { TabDrag.shared.tick() }
        }
        // `.common` includes the event-tracking mode a drag runs the loop in.
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private var tearable = false

    /// A drop target took the tab.
    func landed() { didLand = true }

    /// Whether `point` is over an Octet window, which takes the drop itself.
    private func overWindow(_ point: CGPoint) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0 !== TearOffPreview.shared.window && $0.frame.contains(point) }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            if tearable, !overWindow(point) { TearOffPreview.shared.follow(point) } else { TearOffPreview.shared.hide() }
            return
        }
        watch?.invalidate()
        watch = nil
        let dragged = tabId
        let frame = TearOffPreview.shared.target
        // A drop is handled on release too; let it land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let drag = TabDrag.shared
            defer { drag.tabId = nil }
            guard let dragged, !drag.didLand, let store = drag.store, !drag.overWindow(point) else {
                return TearOffPreview.shared.hide()
            }
            // A split tab can't go whole; tearOff says why.
            guard drag.tearable else { return WindowActions.tearOff(tabId: dragged, store: store, frame: nil) }
            let landing = frame ?? WindowActions.tearOffFrame(at: point, size: NSApp.keyWindow?.frame.size ?? CGSize(width: 1280, height: 820))
            TearOffPreview.shared.land(in: landing)
            WindowActions.tearOff(tabId: dragged, store: store, frame: landing)
        }
    }
}

/// Drop zones over the terminal while a tab is dragged: hovering near a
/// pane's edge shows the half the tab would take, and dropping splits it in
/// there. A tab from another window dropped mid-pane joins as a tab. The
/// way editors take a dragged tab into a new group, and how iTerm and Warp
/// build splits by drag.
struct SplitDropLayer: View {
    /// The panes of the tab showing; nil until fetched.
    let layout: PaneLayout?
    /// The dragged tab is from another window, so the middle takes it as a tab.
    let acceptsTab: Bool
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
            .onDrop(of: [.text], delegate: SplitDropDelegate(size: proxy.size, layout: layout, acceptsTab: acceptsTab, target: $target, drop: drop))
        }
    }

    private func zone(_ target: SplitTarget) -> some View {
        let inset: CGFloat = 6
        return RoundedRectangle(cornerRadius: 8)
            .fill(Theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
            .overlay {
                Text(target.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.chrome)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }
            .frame(width: max(0, target.highlight.width - inset * 2), height: max(0, target.highlight.height - inset * 2))
            .offset(x: target.highlight.minX + inset, y: target.highlight.minY + inset)
            .allowsHitTesting(false)
            .accessibilityLabel(target.title)
    }
}

private struct SplitDropDelegate: DropDelegate {
    let size: CGSize
    let layout: PaneLayout?
    let acceptsTab: Bool
    @Binding var target: SplitTarget?
    let drop: (SplitTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool { layout != nil && info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = layout.flatMap { SplitDrop.target(at: info.location, in: size, layout: $0, acceptsTab: acceptsTab) }
        // Mid-pane in the tab's own window: nothing to do, and the cursor says so.
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let target else { return false }
        TabDrag.shared.landed()
        drop(target)
        self.target = nil
        return true
    }
}
