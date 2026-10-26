import SwiftUI

/// Octet's command line, drawn over the shell's prompt in the terminal's own
/// font: the text highlighted as a shell reads it, the history suggestion
/// greyed out after the caret, and a caret of Octet's own.
struct PromptEditorView: View {
    @ObservedObject var editor: PromptEditor
    @ObservedObject private var settings = SettingsStore.shared
    @State private var caretVisible = true

    var body: some View {
        if editor.isActive, let anchor = editor.anchor {
            // Match the terminal's own font so the line sits on the grid.
            let font = TerminalLook.font()
            // Every character in its own cell (two for a wide one), so the
            // line sits on the terminal's grid whatever the font's glyph
            // widths, and the caret lands between the right characters.
            let cells = self.cells
            let caretColumn = CellWidth.columns(editor.line.text, upTo: editor.line.caret)
            let width = max(1, anchor.columnsRemaining)
            // Longer than the pane: scroll so the caret stays in view.
            let shift = max(0, caretColumn - width + 1)
            ZStack(alignment: .topLeading) {
                Theme.terminalBackground
                // A selection (⌘A, shift-arrows) shows behind its characters.
                if let selection = editor.line.selection {
                    let from = CellWidth.columns(editor.line.text, upTo: selection.lowerBound)
                    let to = CellWidth.columns(editor.line.text, upTo: selection.upperBound)
                    Rectangle()
                        .fill(Theme.accent.opacity(0.35))
                        .frame(width: CGFloat(to - from) * anchor.cellWidth, height: anchor.cellHeight)
                        .offset(x: CGFloat(from - shift) * anchor.cellWidth)
                }
                // Only what's on screen: a long paste or a line wider than the
                // pane would otherwise make a view for every character.
                ForEach(cells.indices.filter { cells[$0].column + cells[$0].width > shift && cells[$0].column <= shift + width },
                        id: \.self) { index in
                    let cell = cells[index]
                    Text(String(cell.character))
                        .font(font)
                        .foregroundStyle(cell.color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: CGFloat(cell.width) * anchor.cellWidth, height: anchor.cellHeight)
                        .offset(x: CGFloat(cell.column - shift) * anchor.cellWidth)
                }
                caret(anchor)
                    .opacity(caretVisible ? 1 : 0)
                    .offset(x: CGFloat(caretColumn - shift) * anchor.cellWidth)
            }
            .frame(height: anchor.cellHeight, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // One element for VoiceOver, not one per character: the line as
            // its value, the suggestion as a hint.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Command line")
            .accessibilityValue(editor.line.text)
            .accessibilityHint(suggestionHint)
            .accessibilityAddTraits(.updatesFrequently)
            // A click puts the caret under the pointer.
            .onTapGesture(coordinateSpace: .local) { point in
                let column = Int(point.x / max(anchor.cellWidth, 1)) + shift
                var index = 0, at = 0
                for character in editor.line.text {
                    let next = at + CellWidth.of(character)
                    if column < next { break }
                    at = next
                    index += 1
                }
                editor.moveCaret(to: index)
            }
            .onAppear { blink() }
        }
    }

    /// The caret in the terminal's own cursor colour and shape, so the line
    /// reads as the terminal's: a bar is a bar, an underline an underline,
    /// and a block a see-through cell so the character under it still shows.
    @ViewBuilder
    private func caret(_ anchor: OctetTerminalRuntime.CursorAnchor) -> some View {
        let color = TerminalLook.cursorColor
        switch settings.values.cursorStyle {
        case .block:
            Rectangle().fill(color.opacity(0.45))
                .frame(width: anchor.cellWidth, height: anchor.cellHeight)
        case .underline:
            Rectangle().fill(color)
                .frame(width: anchor.cellWidth, height: max(1.5, anchor.cellHeight * 0.1))
                .frame(height: anchor.cellHeight, alignment: .bottom)
        case .bar:
            Rectangle().fill(color)
                .frame(width: max(1.5, anchor.cellWidth * 0.12), height: anchor.cellHeight)
        }
    }

    private var suggestionHint: String {
        guard let suggestion = editor.suggestion, suggestion.hasPrefix(editor.line.text),
              suggestion.count > editor.line.text.count else { return "" }
        return "Suggests \(suggestion). Right arrow accepts it."
    }

    private struct Cell {
        let character: Character
        let color: Color
        let column: Int
        let width: Int
    }

    /// The typed text coloured the way a shell reads it, then the history
    /// suggestion greyed out, laid out in cells.
    private var cells: [Cell] {
        let text = editor.line.text
        var colors = Array(repeating: Theme.textPrimary, count: text.count)
        // Walk the spans in order, so each one's position costs only the
        // distance from the last, not from the start of the line.
        var cursor = text.startIndex
        var offset = 0
        for span in ShellSyntax.spans(in: text) {
            let from = offset + text.distance(from: cursor, to: span.range.lowerBound)
            let to = from + text.distance(from: span.range.lowerBound, to: span.range.upperBound)
            cursor = span.range.upperBound
            offset = to
            var color = span.role.color()
            // A command the shell won't find, once it's finished being typed
            // (not while the word is still at the caret), as a shell's own
            // highlighter shows it.
            if span.role == .command {
                let word = String(text[span.range])
                let stillTyping = span.range.upperBound == text.endIndex && editor.line.caretAtEnd
                if !stillTyping, editor.isUnknownCommand(word) { color = Theme.danger }
            }
            for index in from..<min(to, colors.count) { colors[index] = color }
        }
        var result: [Cell] = []
        var column = 0
        for (index, character) in text.enumerated() {
            let width = CellWidth.of(character)
            result.append(Cell(character: character, color: colors[index], column: column, width: width))
            column += width
        }
        if let suggestion = editor.suggestion, suggestion.hasPrefix(text) {
            for character in suggestion.dropFirst(text.count) {
                let width = CellWidth.of(character)
                result.append(Cell(character: character, color: Theme.textTertiary, column: column, width: width))
                column += width
            }
        }
        return result
    }

    private func blink() {
        guard MotionPreferences.shared.animates(.agentStatus) else { return }
        Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard editor.isActive else {
                    caretVisible = true
                    timer.invalidate()
                    return
                }
                caretVisible.toggle()
            }
        }
    }
}
