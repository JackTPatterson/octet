import AppKit
import SwiftUI

/// An agent's Markdown reply, drawn natively block by block.
struct MarkdownView: View {
    let text: String
    /// Still arriving: its last code block may be cut off, so it isn't
    /// offered to run.
    var streaming = false
    /// Drawn in a conversation: T3 Code's chat type (14pt, relaxed lines)
    /// rather than the size the rest of Octet's Markdown uses.
    var chat = false
    @Environment(\.transcriptFindMarks) private var marks

    private var bodyFont: Font { chat ? ChatStyle.body : Theme.Text.transcript }
    private var bodyColor: Color { chat ? ChatStyle.prose : Theme.textPrimary }
    private var lineSpacing: CGFloat { chat ? ChatStyle.bodyLineSpacing : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: chat ? 12 : 8) {
            ForEach(Array(MarkdownCache.shared.blocks(text).enumerated()), id: \.offset) { index, block in
                blockView(block, at: index)
            }
        }
    }

    /// The words of a block, with the find bar's matches marked.
    private func inline(_ text: String, at block: Int) -> AttributedString {
        let rendered = Self.inline(text)
        return marks?.mark(rendered, field: TranscriptFind.key(block: block)) ?? rendered
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, at index: Int) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text, at: index))
                .font(bodyFont)
                .lineSpacing(lineSpacing)
                .foregroundStyle(bodyColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(inline(text, at: index))
                .font(level <= 1 ? Theme.Text.title2 : level == 2 ? Theme.Text.title3
                      : chat ? ChatStyle.bodyMedium : Theme.Text.transcriptMedium)
                .foregroundStyle(bodyColor)
                .textSelection(.enabled)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let ordinal, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(bodyFont.monospacedDigit())
                    .foregroundStyle(chat ? ChatStyle.mutedText : Theme.textTertiary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text, at: index))
                    .font(bodyFont)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(bodyColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16 + (chat ? 8 : 0))
        case .quote(let text):
            Text(inline(text, at: index))
                .font(bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
        case .code(let language, let text):
            CodePanel(text: text, language: language, findField: TranscriptFind.key(block: index),
                      runnable: streaming ? nil : ShellCodeBlock.runnable(language: language, text: text))
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, block: index)
        case .rule:
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Bold, italics, code spans and links, keeping line breaks.
    static func inline(_ text: String) -> AttributedString {
        TranscriptFind.inline(text)
    }
}

/// Monospace text in a panel: the language (or a caption) and a copy button
/// on top, horizontal scrolling for long lines, and a height that hugs short
/// content and scrolls past a limit.
struct CodePanel: View {
    /// One line of `Theme.monoFont`.
    static let lineHeight: CGFloat = 14.5
    let text: String
    var language: String?
    var tint: Color = Theme.textPrimary
    var maxLines = 18
    /// Syntax colors for code; plain tint for output and JSON.
    var highlights = true
    /// Which of the find bar's fields this panel's text is, when it is searched.
    var findField: Int?
    /// The command a shell block runs, when it can be run as it stands.
    var runnable: String?
    @Environment(\.transcriptFindMarks) private var marks
    @Environment(\.transcriptActions) private var actions
    /// Past `shownLimit` characters, the rest is a click away.
    @State private var showAll = false
    static let shownLimit = 20_000

