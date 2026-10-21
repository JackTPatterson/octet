import Foundation

/// One key plus modifiers, as plain data. Octet's menu shortcuts are stored,
/// compared and handed to the terminal in this form; SwiftUI's
/// `KeyboardShortcut` is made from it only at the menu, so everything that
/// decides (conflicts, what the terminal lets through) is testable here.
struct ShortcutBinding: Hashable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// A single unshifted character ("t", "1", "=", "[") or one of `namedKeys`.
    let key: String
    let modifiers: Modifiers

    init(key: String, modifiers: Modifiers = .command) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    /// Keys with no character of their own, by the name stored for them.
    static let namedKeys = Set([
        "return", "tab", "space", "delete", "forwarddelete", "escape",
        "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
    ] + (1...20).map { "f\($0)" })

    var isFunctionKey: Bool {
        guard key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()) else { return false }
        return (1...20).contains(number)
    }

    /// A menu shortcut needs ⌘, ⌃ or ⌥: with only ⇧ (or nothing) the key
    /// would stop typing its character everywhere. Function keys type
    /// nothing, so they may stand alone.
    var isAllowed: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option]) || isFunctionKey
    }

    // MARK: Stored form

    /// "ctrl+alt+shift+cmd+t": modifiers in a fixed order, then the key.
    var encoded: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Reads `encoded`, plus the spellings a person editing the settings by
    /// hand might use ("command", "opt", "super"). nil for anything else, so
    /// a damaged value falls back to the default rather than a wrong key.
    init?(encoded text: String) {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        // "+" as the key itself: "cmd++".
        var key: String?
        if text.hasSuffix("++") || text == "+" {
            key = "+"
            text = String(text.dropLast(text == "+" ? 1 : 2))
        }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if key == nil { key = parts.popLast() }
        if parts.last == "" { parts.removeLast() }
        guard let key, !key.isEmpty, key.count == 1 || Self.namedKeys.contains(key) else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "alt", "opt", "option", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            case "cmd", "command", "super", "⌘": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(key: key, modifiers: modifiers)
    }

    // MARK: Shown form

    /// The keys as a menu shows them, e.g. ⌃⌘↓, in the system's modifier order.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.symbol(key)
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "return": return "↩"
        case "tab": return "⇥"
        case "space": return "Space"
        case "delete": return "⌫"
        case "forwarddelete": return "⌦"
        case "escape": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        default: return key.uppercased()   // "T", "F5"
        }
    }

    // MARK: Recording

    /// Virtual key codes for keys without a character, as `NSEvent.keyCode`
    /// reports them; they're the same on every keyboard layout.
    static let keyCodeNames: [UInt16: String] = [
        36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete", 117: "forwarddelete",
        53: "escape", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    /// The key a key-down names: by code for the named keys, else by the
    /// character the layout gives it with no modifiers held, so ⌘⇧= records
    /// "=" with shift, not "+", the way menus expect it.
    static func key(keyCode: UInt16, unmodifiedCharacters: String?) -> String? {
        if let name = keyCodeNames[keyCode] { return name }
        guard let character = unmodifiedCharacters?.first,
              let scalar = character.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              // Arrow and function keys arrive as private-use characters.
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return String(character).lowercased()
    }

    // MARK: Terminal

    /// The terminal engine's names for this key in a `keybind` trigger. It
    /// matches a binding by character or by physical key depending on how
    /// that binding was written, so a key with both forms gets both, and
    /// unbinding catches the default whichever way it was written.
    var terminalTriggers: [String] {
        var prefix = ""
        if modifiers.contains(.command) { prefix += "super+" }
        if modifiers.contains(.control) { prefix += "ctrl+" }
        if modifiers.contains(.option) { prefix += "alt+" }
        if modifiers.contains(.shift) { prefix += "shift+" }
        return Self.terminalKeyNames(key).map { prefix + $0 }
    }

    static func terminalKeyNames(_ key: String) -> [String] {
        switch key {
        case "return": return ["enter"]
        case "tab": return ["tab"]
        case "space": return ["space"]
        case "delete": return ["backspace"]
        case "forwarddelete": return ["delete"]
        case "escape": return ["escape"]
        case "left", "right", "up", "down", "home", "end": return [key]
        case "pageup": return ["page_up"]
        case "pagedown": return ["page_down"]
        // The terminal binds font size by character and by key, and ⌘+ as
        // well as ⌘=, so all three go.
        case "=": return ["=", "equal", "plus"]
        case "-": return ["-", "minus"]
        case "[": return ["left_bracket"]
        case "]": return ["right_bracket"]
        case ",": return [",", "comma"]
        case ".": return [".", "period"]
        case "/": return ["/", "slash"]
        case ";": return [";", "semicolon"]
        case "'": return ["'", "quote"]
        case "`": return ["`", "backquote"]
        case "\\": return ["\\", "backslash"]
        default:
            if let digit = key.first, key.count == 1, digit.isASCII, digit.isNumber { return [key, "digit_\(key)"] }
            if key.count == 1, let letter = key.first, letter.isASCII, letter.isLetter { return [key] }
            if key.count > 1 { return [key] }   // f1…f20
            // Any other character from another layout: by character only,
            // and never one that the trigger syntax itself uses.
            return [">", "+"].contains(key) ? [] : [key]
        }
    }
}

