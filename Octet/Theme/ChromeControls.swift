import AppKit
import SwiftUI

/// Borderless text field that edits a tab or workspace name in place. Return
/// commits, Escape cancels, and clicking away commits like Finder. The
/// terminal gets keyboard focus back either way.
struct InlineRenameField: View {
    let initial: String
    let placeholder: String
    /// The new name, or nil when the edit was cancelled.
    let onFinish: (String?) -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.uiFont)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Theme.terminalBackground)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 1))
            .focused($focused)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(text) }
            }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        onFinish(trimmed == initial ? nil : trimmed)
        OctetTerminalRuntime.focusTerminal()
    }
}

/// Transparent overlay that only claims middle clicks, so left clicks,
/// hover, and context menus still reach the view underneath.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                return super.otherMouseUp(with: event)
            }
            action?()
        }
    }
}

/// Keeps the window title (read by Mission Control, the Window menu and
/// VoiceOver) on the focused workspace and tab, and reports full screen.
struct WindowObserver: NSViewRepresentable {
    let title: String
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.watch(window) { isFullScreen = $0 }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let title = self.title
        DispatchQueue.main.async { view.window?.title = title }
    }

    final class ObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []

        @MainActor
        func watch(_ window: NSWindow, report: @escaping (Bool) -> Void) {
            MainWindow.window = window
            observers.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in report(true) },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in report(false) },
            ]
            report(window.styleMask.contains(.fullScreen))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// The window a view lives in, and whether it's the one in front. Lets an
/// overlay that every window carries (dialogs, toasts) draw in just one.
@MainActor
final class HostWindow: ObservableObject {
    private(set) weak var window: NSWindow?
    @Published private(set) var isKey = false
    private var observers: [NSObjectProtocol] = []

    /// In front: key, or nothing is key and this is the terminal window.
    var isFront: Bool {
        isKey || (NSApp.keyWindow == nil && window != nil && window === MainWindow.window)
    }

    /// Whether a dialog raised in `origin` belongs here.
    func owns(_ origin: NSWindow?) -> Bool {
        guard let window else { return false }
        if let origin, origin.isVisible { return origin === window }
        return window === (MainWindow.window ?? window)
    }

    func attach(_ window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isKey = window.isKeyWindow }
            })
        }
        isKey = window.isKeyWindow
    }
}

struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class ReaderView: NSView {
        weak var host: HostWindow?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [weak self] in self?.host?.attach(window) }
        }
    }
}
