import Foundation

/// The command line Octet edits while a pane sits at a shell prompt: the text,
/// where the caret is, and every edit a shell's own line editor offers. Kept
/// free of AppKit so the editing rules can be tested directly.
struct PromptLine: Equatable {
    private(set) var text: String = ""
    /// Caret position as an offset in characters, 0...text.count.
    private(set) var caret: Int = 0
    /// Commands stepped through with the up arrow.
    private var historyCursor: Int?
    private var draftBeforeHistory: String?
    /// Where a shift-selection started; nil when nothing is selected.
    private(set) var selectionAnchor: Int?
    /// One step of the undo trail; a struct so the line stays Equatable.
    private struct Snapshot: Equatable {
        let text: String
        let caret: Int
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private static let undoLimit = 100

    init(text: String = "", caret: Int? = nil) {
        self.text = text
        self.caret = caret ?? text.count
    }

    var isEmpty: Bool { text.isEmpty }
    var caretAtEnd: Bool { caret >= text.count }

    /// Preserve multiline input when handing the editor back to the shell.
    /// Bracketed paste prevents a focus change or Tab from submitting newlines.
    func shellInput(trailing: String = "", restoreCaret: Bool = false) -> String {
        let content = text.contains("\n") || text.contains("\r") || text.contains("\t")
            ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        let moves = restoreCaret ? String(repeating: "\u{1b}[D", count: max(0, text.count - caret)) : ""
        return content + moves + trailing
    }

    /// Pasted escape/control bytes must not become terminal instructions on flush.
    static func pastedText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(normalized.unicodeScalars.filter {
            // Unicode format characters (such as emoji ZWJ) are not terminal controls.
            !($0.value < 0x20 || (0x7f...0x9f).contains($0.value)) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .newlines)
    }

    /// The selected span, if any, as character offsets.
    var selection: Range<Int>? {
        guard let anchor = selectionAnchor, anchor != caret else { return nil }
        return min(anchor, caret)..<max(anchor, caret)
    }

    var selectedText: String? {
        selection.map { String(Array(text)[$0]) }
    }

