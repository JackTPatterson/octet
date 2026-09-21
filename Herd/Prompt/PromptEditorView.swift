import SwiftUI

/// Herd's command line, drawn over the shell's prompt in the terminal's own
/// font: the text highlighted as a shell reads it, the history suggestion
/// greyed out after the caret, and a caret of Herd's own.
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
            // The line is one run of text; the caret is drawn over it at its
            // column rather than placed between views, so blinking and moving
            // it never change the layout.
            ZStack(alignment: .topLeading) {
                Theme.terminalBackground
                (highlighted + ghostText)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: max(1.5, anchor.cellWidth * 0.12), height: anchor.cellHeight)
                    .opacity(caretVisible ? 1 : 0)
                    .offset(x: CGFloat(editor.line.caret) * anchor.cellWidth)
            }
            .frame(height: anchor.cellHeight, alignment: .topLeading)
            .onAppear { blink() }
        }
    }

    /// The typed text, coloured the way a shell reads it. The gaps between
    /// tokens are kept, so spacing matches what will be sent.
    private var highlighted: Text {
        let text = editor.line.text
        var rendered = Text("")
        var cursor = text.startIndex
        for span in ShellSyntax.spans(in: text) {
            if cursor < span.range.lowerBound {
                rendered = rendered + Text(String(text[cursor..<span.range.lowerBound]))
            }
            rendered = rendered + Text(String(text[span.range])).foregroundStyle(color(for: span.role))
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex {
            rendered = rendered + Text(String(text[cursor...]))
        }
        return rendered
    }

    /// The completion after the caret, greyed out; empty when there is none.
    private var ghostText: Text {
        guard let suggestion = editor.suggestion, suggestion.hasPrefix(editor.line.text) else { return Text("") }
        return Text(String(suggestion.dropFirst(editor.line.text.count))).foregroundStyle(Theme.textTertiary)
    }

    private func color(for role: ShellSyntax.Role) -> Color {
        switch role {
        case .command: Theme.accent
        case .builtin: Theme.palette.color(\.syntaxBuiltin)
        case .flag: Theme.palette.color(\.syntaxFlag)
        case .string: Theme.palette.color(\.syntaxString)
        case .path: Theme.palette.color(\.syntaxPath)
        case .variable: Theme.palette.color(\.syntaxVariable)
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
