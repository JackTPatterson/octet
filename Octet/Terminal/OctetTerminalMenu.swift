import AppKit

/// The terminal's right-click (and ⌃-click) menu.
@MainActor
enum OctetTerminalMenu {
    static func menu(for surface: TerminalEngine.SurfaceView) -> NSMenu? {
        guard let window = WindowRegistry.shared.windows.first(where: { $0.nsWindow === surface.window })
                ?? WindowRegistry.shared.key else { return nil }
        let menu = NSMenu()
        if let text = surface.accessibilitySelectedText(), !text.isEmpty {
            menu.addItem(item("Copy", key: "c") { surface.copy(nil) })
        }
        menu.addItem(item("Paste", key: "v") { surface.paste(nil) })
        menu.addItem(.separator())
        menu.addItem(item("Split Right", key: "d") { window.splitPane(.right) })
        menu.addItem(item("Split Down", key: "d", shift: true) { window.splitPane(.down) })
        menu.addItem(item("Toggle Zoom") { window.toggleZoom() })
        menu.addItem(item("Close Pane") { window.closeFocusedPane() })
        menu.addItem(.separator())
        menu.addItem(item("Copy Last Command's Output") { PromptJumper.copyLastOutput(store: window.store) })
        menu.addItem(item("Find…", key: "f") { window.findOutput(.showFindInterface) })
        menu.addItem(item("Open Link or File on Screen…", key: "h", shift: true) { HintsSession.start(window: window) })
        menu.addItem(item("Review Changes", key: "r", shift: true) { window.toggleReview() })
        menu.addItem(.separator())
        // ⌃L: the shell (or program) redraws a clear screen; scrollback stays.
        menu.addItem(item("Clear Screen") {
            guard let pane = window.store.keyPaneId else { return }
            let client = window.store.client
            EngineClient.inputQueue.async { _ = try? client.call("pane.send_text", ["pane_id": pane, "text": "\u{0c}"]) }
        })
        return menu
    }

    private static func item(_ title: String, key: String = "", shift: Bool = false,
                             _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = shift ? [.command, .shift] : .command
        return item
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { MainActor.assumeIsolated { run() } }
}
