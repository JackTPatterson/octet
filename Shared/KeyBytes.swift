import Foundation

/// What a key sends to a program in a plain terminal, for mirroring typing
/// into other panes. Only keys with one well-known encoding; anything else
/// is left out rather than guessed.
enum KeyBytes {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let command = Modifiers(rawValue: 4)
    }

    static func encode(keyCode: UInt16, characters: String?, modifiers: Modifiers) -> String? {
        guard !modifiers.contains(.command) else { return nil }
        switch keyCode {
        case 36, 76: return "\r"
        case 51: return "\u{7f}"
        case 48: return "\t"
        case 53: return "\u{1b}"
        case 126: return "\u{1b}[A"
        case 125: return "\u{1b}[B"
        case 124: return "\u{1b}[C"
        case 123: return "\u{1b}[D"
        default: break
        }
        guard let characters, !characters.isEmpty else { return nil }
        if modifiers.contains(.control), characters.count == 1, let scalar = characters.lowercased().unicodeScalars.first,
           (97...122).contains(scalar.value) {
            return String(UnicodeScalar(UInt8(scalar.value - 96)))
        }
        // Private-use characters are function keys with no fixed encoding.
        guard !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return characters
    }
}
