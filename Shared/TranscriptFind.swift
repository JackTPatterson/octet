import Foundation

/// Find in conversation, after T3 Code's thread find: the matching behind the
/// bar (message blocks to matches, stepping through them), kept apart from the
/// views so it can be tested on its own. Shared so the tests see one AgentItem.
enum TranscriptFind {
    /// One piece of an item's text that the transcript draws as a single Text.
    /// `key` says which: a Markdown block (or table cell), or a tool's pieces.
    struct Field: Equatable {
        let key: Int
        let text: String
    }

    /// The `ordinal`th occurrence in one field of one item.
    struct Match: Hashable {
        let itemId: String
        let field: Int
        let ordinal: Int
    }

    static let toolSummary = -1
    static let toolInput = -2
    static let toolOutput = -3
    /// What a code panel draws before it cuts the text off.
    static let panelLimit = 20_000

    /// A table cell's key: tables are one block, drawn as many Texts.
    static func key(block: Int, cell: Int = 0) -> Int { block * 1_000 + cell }

    /// The searchable text of an item, in the pieces the transcript draws.
    /// Only text that is on screen counts, so a match is always one you can
    /// see (a diff, an artifact or a to-do list isn't searched).
    static func fields(of item: AgentItem) -> [Field] {
        switch item.kind {
        case .user(let text), .thinking(let text), .notice(let text):
            return [Field(key: 0, text: text)]
        case .text(let text):
            return markdownFields(text)
        case .tool(let call):
            var fields: [Field] = []
            if call.todos == nil, call.artifact == nil, !call.summary.isEmpty {
                fields.append(Field(key: toolSummary, text: call.summary))
            }
            guard call.todos == nil else { return fields }
            let diff = call.diff != nil
            if !diff, !call.input.isEmpty {
                fields.append(Field(key: toolInput, text: String(call.input.prefix(panelLimit))))
            }
            if let output = call.result ?? call.liveOutput, !output.isEmpty, !diff || call.isError {
                fields.append(Field(key: toolOutput, text: String(output.prefix(panelLimit))))
            }
            return fields
        }
    }

    /// The words of each Markdown block, as the view draws them.
    static func markdownFields(_ markdown: String) -> [Field] {
        var fields: [Field] = []
        for (index, block) in MarkdownBlock.parse(markdown).enumerated() {
            switch block {
            case .paragraph(let text), .quote(let text), .heading(_, let text), .listItem(_, _, let text):
                fields.append(Field(key: key(block: index), text: String(inline(text).characters)))
            case .code(_, let text):
                fields.append(Field(key: key(block: index), text: String(text.prefix(panelLimit))))
            case .table(let header, let rows):
                let cells = header + rows.flatMap { row in (0..<header.count).map { $0 < row.count ? row[$0] : "" } }
                for (cell, text) in cells.enumerated() {
                    fields.append(Field(key: key(block: index, cell: cell), text: String(inline(text).characters)))
                }
            case .rule:
                break
            }
        }
        return fields
    }

    /// Bold, italics, code spans and links, keeping line breaks.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func options(caseSensitive: Bool) -> String.CompareOptions {
        caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
    }

    /// Where `query` occurs in `text`, left to right, without overlapping.
    static func ranges(of query: String, in text: String, caseSensitive: Bool) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: query, options: options(caseSensitive: caseSensitive), range: from..<text.endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found
    }

    /// Every match in the items, in reading order.
    static func matches(in items: [AgentItem], query: String, caseSensitive: Bool) -> [Match] {
        guard !query.isEmpty else { return [] }
        return items.flatMap { item in
            fields(of: item).flatMap { field in
                ranges(of: query, in: field.text, caseSensitive: caseSensitive).indices.map {
                    Match(itemId: item.id, field: field.key, ordinal: $0)
                }
            }
        }
    }

    /// The match `by` steps from `index`, wrapping at either end; the first
    /// (or last, going back) when nothing is current.
    static func step(from index: Int?, by: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return by < 0 ? count - 1 : 0 }
        return ((min(index, count - 1) + by) % count + count) % count
    }

    /// Where the current match is after the matches changed (more text
    /// streamed in): the same match when it's still there, else the nearest slot.
    static func reselect(_ previous: Match?, was index: Int?, in matches: [Match]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let previous, let kept = matches.firstIndex(of: previous) { return kept }
        return min(index ?? 0, matches.count - 1)
    }
}
