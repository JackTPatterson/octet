import Foundation

/// Prompt links, after T3 Code's: `octet://new?prompt=…&dir=…&agent=…`
/// opens a new conversation with the prompt typed in but not sent. A link
/// can come from anywhere, so the prompt is cleaned of characters that
/// draw as nothing (a model reads them; the person checking it can't) and
/// capped in length.
enum PromptLink {
    static let maximumPromptLength = 8_000

    /// Zero-width and bidi controls, tag and variation-selector blocks, and
    /// other characters that render as nothing; T3 Code's list.
    private static let hidden: [ClosedRange<UInt32>] = [
        0x0000...0x0008, 0x000B...0x000C, 0x000E...0x001F, 0x007F...0x009F, 0x00AD...0x00AD, 0x034F...0x034F,
        0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180F, 0x200B...0x200C, 0x200E...0x200F,
        0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164, 0xFE00...0xFE0D, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0,
        0xFFF0...0xFFFB, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF,
    ]

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        hidden.contains { $0.contains(scalar.value) }
    }

    /// Pieces emoji sequences are built from, between which a zero-width
    /// joiner is part of the emoji rather than hiding anything.
    private static func isEmojiPart(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x1F000...0x1FAFF).contains(value) || (0x2190...0x2BFF).contains(value) || value == 0xFE0F
    }

    /// The prompt as it will be shown, and how many invisible characters
    /// were taken out of it.
    static func sanitize(_ raw: String) -> (text: String, hiddenCharacters: Int) {
        var removed = 0
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let scalars: [Unicode.Scalar] = unified.unicodeScalars.filter { scalar in
            guard isHidden(scalar) else { return true }
            removed += 1
            return false
        }
        var kept = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x200D {
                let before = index > 0 ? scalars[index - 1] : nil
                let after = index + 1 < scalars.count ? scalars[index + 1] : nil
                guard isEmojiPart(before), isEmojiPart(after) else {
                    removed += 1
                    continue
                }
            }
            kept.append(scalar)
        }
        return (String(kept).trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    /// The prompt a link may carry, or nil: too long, or nothing visible.
    static func prompt(fromLink raw: String) -> String? {
        guard raw.count <= maximumPromptLength else { return nil }
        let text = sanitize(raw).text
        return text.isEmpty ? nil : text
    }

    /// The last thing the person asked, for "Copy Prompt Link": not a
    /// queued follow-up, a subagent's prompt, or a `!` shell line.
    static func lastPrompt(in items: [AgentItem]) -> String? {
        for item in items.reversed() {
            guard case .user(let text) = item.kind, !item.queued, item.parent == nil else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("! ") { return trimmed }
        }
        return nil
    }

    /// The link for `prompt`, cut to the length a link may carry; nil when
    /// nothing visible is left.
    static func link(prompt: String, dir: String?, agent: String?) -> URL? {
        guard let clean = Self.prompt(fromLink: String(prompt.prefix(maximumPromptLength))) else { return nil }
        return OctetURL.new(prompt: clean, dir: dir, agent: agent).url
    }
}
