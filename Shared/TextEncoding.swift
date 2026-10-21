import Foundation

/// What a text file is encoded in, found from its bytes rather than
/// assumed, so the editor opens a Latin-1 or UTF-16 file instead of calling
/// it binary, says which it is, and writes it back the same way.
struct DecodedText: Equatable {
    enum LineEnding: String, Equatable {
        case lf = "LF", crlf = "CRLF", cr = "CR"
    }

    let text: String
    let encoding: String.Encoding
    /// The file began with a byte order mark, to be written back.
    let byteOrderMark: Bool

    /// How the footer names it: "UTF-8", "UTF-16 LE", "Windows-1252"…
    var encodingName: String { TextEncoding.name(of: encoding, byteOrderMark: byteOrderMark) }

    /// The first line ending in the file; LF when it has none.
    var lineEnding: LineEnding { TextEncoding.lineEnding(of: text) }
}

enum TextEncoding {
    /// Single-byte encodings tried, in order, when the bytes aren't valid
    /// UTF-8. Windows-1252 first: it's what "not quite ASCII" text from
    /// Windows usually is, and it reads Latin-1 text too. Mac Roman is last
    /// because it accepts almost anything.
    static let fallbacks: [String.Encoding] = [.windowsCP1252, .isoLatin1, .macOSRoman]

    /// The text in `data`, or nil when it looks binary (a NUL outside
    /// UTF-16/32, or nothing decodes it).
    static func decode(_ data: Data) -> DecodedText? {
        let bytes = [UInt8](data.prefix(4))
        // Byte order marks first: they settle it.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else { return nil }
            return DecodedText(text: text, encoding: .utf8, byteOrderMark: true)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            guard let text = String(data: data.dropFirst(4), encoding: little ? .utf32LittleEndian : .utf32BigEndian) else { return nil }
            return DecodedText(text: text, encoding: little ? .utf32LittleEndian : .utf32BigEndian, byteOrderMark: true)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            guard let text = String(data: data.dropFirst(2), encoding: little ? .utf16LittleEndian : .utf16BigEndian) else { return nil }
            return DecodedText(text: text, encoding: little ? .utf16LittleEndian : .utf16BigEndian, byteOrderMark: true)
        }
        // A NUL with no mark is a binary file, not text.
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8, byteOrderMark: false)
        }
        for encoding in fallbacks {
            guard let text = String(data: data, encoding: encoding), !looksControl(text) else { continue }
            return DecodedText(text: text, encoding: encoding, byteOrderMark: false)
        }
        return nil
    }

    /// `text` as bytes in `encoding`, with the mark it was read with. nil
    /// when a character can't be written in that encoding (the caller then
    /// offers UTF-8).
    static func encode(_ text: String, as encoding: String.Encoding, byteOrderMark: Bool) -> Data? {
        guard var body = text.data(using: encoding, allowLossyConversion: false) else { return nil }
        // Foundation adds its own mark for the plain .utf16/.utf32; the
        // explicit-endian ones never do, so add it when the file had one.
        if byteOrderMark {
            let mark: [UInt8]
            switch encoding {
            case .utf8: mark = [0xEF, 0xBB, 0xBF]
            case .utf16LittleEndian: mark = [0xFF, 0xFE]
            case .utf16BigEndian: mark = [0xFE, 0xFF]
            case .utf32LittleEndian: mark = [0xFF, 0xFE, 0x00, 0x00]
            case .utf32BigEndian: mark = [0x00, 0x00, 0xFE, 0xFF]
            default: mark = []
            }
            body.insert(contentsOf: mark, at: 0)
        }
        return body
    }

    static func name(of encoding: String.Encoding, byteOrderMark: Bool) -> String {
        switch encoding {
        case .utf8: return byteOrderMark ? "UTF-8 with BOM" : "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .utf16: return "UTF-16"
        case .utf32LittleEndian: return "UTF-32 LE"
        case .utf32BigEndian: return "UTF-32 BE"
        case .windowsCP1252: return "Windows-1252"
        case .isoLatin1: return "ISO-8859-1"
        case .macOSRoman: return "Mac Roman"
        case .ascii: return "ASCII"
        default: return String.localizedName(of: encoding)
        }
    }

    static func lineEnding(of text: String) -> DecodedText.LineEnding {
        let bytes = text.utf8
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let unit = bytes[index]
            if unit == 0x0A { return .lf }
            if unit == 0x0D {
                let next = bytes.index(after: index)
                return next != bytes.endIndex && bytes[next] == 0x0A ? .crlf : .cr
            }
            index = bytes.index(after: index)
        }
        return .lf
    }

    /// Mostly C0 controls (other than tab and line breaks): binary bytes a
    /// single-byte encoding happened to accept.
    private static func looksControl(_ text: String) -> Bool {
        var controls = 0
        var total = 0
        for scalar in text.unicodeScalars.prefix(4096) {
            total += 1
            if scalar.value < 0x20, ![0x09, 0x0A, 0x0D, 0x0C].contains(scalar.value) { controls += 1 }
        }
        return total > 0 && controls * 10 > total
    }
}
