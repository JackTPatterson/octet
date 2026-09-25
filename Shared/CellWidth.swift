import Foundation

/// How many terminal cells a character takes: two for East Asian wide and
/// emoji characters, one otherwise; what a terminal grid does, so Octet's
/// line can sit on it cell for cell.
enum CellWidth {
    static func of(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        return isWide(scalar.value) ? 2 : 1
    }

    /// Columns before `index` characters of `text`.
    static func columns(_ text: String, upTo index: Int) -> Int {
        text.prefix(index).reduce(0) { $0 + of($1) }
    }

    /// Wide and fullwidth ranges (Unicode East Asian Width W and F).
    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