/// Octet's rebindable shortcuts and the keys held by things that can't be
/// rebound. Answers what a shortcut is right now, what a new binding takes
/// from others, and which keys the terminal must let through to the menus.
struct ShortcutTable {
    struct Entry: Equatable {
        let id: String
        let title: String
        let defaultBinding: ShortcutBinding?
        /// Where the key applies, for one that only works while something
        /// has focus (the browser page, a conversation); nil for the menus,
        /// which apply everywhere. A scoped key may share a menu's key on
        /// purpose, as the browser's ⌘R does, so only keys in the same scope
        /// conflict, and the terminal is never told to let a scoped one go.
        var scope: String? = nil

        init(id: String, title: String, defaultBinding: ShortcutBinding?, scope: String? = nil) {
            self.id = id
            self.title = title
            self.defaultBinding = defaultBinding
            self.scope = scope
        }
    }

    /// A key someone else holds: Quit and Settings (the system's), Copy and
    /// Paste (the terminal's), Find, ⌘1–⌘8. Recording one is refused, since
    /// unassigning its holder isn't possible.
    struct Reserved: Equatable {
        let binding: ShortcutBinding
        let title: String
        /// Whether it's a menu item the terminal must let the key through
        /// to, rather than a key the terminal handles itself.
        var menu = true
    }

    let entries: [Entry]
    let reserved: [Reserved]

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// The override if there is a readable one, else the default. An empty
    /// override is "unassigned".
    func effective(_ id: String, overrides: [String: String]) -> ShortcutBinding? {
        let fallback = entry(id)?.defaultBinding
        guard let stored = overrides[id] else { return fallback }
        if stored.isEmpty { return nil }
        return ShortcutBinding(encoded: stored) ?? fallback
    }

    /// Whether the person changed it, which the Keyboard page marks "Custom".
    func isCustom(_ id: String, overrides: [String: String]) -> Bool {
        effective(id, overrides: overrides) != entry(id)?.defaultBinding
    }

    /// Each shortcut whose key another one also holds, with the other's
    /// title. A recording never leaves one, but a default added in a later
    /// version can land on a key someone had already taken.
    func conflicts(overrides: [String: String]) -> [String: String] {
        var holders: [ShortcutBinding: [Entry]] = [:]
        for entry in entries {
            guard let binding = effective(entry.id, overrides: overrides) else { continue }
            holders[binding, default: []].append(entry)
        }
        var result: [String: String] = [:]
        for (binding, list) in holders {
            for entry in list {
                if let other = list.first(where: { $0.id != entry.id && $0.scope == entry.scope }) {
                    result[entry.id] = other.title
                } else if let held = reserved.first(where: { $0.binding == binding }) {
                    result[entry.id] = held.title
                }
            }
        }
        return result
    }

    enum Assignment: Equatable {
        /// The new overrides, and the titles of shortcuts that lost the key.
        case assigned(overrides: [String: String], displaced: [String])
        /// Held by something that can't be rebound; its title.
        case reserved(String)
        /// Needs ⌘, ⌃ or ⌥.
        case notAllowed
    }

    /// Gives `id` the binding (nil unassigns it). The most recent binding
    /// wins: any other shortcut on the same key becomes unassigned. An
    /// override equal to the default is dropped, so "Custom" means changed.
    func assign(_ binding: ShortcutBinding?, to id: String, overrides: [String: String]) -> Assignment {
        var result = overrides
        var displaced: [String] = []
        if let binding {
            guard binding.isAllowed else { return .notAllowed }
            if let held = reserved.first(where: { $0.binding == binding }) { return .reserved(held.title) }
            let scope = entry(id)?.scope
            for other in entries where other.id != id && other.scope == scope
                && effective(other.id, overrides: overrides) == binding {
                result[other.id] = ""
                displaced.append(other.title)
            }
        }
        let fallback = entry(id)?.defaultBinding
        result[id] = binding == fallback ? nil : (binding?.encoded ?? "")
        return .assigned(overrides: result, displaced: displaced)
    }

    /// Drops one override.
    func reset(_ id: String, overrides: [String: String]) -> [String: String] {
        var result = overrides
        result[id] = nil
        return result
    }

    /// Terminal `keybind` lines that unbind every key Octet's menus hold
    /// right now, so the key reaches the menu instead of the terminal. A
    /// key freed by rebinding isn't listed, so it goes back to the terminal.
    func terminalPassThrough(overrides: [String: String], extra: [String] = []) -> String {
        var triggers: [String] = []
        var seen = Set<String>()
        let bindings = entries.filter { $0.scope == nil }.compactMap { effective($0.id, overrides: overrides) }
            + reserved.filter(\.menu).map(\.binding)
        for trigger in bindings.flatMap(\.terminalTriggers) + extra where seen.insert(trigger).inserted {
            triggers.append(trigger)
        }
        return triggers.map { "keybind = \($0)=unbind" }.joined(separator: "\n")
    }
}
