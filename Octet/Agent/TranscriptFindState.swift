import SwiftUI

/// What the bar is looking for, as the transcript draws it: set on each item
/// by the transcript, read by the Texts that show matches.
struct TranscriptFindMarks: Equatable {
    var query: String
    var caseSensitive: Bool
    /// The current match, when it is in this item.
    var current: (field: Int, ordinal: Int)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query == rhs.query && lhs.caseSensitive == rhs.caseSensitive
            && lhs.current?.field == rhs.current?.field && lhs.current?.ordinal == rhs.current?.ordinal
    }

    /// `text` with each match backed in the accent, the current one stronger.
    func mark(_ text: AttributedString, field: Int) -> AttributedString {
        let plain = String(text.characters)
        let found = TranscriptFind.ranges(of: query, in: plain, caseSensitive: caseSensitive)
        guard !found.isEmpty else { return text }
        var result = text
        for (ordinal, range) in found.enumerated() {
            let start = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = result.index(start, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
            let isCurrent = current?.field == field && current?.ordinal == ordinal
            result[start..<end].backgroundColor = Theme.accent.opacity(isCurrent ? 0.7 : 0.28)
            result[start..<end].foregroundColor = Theme.textPrimary
        }
        return result
    }

    func mark(_ text: String, field: Int) -> AttributedString {
        mark(AttributedString(text), field: field)
    }
}

private struct TranscriptFindMarksKey: EnvironmentKey {
    static let defaultValue: TranscriptFindMarks? = nil
}

extension EnvironmentValues {
    var transcriptFindMarks: TranscriptFindMarks? {
        get { self[TranscriptFindMarksKey.self] }
        set { self[TranscriptFindMarksKey.self] = newValue }
    }
}

/// The find bar's state for one conversation.
@MainActor
final class TranscriptFindState: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var query = ""
    @Published var caseSensitive = false
    @Published private(set) var matches: [TranscriptFind.Match] = []
    @Published private(set) var index: Int?
    /// Bumped to put the cursor in the field, again if it is already open.
    @Published private(set) var focusRequest = 0
    /// Bumped when the transcript should scroll to the current match.
    @Published private(set) var scrollRequest = 0

    var current: TranscriptFind.Match? { index.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }

    /// What the transcript draws for one item; nil when nothing is searched.
    func marks(for itemId: String) -> TranscriptFindMarks? {
        guard isOpen, !query.isEmpty else { return nil }
        let here = current?.itemId == itemId ? current : nil
        return TranscriptFindMarks(query: query, caseSensitive: caseSensitive,
                                   current: here.map { ($0.field, $0.ordinal) })
    }

    /// The menu's Find, Find Next and Find Previous.
    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .nextMatch: if isOpen { step(1) }
        case .previousMatch: if isOpen { step(-1) }
        default: open()
        }
    }

    func open() {
        isOpen = true
        focusRequest += 1
    }

    func close() {
        isOpen = false
        matches = []
        index = nil
    }

    /// Looks again, after the query or the transcript changed. Typing starts
    /// at the first match; streaming keeps the one you are on.
    func refresh(_ items: [AgentItem], restart: Bool = false) {
        guard isOpen else { return }
        let found = TranscriptFind.matches(in: items, query: query, caseSensitive: caseSensitive)
        guard found != matches || restart else { return }
        let previous = current
        matches = found
        index = restart ? (found.isEmpty ? nil : 0) : TranscriptFind.reselect(previous, was: index, in: found)
        if restart || current != previous { scrollRequest += 1 }
    }

    func step(_ by: Int) {
        index = TranscriptFind.step(from: index, by: by, count: matches.count)
        scrollRequest += 1
    }
}

/// Plain text with the find bar's matches marked.
struct FoundText: View {
    let text: String
    var field = 0
    @Environment(\.transcriptFindMarks) private var marks

    init(_ text: String, field: Int = 0) {
        self.text = text
        self.field = field
    }

    var body: some View {
        if let marks { Text(marks.mark(text, field: field)) } else { Text(text) }
    }
}
