import Foundation

/// The block structure of an agent's Markdown reply: enough to draw code,
/// headings, lists and quotes natively. Inline styling (bold, code spans,
/// links) is left to AttributedString inside each block.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `ordinal` is the item's number in an ordered list, nil for bullets.
    case listItem(ordinal: Int?, depth: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    /// A pipe table: the header row, then body rows, cells trimmed.
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (language: String?, lines: [String], marker: String)?
        var tableLines: [String] = []

        func flushTable() {
            defer { tableLines = [] }
            guard !tableLines.isEmpty else { return }
            let rows = tableLines.map(Self.cells)
            // Needs a |---| separator after the header to be a table.
            if rows.count >= 2, rows[1].allSatisfy({ $0.allSatisfy { "-:| ".contains($0) } && $0.contains("-") }) {
                blocks.append(.table(header: rows[0], rows: Array(rows.dropFirst(2))))
            } else {
                blocks.append(.paragraph(tableLines.joined(separator: "\n")))
            }
        }

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence == nil, trimmed.hasPrefix("|") {
                flushParagraph()
                tableLines.append(trimmed)
                continue
            }
            flushTable()
            if var open = fence {
                if trimmed.hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fence = (language.isEmpty ? nil : language, [], marker)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let item = Self.listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
                continue
            }
            paragraph.append(line)
        }
        flushTable()
        // A fence still open means the reply is mid-stream: show what's there.
        if let open = fence {
            flushParagraph()
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        let depth = indent / 2
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return .listItem(ordinal: nil, depth: depth, text: String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, let number = Int(digits) {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(ordinal: number, depth: depth, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}
