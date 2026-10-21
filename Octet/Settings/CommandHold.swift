import AppKit
import SwiftUI

/// Holding ⌘ on its own for a moment reveals the ⌘-number on each tab, as
/// Warp and T3 Code do. Any other key, a click, or letting go hides them.
///
/// Unlike T3 Code this also works while the terminal has focus: in Octet the
/// terminal nearly always does, and ⌘ alone types nothing, so there is no
/// typing to get in the way of. A chord (⌘C, ⌘T) is a key-down before the
/// delay runs out, which cancels the reveal, so quick shortcuts never flash
/// badges.
@MainActor
final class CommandHold: ObservableObject {
    static let shared = CommandHold()

    /// Between T3 Code's 200ms, which flickers on ordinary chords, and
    /// Warp's 750ms, which feels slow when you're looking for a number.
    static let delay: TimeInterval = 0.5

    @Published private(set) var revealed = false
    private var pending: DispatchWorkItem?
    nonisolated(unsafe) private var monitor: Any?
    private var resign: NSObjectProtocol?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return hide() }
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        held == .command ? arm() : hide()
    }

    private func arm() {
        guard pending == nil, !revealed else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.revealed = true
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        if revealed { revealed = false }
    }
}

/// Which ⌘-number reaches a tab: ⌘1 to ⌘8 by position, and ⌘9 (Last Tab)
/// for the last one once it's past the eighth.
enum TabJump {
    /// 1 to 8, 9 for "last", or nil for a tab no number reaches.
    static func number(index: Int, count: Int) -> Int? {
        guard index >= 0, index < count else { return nil }
        if index < 8 { return index + 1 }
        return index == count - 1 ? 9 : nil
    }

    /// The shortcut as it's bound now, so the label follows a rebind.
    static func shortcut(index: Int, count: Int) -> OctetShortcut? {
        number(index: index, count: count).map(OctetShortcut.tab)
    }
}
