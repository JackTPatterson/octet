import AppKit
import SwiftUI

/// Makes the hosting window's title bar transparent and dark so the
/// sidebar runs to the top edge, like the main window.
struct DarkTransparentTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the window's background and appearance in step with the theme.
struct ThemedWindow: NSViewRepresentable {
    let themeName: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
        }
    }
}

/// Gives a custom title bar the native behavior: drag moves the window and a
/// double-click zooms or minimizes, following the system "Double-click a
/// window's title bar to" setting. Place it behind the bar's controls.
struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}

/// Centers the traffic lights vertically in a custom title bar of `height`.
/// AppKit resets their position on layout, so it reapplies on every resize.
struct TrafficLightAligner: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = AlignerView()
        view.height = height
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AlignerView)?.height = height
    }

    private final class AlignerView: NSView {
        var height: CGFloat = 0 { didSet { align() } }
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    self?.align()
                }
            }
            DispatchQueue.main.async { self.align() }
        }

        private func align() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
                // The title bar view is not flipped: y counts up from its bottom.
                let fromTop = (height - button.frame.height) / 2
                let y = bar.bounds.height - fromTop - button.frame.height
                if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
            }
        }
    }
}