    /// Records the line so the next edit can be undone.
    private mutating func checkpoint() {
        undoStack.append(Snapshot(text: text, caret: caret))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(text: text, caret: caret))
        text = previous.text
        caret = min(previous.caret, text.count)
        selectionAnchor = nil
        forgetHistory()
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(text: text, caret: caret))
        text = next.text
        caret = min(next.caret, text.count)
        selectionAnchor = nil
        forgetHistory()
    }

    /// Replaces the selection, if there is one. True when it removed text.
    @discardableResult
    mutating func deleteSelection() -> Bool {
        guard let range = selection else { return false }
        checkpoint()
        text.removeSubrange(characterIndex(range.lowerBound)..<characterIndex(range.upperBound))
        caret = range.lowerBound
        selectionAnchor = nil
        forgetHistory()
        return true
    }

    mutating func selectAll() {
        selectionAnchor = 0
        caret = text.count
    }

    mutating func clearSelection() { selectionAnchor = nil }

    /// Starts or extends a selection around a caret move.
    mutating func extendingSelection(_ move: (inout PromptLine) -> Void) {
        if selectionAnchor == nil { selectionAnchor = caret }
        move(&self)
    }

    // MARK: - Editing

    mutating func insert(_ string: String) {
        if selection != nil {
            deleteSelection()
        } else {
            checkpoint()
        }
        let index = characterIndex(caret)
        text.insert(contentsOf: string, at: index)
        caret += string.count
        forgetHistory()
    }

    mutating func deleteBackward() {
        if deleteSelection() { return }
        guard caret > 0 else { return }
        checkpoint()
        text.remove(at: characterIndex(caret - 1))
        caret -= 1
        forgetHistory()
    }

    mutating func deleteForward() {
        if deleteSelection() { return }
        guard caret < text.count else { return }
        checkpoint()
        text.remove(at: characterIndex(caret))
        forgetHistory()
    }

    /// ⌥⌫ / ⌃W: remove the word before the caret, and the spaces it sits on.
    mutating func deleteWordBackward() {
        if deleteSelection() { return }
        guard caret > 0 else { return }
        checkpoint()
        var index = caret
        while index > 0, character(at: index - 1) == " " { index -= 1 }
        while index > 0, character(at: index - 1) != " " { index -= 1 }
        text.removeSubrange(characterIndex(index)..<characterIndex(caret))
        caret = index
        forgetHistory()
    }

    /// ⌃U: clear to the start of the line.
    mutating func deleteToStart() {
        checkpoint()
        text.removeSubrange(text.startIndex..<characterIndex(caret))
        caret = 0
        forgetHistory()
    }

    /// ⌃K: clear to the end of the line.
    mutating func deleteToEnd() {
        checkpoint()
        text.removeSubrange(characterIndex(caret)..<text.endIndex)
        forgetHistory()
    }

    mutating func clear() {
        checkpoint()
        text = ""
        caret = 0
        forgetHistory()
    }

    // MARK: - Moving

    mutating func moveLeft() { caret = max(0, caret - 1) }
    mutating func moveRight() { caret = min(text.count, caret + 1) }
    mutating func moveToStart() { caret = 0 }
    /// Puts the caret before character `index` (a click on the line).
    mutating func moveCaret(to index: Int) {
        caret = min(max(0, index), text.count)
        selectionAnchor = nil
    }
    mutating func moveToEnd() { caret = text.count }

    /// Replaces the word under the caret, for accepting a completion.
    mutating func replace(range: Range<Int>, with value: String) {
        checkpoint()
        let lower = characterIndex(range.lowerBound)
        let upper = characterIndex(min(range.upperBound, text.count))
        text.replaceSubrange(lower..<upper, with: value)
        caret = range.lowerBound + value.count
        selectionAnchor = nil
        forgetHistory()
    }

    mutating func moveWordLeft() {
        var index = caret
        while index > 0, character(at: index - 1) == " " { index -= 1 }
        while index > 0, character(at: index - 1) != " " { index -= 1 }
        caret = index
    }

    mutating func moveWordRight() {
        var index = caret
        while index < text.count, character(at: index) == " " { index += 1 }
        while index < text.count, character(at: index) != " " { index += 1 }
        caret = index
    }

    // MARK: - History and suggestions

    /// Accepts the greyed-out completion, if the caret is at the end.
    mutating func accept(suggestion: String?) -> Bool {
        guard let suggestion, caretAtEnd, suggestion.hasPrefix(text), suggestion != text else { return false }
        text = suggestion
        caret = text.count
        forgetHistory()
        return true
    }

    /// Accepts one word of the completion, the way ⌥→ does in a shell.
    mutating func acceptWord(of suggestion: String?) -> Bool {
        guard let suggestion, caretAtEnd, suggestion.hasPrefix(text), suggestion != text else { return false }
        let rest = Array(suggestion)[text.count...]
        var taken = 0
        var seenWord = false
        for character in rest {
            if character == " " {
                // Take the space that ends the word too, so typing carries on
                // from the next one.
                if seenWord {
                    taken += 1
                    break
                }
            } else {
                seenWord = true
            }
            taken += 1
        }
        text = String(Array(suggestion)[0..<(text.count + taken)])
        caret = text.count
        forgetHistory()
        return true
    }

    /// ↑ / ↓ through the commands that match what has been typed so far.
    mutating func stepHistory(_ direction: Int, matches: [String]) {
        guard !matches.isEmpty else { return }
        if historyCursor == nil {
            guard direction > 0 else { return }
            draftBeforeHistory = text
            historyCursor = -1
        }
        let next = (historyCursor ?? -1) + direction
        if next < 0 {
            // Back past the newest entry: whatever was being typed returns.
            text = draftBeforeHistory ?? ""
            caret = text.count
            forgetHistory()
            return
        }
        let index = min(next, matches.count - 1)
        historyCursor = index
        text = matches[index]
        caret = text.count
    }

    /// True while the line is showing a history entry rather than typing.
    var isBrowsingHistory: Bool { historyCursor != nil }

    private mutating func forgetHistory() {
        historyCursor = nil
        draftBeforeHistory = nil
    }

    // MARK: - Helpers

    private func characterIndex(_ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
    }

    private func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < text.count else { return nil }
        return text[characterIndex(offset)]
    }
}