    static func highlighted(_ text: String) -> AttributedString {
        let key = SettingsStore.shared.values.themeName + "\u{0}" + text
        if let hit = highlightCache.object(forKey: key as NSString) { return hit.value }
        var state = CodeHighlighter.State()
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += CodeColors.attributed(line, state: &state)
        }
        highlightCache.setObject(HighlightBox(result), forKey: key as NSString)
        return result
    }

    private final class HighlightBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Colored code by theme and text, so a redraw doesn't color it again.
    nonisolated(unsafe) private static let highlightCache: NSCache<NSString, HighlightBox> = {
        let cache = NSCache<NSString, HighlightBox>()
        cache.countLimit = 300
        return cache
    }()

    private func marked(_ text: AttributedString) -> AttributedString {
        guard let findField, let marks else { return text }
        return marks.mark(text, field: findField)
    }

    var body: some View {
        let cut = !showAll && text.count > Self.shownLimit
        let shown = cut ? String(text.prefix(Self.shownLimit)) : text
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LanguageLogo(language: language, size: 12)
                Text(language?.isEmpty == false ? language! : "text")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let runnable, let run = actions.runInTerminal {
                    Button { run(runnable) } label: {
                        HStack(spacing: 4) {
                            OctetIcon("terminal", size: 12)
                            Text("Run").font(Theme.Text.caption)
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Run in the focused terminal pane")
                    .accessibilityLabel("Run in terminal")
                }
                TranscriptCopyButton(text: text, label: "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.card.opacity(0.5))
            // Pinned top-left: a two-way scroll view centers content that's
            // smaller than it.
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Group {
                        if highlights { Text(marked(Self.highlighted(shown))) } else { Text(marked(AttributedString(shown))).foregroundStyle(tint) }
                    }
                        .font(Theme.monoFont)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .frame(height: CGFloat(min(lines, maxLines)) * Self.lineHeight + 16)
            if cut {
                TranscriptShowMore(title: "Show all \(text.count.formatted()) characters") { showAll = true }
            }
        }
        .background(Theme.terminalBackground)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// Syntax colors from the theme's own ANSI palette.
@MainActor
enum CodeColors {
    static func color(_ kind: CodeHighlighter.Kind) -> Color {
        let ansi = TerminalTheme.named(SettingsStore.shared.values.themeName).ansi
        switch kind {
        case .plain: return Theme.textPrimary
        case .keyword: return Color(hex: ansi[1])
        case .type: return Theme.palette.color(\.syntaxFlag)
        case .string: return Theme.palette.color(\.syntaxString)
        case .comment: return Theme.textTertiary
        case .number: return Theme.palette.color(\.syntaxVariable)
        }
    }

    static func attributed(_ line: String, state: inout CodeHighlighter.State) -> AttributedString {
        var result = AttributedString()
        for span in CodeHighlighter.highlight(line, state: &state) {
            var piece = AttributedString(span.text)
            piece.foregroundColor = color(span.kind)
            result += piece
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}

/// A file change the way code review tools draw it: line numbers, each run
/// of changed lines as one rounded, tinted block with a solid number column,
/// plain +/- markers, and syntax colors.
struct DiffView: View {
    let lines: [LineDiff.Line]
    var path: String?
    /// The file line the snippet starts at, when known.
    var startLine: Int?
    var maxLines = 24
    /// Past `shownLimit` lines, the rest is a click away.
    @State private var showAll = false
    static let shownLimit = 400

    static let rowHeight: CGFloat = 21
    private static let radius: CGFloat = 5

    var body: some View {
        let shown = showAll ? lines : Array(lines.prefix(Self.shownLimit))
        VStack(spacing: 0) {
            table(shown)
            if shown.count < lines.count {
                TranscriptShowMore(title: "Show \(lines.count - shown.count) more lines") { showAll = true }
            }
        }
        .background(ChatStyle.card)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func table(_ shown: [LineDiff.Line]) -> some View {
        let highlighted = Self.highlight(shown)
        let offset = (startLine ?? 1) - 1
        let digits = String((shown.compactMap(\.number).max() ?? 1) + offset).count
        let gutter = CGFloat(digits) * 8 + 20
        return GeometryReader { geometry in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        row(line, text: highlighted[index], index: index, in: shown,
                            number: line.number.map { $0 + offset }, gutter: gutter, width: geometry.size.width - 12)
                    }
                }
                .padding(6)
                .textSelection(.enabled)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .frame(height: CGFloat(min(shown.count, maxLines)) * Self.rowHeight + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(path.map { "Changes to \(($0 as NSString).lastPathComponent), " } ?? "")\(Self.summary(lines))")
    }

    private func row(_ line: LineDiff.Line, text: AttributedString, index: Int, in all: [LineDiff.Line],
                     number: Int?, gutter: CGFloat, width: CGFloat) -> some View {
        // Drawn as the Diff plane draws its lines, so a change reads the
        // same in the conversation as beside it.
        let edges = DiffStyle.edges(all.map { DiffLineKind($0.kind) }, at: index)
        return DiffLineRow(kind: DiffLineKind(line.kind), number: number, text: text, gutter: gutter,
                           first: edges.first, last: edges.last, minWidth: width)
            .opacity(line.kind == .context ? 0.85 : 1)
    }

    /// Syntax colors per line, carrying block-comment state down the diff.
    static func highlight(_ lines: [LineDiff.Line]) -> [AttributedString] {
        var state = CodeHighlighter.State()
        return lines.map { CodeColors.attributed($0.text, state: &state) }
    }

    static func marker(_ kind: LineDiff.Line.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: ""
        }
    }

    static func tint(_ kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: Color(hex: TerminalTheme.named(SettingsStore.shared.values.themeName).ansi[2])
        case .removed: Theme.danger
        case .context: Theme.textTertiary
        }
    }

    /// "+3 -1", for headers and VoiceOver.
    static func summary(_ lines: [LineDiff.Line]) -> String {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        return "+\(added) -\(removed)"
    }
}

/// A Markdown table: header row on a tint, rules between rows.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    /// The Markdown block this is, for the find bar's fields.
    var block = 0
    @Environment(\.transcriptFindMarks) private var marks

    var body: some View {
        let columns = header.count
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(header[column], bold: true, at: column)
                }
            }
            .background(Theme.card)
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Divider().overlay(Theme.divider)
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < row.count ? row[column] : "", bold: false, at: columns * (rowIndex + 1) + column)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String, bold: Bool, at cell: Int) -> some View {
        let rendered = MarkdownView.inline(text)
        return Text(marks?.mark(rendered, field: TranscriptFind.key(block: block, cell: cell)) ?? rendered)
            .font(bold ? Theme.Text.bodyMedium : Theme.Text.body)
            .foregroundStyle(bold ? Theme.textPrimary : Theme.textSecondary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Copy a whole message: as the Markdown the agent wrote, or as the words it
/// shows.
struct MessageCopyMenu: View {
    let text: String

    var body: some View {
        Button("Copy as Markdown") { copy(text, "Copied the message as Markdown") }
        Button("Copy as Plain Text") { copy(MarkdownPlain.plain(text), "Copied the message as plain text") }
    }

    private func copy(_ value: String, _ title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardWatcher.shared.acknowledge()
        ToastCenter.shared.info(title, detail: ClipboardPreview.summary(value))
    }
}

/// The transcript's one copy control: the icon turns into a check for a
/// moment once it's copied, with nothing else said.
struct TranscriptCopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            motion.perform(.palette, .easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                motion.perform(.palette, .easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            OctetIcon(copied ? "checkmark" : "doc.on.doc", size: 12)
                .foregroundStyle(copied ? ChatStyle.primary : Theme.textTertiary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : label)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

/// Under a cut-off panel: the rest of it, on request.
struct TranscriptShowMore: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                OctetIcon("chevron.down", size: 11)
                Text(title).font(Theme.Text.caption)
            }
            .foregroundStyle(ChatStyle.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Theme.card.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
