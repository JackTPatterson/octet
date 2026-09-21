import AppKit
import SwiftUI

/// One terminal window: its context, made once, and the shared stores.
struct OctetWindowRoot: View {
    let spec: OctetWindowSpec
    @ObservedObject var store: SessionStore
    let session: EngineSession?
    @ObservedObject var slash: SlashController
    @ObservedObject var prompt: PromptEditor
    @StateObject private var context: WindowContext
    @Environment(\.openWindow) private var openWindow

    init(spec: OctetWindowSpec, store: SessionStore, session: EngineSession?, slash: SlashController, prompt: PromptEditor) {
        self.spec = spec
        self.store = store
        self.session = session
        self.slash = slash
        self.prompt = prompt
        _context = StateObject(wrappedValue: WindowContext(spec: spec, store: store))
    }

    var body: some View {
        RootView(store: store, ui: context.ui, session: session, slash: slash, prompt: prompt)
            .environmentObject(context)
            .background(WindowAccessor(context: context, origin: spec.origin, frame: spec.frame))
            .onAppear {
                WindowRegistry.shared.add(context)
                WindowOpener.open = { openWindow(value: $0) }
            }
            .onDisappear { WindowRegistry.shared.remove(context) }
            .onChange(of: context.focusedWorkspace?.workspaceId) { _, _ in WindowRegistry.shared.save() }
    }
}

/// Opens terminal windows from outside a view: SwiftUI's `openWindow` only
/// exists inside one, so each window hands it over.
@MainActor
enum WindowOpener {
    static var open: ((OctetWindowSpec) -> Void)?
}

/// Ties a window's context to its `NSWindow`: which window it is, where a
/// torn-off tab asked for it to go, and when it comes to the front.
private struct WindowAccessor: NSViewRepresentable {
    let context: WindowContext
    let origin: CGPoint?
    let frame: CGRect?

    func makeCoordinator() -> Coordinator { Coordinator(context: context, origin: origin, frame: frame) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.window == nil {
            DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
        }
    }

    @MainActor
    final class Coordinator {
        let context: WindowContext
        var origin: CGPoint?
        var frame: CGRect?
        weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(context: WindowContext, origin: CGPoint?, frame: CGRect?) {
            self.context = context
            self.origin = origin
            self.frame = frame
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            context.nsWindow = window
            // Where the tab was let go, as the window's top-left, kept on screen.
            // Reopened as it was, when that still fits a screen.
            if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                self.frame = nil
                window.setFrame(frame, display: true)
            } else if let origin {
                self.origin = nil
                var frame = window.frame
                frame.origin = CGPoint(x: origin.x - 60, y: origin.y - frame.height + 20)
                if let visible = (NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? window.screen)?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
                }
                window.setFrame(frame, display: true)
            }
            let context = self.context
            let becameKey = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    WindowRegistry.shared.becameKey(context)
                    MainWindow.window = window
                }
            }
            let willClose = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { context.closing = true }
            }
            let moved = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { WindowRegistry.shared.save() }
            }
            observers = [becameKey, willClose, moved]
            if window.isKeyWindow {
                WindowRegistry.shared.becameKey(context)
                MainWindow.window = window
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Runs a menu command on the terminal window in front. Nothing happens
/// while Settings or the Marketplace is the key window.
@MainActor
enum KeyWindow {
    static func act(_ action: (WindowContext) -> Void) {
        MainWindow.perform {
            if let window = WindowRegistry.shared.key { action(window) }
        }
    }
}
