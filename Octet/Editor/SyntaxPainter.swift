import AppKit

/// Colours a text storage with CodeHighlighter, a line at a time, so an edit
/// repaints the lines it touched and the ones after it only until the
/// highlighter's state (an open block comment) is back to what it was,
/// rather than the whole document on every keystroke.
///
/// Each line remembers the state it ended in as an attribute on its own
/// characters; the text system carries that along through edits, so the
/// line before an edit still knows how the edited one starts.
@MainActor
struct SyntaxPainter {
    /// The highlighter's state at the end of the line holding the character.
    static let endStateKey = NSAttributedString.Key("octet.syntaxEndState")

    var font: NSFont
    var palette: ThemePalette

    /// Paints every line.
    func paintAll(_ storage: NSTextStorage) {
        paint(storage, edited: NSRange(location: 0, length: storage.length))
    }

    /// Paints from the start of the line holding `edited.location` until
    /// past `edited` and the state settles. Returns what it painted.
    @discardableResult
    func paint(_ storage: NSTextStorage, edited: NSRange) -> NSRange {
        let text = storage.string as NSString
        let length = text.length
        let editedEnd = min(NSMaxRange(edited), length)
        var location = text.lineRange(for: NSRange(location: min(edited.location, length), length: 0)).location
        let start = location
        var state = location > 0 ? Self.state(in: storage, at: location - 1) ?? CodeHighlighter.State() : CodeHighlighter.State()
        let plain = palette.nsColor(\.textPrimary)

        storage.beginEditing()
        defer { storage.endEditing() }
        while location < length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: location, length: 0))
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            // What this line ended in before the edit, to know when to stop.
            let previous = Self.state(in: storage, at: max(lineStart, lineEnd - 1))

            storage.setAttributes([.font: font, .foregroundColor: plain], range: lineRange)
            // The line's text without its ending, so "\r\n" can't shift the
            // colours that follow it.
            let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            var offset = lineStart
            for span in CodeHighlighter.highlight(line, state: &state) {
                let spanLength = (span.text as NSString).length
                if span.kind != .plain {
                    storage.addAttribute(.foregroundColor, value: color(span.kind),
                                         range: NSRange(location: offset, length: spanLength))
                }
                offset += spanLength
            }
            if lineRange.length > 0 {
                storage.addAttribute(Self.endStateKey, value: Self.encode(state), range: lineRange)
            }
            location = lineEnd
            if lineEnd <= lineStart { break }
            if lineEnd >= editedEnd, previous == state { break }
        }
        return NSRange(location: start, length: location - start)
    }

    private func color(_ kind: CodeHighlighter.Kind) -> NSColor {
        switch kind {
        case .plain: palette.nsColor(\.textPrimary)
        case .keyword: palette.nsColor(\.syntaxFlag)
        case .type: palette.nsColor(\.syntaxBuiltin)
        case .string: palette.nsColor(\.syntaxString)
        case .comment: palette.nsColor(\.textTertiary)
        case .number: palette.nsColor(\.syntaxVariable)
        }
    }

    // The state is one flag today; kept as a number so another field can
    // join it without changing how lines store it.
    private static func encode(_ state: CodeHighlighter.State) -> NSNumber {
        NSNumber(value: state.inBlockComment ? 1 : 0)
    }

    private static func state(in storage: NSTextStorage, at index: Int) -> CodeHighlighter.State? {
        guard index >= 0, index < storage.length,
              let value = storage.attribute(endStateKey, at: index, effectiveRange: nil) as? NSNumber else { return nil }
        return CodeHighlighter.State(inBlockComment: value.intValue & 1 == 1)
    }
}
