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
            let family = settings.values.fontFamily
            let font = family.isEmpty
                ? Font.system(size: settings.values.fontSize, design: .monospaced)
                : Font.custom(family, fixedSize: settings.values.fontSize)
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
                ForEach(cells.indices, id: \.self) { index in
                    let cell = cells[index]
                    Text(String(cell.character))
                        .font(font)
                        .foregroundStyle(cell.color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: CGFloat(cell.width) * anchor.cellWidth, height: anchor.cellHeight)
                        .offset(x: CGFloat(cell.column - shift) * anchor.cellWidth)
                }
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: max(1.5, anchor.cellWidth * 0.12), height: anchor.cellHeight)
                    .opacity(caretVisible ? 1 : 0)
                    .offset(x: CGFloat(caretColumn - shift) * anchor.cellWidth)
            }
            .frame(height: anchor.cellHeight, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
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
        for span in ShellSyntax.spans(in: text) {
            let from = text.distance(from: text.startIndex, to: span.range.lowerBound)
            let to = text.distance(from: text.startIndex, to: span.range.upperBound)
            for index in from..<min(to, colors.count) { colors[index] = color(for: span.role) }
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

    private func color(for role: ShellSyntax.Role) -> Color {
        switch role {
        case .command: Theme.accent
        case .builtin: Theme.palette.color(\.syntaxBuiltin)
        case .flag: Theme.palette.color(\.syntaxFlag)
        case .string: Theme.palette.color(\.syntaxString)
        case .path: Theme.palette.color(\.syntaxPath)
        case .variable: Theme.palette.color(\.syntaxVariable)
        case .assignment: Theme.palette.color(\.syntaxVariable)
        case .reserved: Theme.palette.color(\.syntaxBuiltin)
        case .expansion: Theme.palette.color(\.syntaxVariable)
        case .glob: Theme.palette.color(\.syntaxPath)
        case .redirect, .separator: Theme.textSecondary
        case .comment: Theme.textTertiary
        case .argument: Theme.textPrimary
        }
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
