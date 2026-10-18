import Foundation

/// The prompts sent in a project, oldest first, for ↑ and ↓ in the
/// composer, as T3 Code's composer recalls them: the same prompt twice keeps
/// one copy at its latest place, and only the newest `limit` are kept.
struct ComposerPromptHistory: Codable, Equatable {
    static let limit = 100

    private(set) var entries: [String] = []

    init(entries: [String] = []) {
        self.entries = []
        for entry in entries { record(entry) }
    }

    /// Adds a sent prompt. Blank prompts, and the plan follow-up's own
    /// "implement this plan" message, aren't kept.
    mutating func record(_ prompt: String) {
        guard let recallable = Self.recallable(prompt) else { return }
        entries.removeAll { $0 == recallable }
        entries.append(recallable)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// What of a sent message comes back on ↑: trimmed, or nothing.
    static func recallable(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(ComposerPlanFollowUp.implementationPrefix) else { return nil }
        return trimmed
    }
}

/// Walking the history from the composer. ↑ starts on an empty composer
/// (or with the caret at the very start of a draft, which ↑ couldn't move
/// anyway), and keeps going back while the recalled prompt is unchanged and
/// the caret is on its first line. ↓ goes forward while the prompt is
/// unchanged and the caret is on its last line, and past the newest brings
/// back the draft it started from. Editing a recalled prompt makes it a new
/// draft, and the arrows move the caret again.
struct ComposerHistoryCursor: Equatable {
    /// The entry on show, counted from the oldest.
    private(set) var index: Int?
    /// The text recalled, to tell whether it has since been edited.
    private(set) var recalled: String?
    /// What the composer held before the walk began.
    private(set) var draft = ""

    enum Direction { case back, forward }

    /// Where the caret sits, in UTF-16 offsets as the text view reports it.
    struct Caret: Equatable {
        var location: Int
        var length = 0

        static let start = Caret(location: 0)
    }

    var isActive: Bool { index != nil }

    /// Takes a step, returning the text to put in the composer, or nil when
    /// the arrow should move the caret as usual.
    mutating func step(_ direction: Direction, entries: [String], text: String, caret: Caret) -> String? {
        let unchanged = index != nil && recalled == text
        if index != nil, !unchanged { reset() }
        switch direction {
        case .back:
            if let index, unchanged {
                guard Self.onFirstLine(text, caret), index > 0 else { return nil }
                return show(index - 1, entries)
            }
            let startable = text.isEmpty || (caret.location == 0 && caret.length == 0)
            guard startable, !entries.isEmpty else { return nil }
            draft = text
            return show(entries.count - 1, entries)
        case .forward:
            guard let index, unchanged, Self.onLastLine(text, caret) else { return nil }
            if index + 1 < entries.count { return show(index + 1, entries) }
            let restored = draft
            reset()
            return restored
        }
    }

    /// Forgets the walk, e.g. once a message is sent.
    mutating func reset() {
        index = nil
        recalled = nil
        draft = ""
    }

    private mutating func show(_ position: Int, _ entries: [String]) -> String? {
        guard entries.indices.contains(position) else { return nil }
        index = position
        recalled = entries[position]
        return entries[position]
    }

    /// No line break before the caret (or the start of the selection).
    static func onFirstLine(_ text: String, _ caret: Caret) -> Bool {
        let utf16 = Array(text.utf16)
        let end = min(max(0, caret.location), utf16.count)
        return !utf16[..<end].contains(10)
    }

    /// No line break after the caret (or the end of the selection).
    static func onLastLine(_ text: String, _ caret: Caret) -> Bool {
        let utf16 = Array(text.utf16)
        let start = min(max(0, caret.location + caret.length), utf16.count)
        return !utf16[start...].contains(10)
    }
}
