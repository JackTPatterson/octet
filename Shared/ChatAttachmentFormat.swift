import Foundation

/// Something riding along with a message besides its words and images, as
/// ChatGPT shows them: a file, or a long run of pasted text, each a tile
/// rather than a wall of text in the box.
struct ComposerExtra: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(String)
        case pasted(String)
    }
    let id = UUID()
    let kind: Kind
}

/// How extras travel. The agent gets plain text it already understands
/// (pasted text in a fenced `pasted` block, files as @mentions on a line of
/// their own at the end), and a sent message is read back into tiles.
enum ChatAttachmentFormat {
    static let pastedLanguage = "pasted"

    /// A paste this big becomes a tile instead of text in the box.
    static func collapses(_ inserted: String) -> Bool {
        inserted.count >= 1_000 || inserted.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= 9
    }

    /// The message as sent: the words, then each pasted block, then the files.
    static func compose(_ message: String, extras: [ComposerExtra], cwd: String) -> String {
        var parts = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
        for extra in extras {
            if case .pasted(let text) = extra.kind { parts.append(fenced(text)) }
        }
        let files = extras.compactMap { extra -> String? in
            if case .file(let path) = extra.kind { return "@" + AgentComposerSyntax.mentionPath(path, cwd: cwd) }
            return nil
        }
        if !files.isEmpty { parts.append(files.joined(separator: " ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A fence longer than any run of backticks inside, so the text can't close it.
    private static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + pastedLanguage + "\n" + text + "\n" + fence
    }

    struct Parts: Equatable {
        var body: String
        var pasted: [String]
        var files: [String]
    }

    /// A sent message taken apart again: its words, its pasted blocks, and
    /// the files on its last line (only when that line is nothing but
    /// @mentions, so a mention mid-sentence stays where it was written).
    static func parse(_ text: String) -> Parts {
        var body = text
        var pasted: [String] = []
        let pattern = #"(?m)^(`{3,})pasted\n([\s\S]*?)\n\1[ \t]*$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: body), let inner = Range(match.range(at: 2), in: body) else { continue }
                pasted.insert(String(body[inner]), at: 0)
                body.removeSubrange(whole)
            }
        }
        var files: [String] = []
        var lines = body.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last {
            let tokens = last.split(separator: " ", omittingEmptySubsequences: true)
            if !tokens.isEmpty, tokens.allSatisfy({ $0.hasPrefix("@") && $0.count > 1 }) {
                files = tokens.map { String($0.dropFirst()) }
                lines.removeLast()
            }
        }
        body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(body: body, pasted: pasted, files: files)
    }

    /// What was inserted between two versions of the box's text, when it
    /// was one contiguous insertion (a paste), with where it went.
    static func insertion(from old: String, to new: String) -> (text: String, range: Range<String.Index>)? {
        guard new.count > old.count else { return nil }
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        let keptSuffix = min(suffix, old.count - prefix)
        let start = new.index(new.startIndex, offsetBy: prefix)
        let end = new.index(new.endIndex, offsetBy: -keptSuffix)
        guard start <= end, prefix + keptSuffix == old.count else { return nil }
        return (String(new[start..<end]), start..<end)
    }
}
