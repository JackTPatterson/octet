import AppKit
import Carbon.HIToolbox

/// A shortcut that works from any app: brings Octet to the front, or hides
/// it when it's already there, like iTerm2's hotkey window. Carbon's hotkey
/// registration needs no accessibility permission.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    enum Choice: String, Codable, CaseIterable {
        case off
        case controlBacktick = "ctrl_backtick"
        case optionSpace = "option_space"
        case commandOptionT = "cmd_option_t"

        var title: String {
            switch self {
            case .off: "Off"
            case .controlBacktick: "⌃`"
            case .optionSpace: "⌥Space"
            case .commandOptionT: "⌥⌘T"
            }
        }

        fileprivate var key: (code: UInt32, modifiers: UInt32)? {
            switch self {
            case .off: nil
            case .controlBacktick: (UInt32(kVK_ANSI_Grave), UInt32(controlKey))
            case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
            case .commandOptionT: (UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey))
            }
        }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers the chosen shortcut, replacing any earlier one.
    func apply(_ choice: Choice) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let key = choice.key else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.shared.toggle() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F435454), id: 1)   // "OCTT"
        let status = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            ToastCenter.shared.fail(nil, "Couldn't use \(choice.title) as Octet's hotkey",
                                    detail: "Another app may already use it. Pick another in Settings › General.")
        }
    }

    /// In front with a window showing: hide. Otherwise: come forward.
    func toggle() {
        if SettingsStore.shared.values.hotkeyDropDown { return toggleDropDown() }
        if NSApp.isActive, NSApp.keyWindow?.isVisible == true {
            NSApp.hide(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = WindowRegistry.shared.key { window.bringForward() }
        else { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        OctetTerminalRuntime.focusTerminal()
    }

    // MARK: - Drop-down

    /// The window the hotkey drops down, and how it was before, to put back.
    private weak var dropped: NSWindow?
    private var before: (frame: NSRect, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior)?

    /// The top of the screen the pointer is on, full width: over every
    /// Space, a full-screen app's included, like a Quake console.
    static func dropDownFrame(in visible: NSRect, share: CGFloat = 0.45) -> NSRect {
        let height = (visible.height * share).rounded()
        return NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
    }

    private func toggleDropDown() {
        if let window = dropped, window.isVisible, NSApp.isActive {
            // Slide up and away.
            let away = window.frame.offsetBy(dx: 0, dy: window.frame.height)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = !MotionPreferences.shared.enabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                window.animator().setFrame(away, display: true)
            }, completionHandler: {
                MainActor.assumeIsolated {
                    window.orderOut(nil)
                    NSApp.hide(nil)
                }
            })
            return
        }
        guard let window = dropped ?? WindowRegistry.shared.key?.nsWindow
                ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        if dropped !== window {
            restoreDropDown()
            dropped = window
            before = (window.frame, window.level, window.collectionBehavior)
        }
        window.collectionBehavior = before!.behavior.union([.canJoinAllSpaces, .fullScreenAuxiliary]).subtracting(.moveToActiveSpace)
        window.level = .floating
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let target = Self.dropDownFrame(in: screen?.visibleFrame ?? window.frame)
        window.setFrame(target.offsetBy(dx: 0, dy: target.height), display: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = !MotionPreferences.shared.enabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            window.animator().setFrame(target, display: true)
        }
        OctetTerminalRuntime.focusTerminal()
    }

    /// Puts the dropped-down window back as it was (the setting turned off).
    func restoreDropDown() {
        guard let window = dropped, let before else { return }
        window.level = before.level
        window.collectionBehavior = before.behavior
        window.setFrame(before.frame, display: true)
        dropped = nil
        self.before = nil
    }
}
