import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What Octet drags between its own views. Each kind travels under a type of
/// Octet's own, never as text, so a terminal, a text field or another app
/// can't take a tab's id as something typed. The payload itself is read
/// from `TabDrag.shared`; the pasteboard only carries the kind.
enum OctetDragKind: String, CaseIterable {
    case tab, workspace, pane, stripTab, plane, ticket, statusChip

    var type: UTType { UTType(exportedAs: "com.jpxsoftware.octet.drag.\(rawValue)", conformingTo: .data) }
    var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(type.identifier) }

    /// Everything the tab strip and the split zones take.
    static let layout: [UTType] = [tab, pane, stripTab].map(\.type)
}

private struct DragSourcesCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A page is drawn over these views, so their drags are off: a source
    /// takes presses by watching events, not by being hit, and would
    /// otherwise start under whatever covers it.
    var octetDragSourcesCovered: Bool {
        get { self[DragSourcesCoveredKey.self] }
        set { self[DragSourcesCoveredKey.self] = newValue }
    }
}

/// How a drag from a `DragSource` ended.
enum DragEnd {
    /// A drop target took it.
    case dropped
    /// Let go where nothing took it, at this point on screen: torn off.
    case released(CGPoint)
    /// Escape, or Octet stopped being the active app: nothing happens.
    case cancelled
}

extension View {
    /// Makes the view draggable as `kind`, the drag run by AppKit so its end
    /// is known: dropped, let go over nothing, or cancelled. Clicks, hover
    /// and context menus still reach the view.
    func octetDragSource(_ kind: OctetDragKind, enabled: Bool = true, began: @escaping () -> Bool,
                         moved: ((CGPoint) -> Void)? = nil, ended: @escaping (DragEnd) -> Void) -> some View {
        overlay(DragSource(kind: kind, enabled: enabled, began: began, moved: moved, ended: ended))
    }
}

/// Starts an AppKit dragging session once the mouse, pressed over the view,
/// travels past a few points. It never takes a click itself: a local monitor
/// watches for the press and the drag, so the view underneath keeps its
/// gestures, as `MiddleClickCatcher` does.
struct DragSource: NSViewRepresentable {
    let kind: OctetDragKind
    let enabled: Bool
    /// Called as the drag starts; false declines it.
    let began: () -> Bool
    let moved: ((CGPoint) -> Void)?
    let ended: (DragEnd) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.kind = kind
        // Under a page drawn over it (Settings, the Agents hub), the view is
        // out of sight: a press there belongs to the page.
        view.enabled = enabled && !context.environment.octetDragSourcesCovered
        view.began = began
        view.moved = moved
        view.ended = ended
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) { view.stopMonitoring() }

    final class SourceView: NSView, NSDraggingSource {
        var kind = OctetDragKind.tab
        var enabled = true
        var began: (() -> Bool)?
        var moved: ((CGPoint) -> Void)?
        var ended: ((DragEnd) -> Void)?
        /// Where the press that may become a drag went down, in window points.
        private var pressedAt: CGPoint?
        private var monitor: Any?
        private var dragging = false
        private var cancelled = false
        private var resignObserver: NSObjectProtocol?

        /// How far the mouse travels before a press is a drag, as Warp's.
        static let threshold: CGFloat = 5
        /// The source of the drag under way, held so that its end still
        /// arrives when the view it started from goes (a pane's grip, as the
        /// tab it's in changes): otherwise the drag would never finish.
        private static var active: SourceView?
        /// Every source watching for presses. Each watches the same events,
        /// so the one under the pointer must be picked, not all that claim it.
        private static let all = NSHashTable<SourceView>.weakObjects()

        /// The press point, in window points, if this view is the innermost
        /// source under it: a neighbour whose frame overlaps (a tab in a
        /// scroll view mid-animation) never takes another tab's press.
        private func claims(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), visibleRect.contains(point) else { return false }
            let area = bounds.width * bounds.height
            for other in Self.all.allObjects where other !== self && other.enabled && other.window === window
                && !other.isHiddenOrHasHiddenAncestor {
                let p = other.convert(event.locationInWindow, from: nil)
                guard other.bounds.contains(p), other.visibleRect.contains(p) else { continue }
                if other.bounds.width * other.bounds.height < area { return false }
            }
            return true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stopMonitoring() : startMonitoring()
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            Self.all.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) {
                [weak self] event in self?.handle(event) ?? event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            Self.all.remove(self)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .keyDown where dragging && event.keyCode == 53:
                cancelled = true
                return event
            case .leftMouseDown:
                pressedAt = nil
                // The visible part only: a tab scrolled out of the strip
                // mustn't take a press meant for what's beside the strip.
                guard enabled, event.window === window, !isHiddenOrHasHiddenAncestor,
                      claims(event),
                      !event.modifierFlags.contains(.control) else { return event }
                pressedAt = event.locationInWindow
                return event
            case .leftMouseDragged:
                guard let start = pressedAt, event.window === window else { return event }
                let p = event.locationInWindow
                guard hypot(p.x - start.x, p.y - start.y) >= Self.threshold else { return event }
                pressedAt = nil
                guard began?() == true else { return event }
                beginSession(with: event)
                return nil
            case .leftMouseUp:
                pressedAt = nil
                return event
            default:
                return event
            }
        }

        private func beginSession(with event: NSEvent) {
            let item = NSPasteboardItem()
            item.setData(Data(), forType: kind.pasteboardType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            dragging.setDraggingFrame(bounds, contents: snapshot())
            self.dragging = true
            cancelled = false
            // Octet going to the background mid-drag (⌘Tab) cancels it,
            // rather than tearing off wherever the pointer then is.
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                self?.cancelled = true
            }
            Self.active = self
            let session = beginDraggingSession(with: [dragging], event: event, source: self)
            // No slide back: it would hold `endedAt` back until after the
            // button is let go, and an Escape would then read as a release.
            session.animatesToStartingPositionsOnCancelOrFail = false
            session.draggingFormation = .none
        }

        /// The view as it's drawn, for the image under the pointer.
        private func snapshot() -> NSImage? {
            guard let content = window?.contentView else { return nil }
            let rect = content.convert(bounds, from: self)
            guard rect.width > 0, rect.height > 0, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            content.cacheDisplay(in: rect, to: rep)
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            return image
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Nothing outside Octet takes one of its drags.
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            moved?(screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            dragging = false
            // Escape ends the session with the button still held; letting go
            // ends it with the button up.
            let escape = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode == 53 } ?? false
            let held = NSEvent.pressedMouseButtons & 1 != 0 || escape
            let outcome: DragEnd = operation != [] ? .dropped : (cancelled || held ? .cancelled : .released(screenPoint))
            cancelled = false
            ended?(outcome)
            Self.active = nil
        }
    }
}
