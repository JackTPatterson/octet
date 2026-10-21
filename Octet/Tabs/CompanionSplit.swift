import AppKit
import SwiftUI

/// The terminal with one of Octet's own tabs beside it, on `edge`, split by
/// a divider that drags to resize and double-clicks back to halves. Escape,
/// or Octet going to the background, puts a drag back where it started.
///
/// Always the same three views in the same order (terminal, divider, the
/// tab beside it), placed by a layout, so the terminal keeps its identity
/// as a tab comes beside it, goes, or moves to another side: rebuilt, its
/// surface would start a new engine client and lose focus.
struct CompanionSplit<Terminal: View, Companion: View>: View {
    /// Nil: the terminal alone.
    let edge: SplitEdge?
    /// The companion's share of the space.
    let share: CGFloat
    let setShare: (CGFloat) -> Void
    /// Where the terminal now starts in the split, for what's drawn over it
    /// from outside: a companion on the left or above pushes it along.
    var terminalMoved: (CGSize) -> Void = { _ in }
    @ViewBuilder let terminal: Terminal
    @ViewBuilder let companion: Companion
    /// The share while the divider is dragged, committed once let go.
    @State private var live: CGFloat?
    @State private var dragging = false
    @State private var hovering = false

    private var horizontal: Bool { edge == nil || edge == .left || edge == .right }
    private var companionFirst: Bool { edge == .left || edge == .top }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let length = edge == nil ? 0 : max(0, (total * (live ?? share)).rounded())
            CompanionLayout(edge: edge, length: length) {
                terminal
                Group {
                    if edge != nil { divider(total: total) } else { Color.clear }
                }
                companion.clipped()
            }
            .coordinateSpace(name: Self.space)
            .onChange(of: terminalOffset(length), initial: true) { _, offset in terminalMoved(offset) }
        }
        .onDisappear {
            terminalMoved(.zero)
            if hovering { NSCursor.pop() }
        }
    }

    private static var space: String { "companion-split" }

    private func terminalOffset(_ length: CGFloat) -> CGSize {
        guard companionFirst else { return .zero }
        return horizontal ? CGSize(width: length + 1, height: 0) : CGSize(width: 0, height: length + 1)
    }

    private func divider(total: CGFloat) -> some View {
        let cursor: NSCursor = horizontal ? .resizeLeftRight : .resizeUpDown
        return Rectangle()
            .fill(Theme.divider)
            // A wider grip than the line, as Warp's and Orca's.
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        inside ? cursor.push() : NSCursor.pop()
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            if !dragging {
                                dragging = true
                                ResizeCancel.shared.begin { live = nil }
                            }
                            guard ResizeCancel.shared.isLive else { return }
                            cursor.set()
                            let at = horizontal ? value.location.x : value.location.y
                            let fraction = total > 0 ? at / total : 0.5
                            live = min(0.85, max(0.15, companionFirst ? fraction : 1 - fraction))
                        }
                        .onEnded { _ in
                            dragging = false
                            if ResizeCancel.shared.isLive, let live { setShare(live) }
                            ResizeCancel.shared.end()
                            live = nil
                        })
                    .onTapGesture(count: 2) { setShare(0.5) }
                    .accessibilityElement()
                    .accessibilityLabel("Split divider")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = direction == .increment ? 0.05 : -0.05
                        setShare(share + step)
                    }
            }
            .onDisappear {
                if dragging { ResizeCancel.shared.end() }
                dragging = false
                live = nil
            }
    }
}

/// Places the terminal, the divider and the tab beside it: the tab takes
/// `length` on `edge`'s side, the divider a point, the terminal the rest.
private struct CompanionLayout: Layout {
    let edge: SplitEdge?
    let length: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        func put(_ index: Int, _ rect: CGRect) {
            subviews[index].place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
        guard let edge, length > 0 else {
            put(0, bounds)
            put(1, CGRect(origin: bounds.origin, size: .zero))
            put(2, CGRect(origin: bounds.origin, size: .zero))
            return
        }
        let x = bounds.minX, y = bounds.minY, w = bounds.width, h = bounds.height
        let rest = max(0, (edge == .left || edge == .right ? w : h) - length - 1)
        switch edge {
        case .left:
            put(2, CGRect(x: x, y: y, width: length, height: h))
            put(1, CGRect(x: x + length, y: y, width: 1, height: h))
            put(0, CGRect(x: x + length + 1, y: y, width: rest, height: h))
        case .right:
            put(0, CGRect(x: x, y: y, width: rest, height: h))
            put(1, CGRect(x: x + rest, y: y, width: 1, height: h))
            put(2, CGRect(x: x + rest + 1, y: y, width: length, height: h))
        case .top:
            put(2, CGRect(x: x, y: y, width: w, height: length))
            put(1, CGRect(x: x, y: y + length, width: w, height: 1))
            put(0, CGRect(x: x, y: y + length + 1, width: w, height: rest))
        case .bottom:
            put(0, CGRect(x: x, y: y, width: w, height: rest))
            put(1, CGRect(x: x, y: y + rest, width: w, height: 1))
            put(2, CGRect(x: x, y: y + rest + 1, width: w, height: length))
        }
    }
}

/// Escape, or Octet going to the background, during a pointer drag of
/// Octet's own (a divider, a panel's edge): the drag is put back. One at a
/// time, as there's one pointer.
@MainActor
final class ResizeCancel {
    static let shared = ResizeCancel()
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var cancel: (() -> Void)?
    /// Set once cancelled, until the drag's gesture ends: what it reports
    /// after that is ignored.
    private(set) var cancelled = false

    func begin(onCancel: @escaping () -> Void) {
        end()
        cancelled = false
        cancel = onCancel
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.cancel != nil else { return event }
            self.fire()
            return nil
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ResizeCancel.shared.fire() }
        }
    }

    private func fire() {
        cancelled = true
        let cancel = self.cancel
        self.cancel = nil
        cancel?()
    }

    /// Whether the drag in progress may still change anything.
    var isLive: Bool { !cancelled }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
        cancel = nil
    }
}

/// Zones by the edges of the view while one of Octet's own tabs is dragged
/// over the terminal, or a terminal tab over one of them: dropped by an
/// edge, the two show side by side.
struct CompanionDropLayer: View {
    /// The zone's label for an edge.
    let title: (SplitEdge) -> String
    let animation: Animation?
    let drop: (SplitEdge) -> Void
    @State private var edge: SplitEdge?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let edge {
                    DropZone(title: title(edge), rect: WorkspaceDropTarget.beside(edge).highlight(in: proxy.size))
                        .transition(.opacity)
                }
            }
            .animation(animation, value: edge)
            .onDrop(of: OctetDragKind.layout, delegate: CompanionDropDelegate(size: proxy.size, edge: $edge, drop: drop))
        }
    }
}

private struct CompanionDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var edge: SplitEdge?
    let drop: (SplitEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        var found: SplitEdge?
        if case .beside(let side) = WorkspaceDropTarget.at(info.location, in: size) { found = side }
        if found != edge { edge = found }
        return DropProposal(operation: edge == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let edge else { return false }
        self.edge = nil
        drop(edge)
        return true
    }
}

/// The lit part of the view a drop would take, with what it does.
struct DropZone: View {
    let title: String
    let rect: CGRect
    var inset: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .fill(Theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5))
            .overlay {
                Text(title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.chrome)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }
            .frame(width: max(0, rect.width - inset * 2), height: max(0, rect.height - inset * 2))
            .offset(x: rect.minX + inset, y: rect.minY + inset)
            .allowsHitTesting(false)
            .accessibilityLabel(title)
    }
}
