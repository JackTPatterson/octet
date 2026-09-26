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
        if NSApp.isActive, NSApp.keyWindow?.isVisible == true {
            NSApp.hide(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = WindowRegistry.shared.key { window.bringForward() }
        else { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        OctetTerminalRuntime.focusTerminal()
    }
}
