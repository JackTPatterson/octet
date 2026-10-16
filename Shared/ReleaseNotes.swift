import Foundation

/// An update's release notes as Markdown, for Octet's update dialog to draw
/// with its own Markdown view. Sparkle hands notes over as HTML (the usual
/// appcast `<description>` or a linked page), Markdown, or plain text; HTML
/// is turned into the few Markdown blocks release notes use (headings,
/// lists, paragraphs, emphasis, code, links) rather than shown in a web view,
/// which is what read as raw text on a black page.
enum ReleaseNotes {
    /// `format` is Sparkle's `itemDescriptionFormat` ("html", "markdown",
    /// "plain-text"), or a MIME type for a downloaded page; nil means HTML,
    /// Sparkle's default.
    static func markdown(_ text: String, format: String?) -> String {
        let kind = (format ?? "html").lowercased()
        if kind.contains("markdown") || kind.contains("plain") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return markdown(fromHTML: text)
    }

    static func markdown(fromHTML html: String) -> String {
        var text = html
        // Things that never show.
        for tag in ["script", "style", "head", "title"] {
            text = replacing("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: text, with: "")
        }
        text = replacing("<!--[\\s\\S]*?-->", in: text, with: "")

        // Preformatted blocks keep their lines; set aside before whitespace
        // is collapsed, and put back as fenced code.
        var blocks: [String] = []
        text = replacing("<pre\\b[^>]*>([\\s\\S]*?)</pre>", in: text) { groups in
            let code = decodeEntities(replacing("<[^>]+>", in: groups[1], with: ""))
            blocks.append("```\n" + code.trimmingCharacters(in: .newlines) + "\n```")
            return "\u{0}\(blocks.count - 1)\u{0}"
        }

        // HTML's own line breaks mean nothing.
        text = replacing("\\s+", in: text, with: " ")
        text = replacing("<br\\s*/?>", in: text, with: "\n")
        text = replacing("<h([1-6])\\b[^>]*>(.*?)</h\\1>", in: text) { groups in
            "\n\n" + String(repeating: "#", count: Int(groups[1]) ?? 2) + " " + groups[2].trimmingCharacters(in: .whitespaces) + "\n\n"
        }
        text = replacing("<li\\b[^>]*>", in: text, with: "\n- ")
        text = replacing("</li>", in: text, with: "")
        text = replacing("</?(p|div|ul|ol|blockquote|section|article|table|tr)\\b[^>]*>", in: text, with: "\n\n")
        text = replacing("<hr\\b[^>]*>", in: text, with: "\n\n---\n\n")
        text = replacing("</?(strong|b)\\b[^>]*>", in: text, with: "**")
        text = replacing("</?(em|i)\\b[^>]*>", in: text, with: "*")
        text = replacing("</?code\\b[^>]*>", in: text, with: "`")
        text = replacing("<a\\b[^>]*href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>", in: text) { groups in
            let label = groups[2].trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? groups[1] : "[\(label)](\(groups[1]))"
        }
        text = replacing("<[^>]+>", in: text, with: "")
        text = decodeEntities(text)

        // Tidy: no stray spaces at line edges, at most one blank line.
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        text = replacing("\n{3,}", in: lines.joined(separator: "\n"), with: "\n\n")
        for (index, block) in blocks.enumerated() {
            text = text.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: "\n\n" + block + "\n\n")
        }
        text = replacing("\n{3,}", in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How the update dialog names a version. Betas share a marketing
    /// version ("0.1.0" for beta 18 and 19 alike), so when the two being
    /// compared read the same the build goes alongside, or the dialog
    /// would say 0.1.0 is replacing 0.1.0.
    static func versionLabel(display: String, build: String, comparedTo otherDisplay: String) -> String {
        let display = display.isEmpty ? build : display
        guard display == otherDisplay, !build.isEmpty, build != display else { return display }
        return "\(display) (\(build))"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&rarr;": "\u{2192}"]
        var result = text
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        result = replacing("&#(x?)([0-9a-fA-F]+);", in: result) { groups in
            let value = UInt32(groups[2], radix: groups[1].isEmpty ? 10 : 16)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? groups[0]
        }
        // Last, so "&amp;lt;" stays "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with what `transform` makes of its groups
    /// (group 0 is the whole match; a group that didn't take part is "").
    private static func replacing(_ pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += transform(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }
}
