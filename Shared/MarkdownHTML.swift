import Foundation

/// A Markdown file as HTML, for the editor's viewer: the blocks Octet already
/// parses, written out as GitHub would draw them, with the file's own HTML
/// (centred headers, badges, `<picture>`, `<details>`) passed through as is.
enum MarkdownHTML {
    /// The page's body for `markdown`.
    static func body(_ markdown: String) -> String {
        var html = ""
        // Open lists, innermost last: whether each is ordered.
        var lists: [Bool] = []

        func closeLists(to depth: Int) {
            while lists.count > depth {
                html += lists.removeLast() ? "</li></ol>\n" : "</li></ul>\n"
            }
        }

        for block in MarkdownBlock.parse(markdown) {
            if case .listItem(let ordinal, let depth, let text) = block {
                let ordered = ordinal != nil
                if lists.count > depth + 1 { closeLists(to: depth + 1) }
                if lists.count == depth + 1, lists[depth] != ordered { closeLists(to: depth) }
                if lists.count == depth + 1 {
                    html += "</li>\n<li>"
                } else {
                    // Deeper than the list it's in by any amount: one level in.
                    let start = ordinal.flatMap { $0 == 1 ? nil : $0 }.map { " start=\"\($0)\"" } ?? ""
                    html += ordered ? "<ol\(start)>\n<li>" : "<ul>\n<li>"
                    lists.append(ordered)
                }
                html += listItem(text)
                continue
            }
            closeLists(to: 0)
            switch block {
            case .paragraph(let text):
                html += isHTML(text) ? text + "\n" : "<p>" + inline(text) + "</p>\n"
            case .heading(let level, let text):
                html += "<h\(level) id=\"\(slug(text))\">" + inline(text) + "</h\(level)>\n"
            case .quote(let text):
                html += quote(text)
            case .code(let language, let text):
                let type = language.map { " class=\"language-\(escape($0))\"" } ?? ""
                html += "<pre><code\(type)>" + escape(text) + "</code></pre>\n"
            case .table(let header, let rows):
                html += "<table>\n<thead><tr>" + header.map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows {
                    html += "<tr>" + row.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>\n"
                }
                html += "</tbody>\n</table>\n"
            case .rule:
                html += "<hr>\n"
            case .listItem:
                break
            }
        }
        closeLists(to: 0)
        return html
    }

    /// A block written in HTML rather than Markdown, which stays as written.
    static func isHTML(_ text: String) -> Bool {
        text.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(\s|>|/>|$)"#, options: .regularExpression) != nil
            || text.hasPrefix("<!--")
    }

    /// A task list's box, else the item's words.
    private static func listItem(_ text: String) -> String {
        for (marker, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(marker) {
            let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            return box + inline(String(text.dropFirst(marker.count)))
        }
        return inline(text)
    }

    /// A quote, or one of GitHub's alerts (`> [!NOTE]`) when it starts with one.
    private static func quote(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let alerts = ["NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important", "WARNING": "Warning", "CAUTION": "Caution"]
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[!"), first.hasSuffix("]"),
           let title = alerts[String(first.dropFirst(2).dropLast()).uppercased()] {
            lines.removeFirst()
            return "<div class=\"alert alert-\(title.lowercased())\"><p class=\"alert-title\">\(title)</p>"
                + paragraphs(lines) + "</div>\n"
        }
        return "<blockquote>" + paragraphs(lines) + "</blockquote>\n"
    }

    /// Lines split into paragraphs at blank ones.
    private static func paragraphs(_ lines: [String]) -> String {
        lines.split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "<p>" + inline($0.joined(separator: "\n")) + "</p>" }
            .joined()
    }

    // MARK: - Inline

    /// Code spans, links, images, emphasis and autolinks as HTML. Inline
    /// HTML is kept; every other `<`, `>` and `&` is escaped.
    static func inline(_ text: String) -> String {
        var kept: [String] = []
        func keep(_ html: String) -> String {
            kept.append(html)
            return "\u{1}\(kept.count - 1)\u{2}"
        }
        var text = text
        // Hard breaks: two trailing spaces or a backslash before a newline.
        text = replace(text, #"( {2,}|\\)\n"#) { _ in keep("<br>\n") }
        // Code spans first: nothing inside them is Markdown or HTML.
        text = replace(text, #"(`+)(.+?)\1"#) { groups in
            keep("<code>" + escape(groups[2].trimmingCharacters(in: .whitespaces)) + "</code>")
        }
        text = replace(text, #"<(https?://[^>\s]+)>"#) { groups in
            keep("<a href=\"\(attribute(groups[1]))\">\(escape(groups[1]))</a>")
        }
        text = replace(text, #"<!--[\s\S]*?-->|</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#) { groups in keep(groups[0]) }
        text = escapeText(text)
        text = replace(text, #"!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\s*\)"#) { groups in
            "<img src=\"\(groups[2])\" alt=\"\(groups[1])\">"
        }
        text = replace(text, #"\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\s*\)"#) { groups in
            "<a href=\"\(groups[2])\">\(groups[1])</a>"
        }
        text = replace(text, #"(?<![\w"'=(/>])(https?://[^\s<>()]+[^\s<>().,;:!?'"])"#) { groups in
            "<a href=\"\(groups[1])\">\(groups[1])</a>"
        }
        text = replace(text, #"\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__"#) { groups in
            "<strong>\(groups[1].isEmpty ? groups[2] : groups[1])</strong>"
        }
        text = replace(text, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])|(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#) { groups in
            "<em>\(groups[1].isEmpty ? groups[2] : groups[1])</em>"
        }
        text = replace(text, #"~~(?=\S)(.+?)(?<=\S)~~"#) { groups in "<del>\(groups[1])</del>" }
        // What was set aside goes back, in its place.
        return replace(text, "\u{1}(\\d+)\u{2}") { groups in Int(groups[1]).map { kept[$0] } ?? "" }
    }

    /// A heading's anchor, as GitHub makes it: lower case, punctuation
    /// dropped, spaces as hyphens, so `#build-from-source` links land.
    static func slug(_ text: String) -> String {
        let plain = replace(text, #"<[^>]+>|[`*_~]|\[([^\]]*)\]\([^)]*\)"#) { groups in groups[1] }
        return plain.lowercased().compactMap { character -> String? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return String(character) }
            return character == " " ? "-" : nil
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escaped, but with entities the file wrote (`&nbsp;`, `&copy;`) kept.
    private static func escapeText(_ text: String) -> String {
        replace(text, #"&(?!#?[A-Za-z0-9]+;)"#) { _ in "&amp;" }
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func attribute(_ text: String) -> String {
        escape(text)
    }

    /// Every match of `pattern` in `text` replaced by what `make` returns for
    /// its groups (a group that didn't take part is empty).
    private static func replace(_ text: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += make(groups)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }
}
