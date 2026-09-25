import AppKit
import SwiftUI

/// An agent's Markdown reply, drawn natively block by block.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level <= 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let ordinal, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(Self.inline(text))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            Text(Self.inline(text))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
        case .code(let language, let text):
            CodePanel(text: text, language: language)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Bold, italics, code spans and links, keeping line breaks.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
    @State private var copied = false

    static func highlighted(_ text: String) -> AttributedString {
        var state = CodeHighlighter.State()
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += CodeColors.attributed(line, state: &state)
        }
        return result
    }

    var body: some View {
        let shown = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LanguageLogo(language: language, size: 12)
                Text(language?.isEmpty == false ? language! : "text")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        OctetIcon(copied ? "checkmark" : "doc.on.doc", size: 12)
                        Text(copied ? "Copied" : "Copy").font(Theme.captionFont)
                    }
                    .foregroundStyle(copied ? Theme.accent : Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.card.opacity(0.5))
            // Pinned top-left: a two-way scroll view centers content that's
            // smaller than it.
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Group {
                        if highlights { Text(Self.highlighted(shown)) } else { Text(shown).foregroundStyle(tint) }
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
        }
        .background(Theme.terminalBackground)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

    static let rowHeight: CGFloat = 21
    private static let radius: CGFloat = 5

    var body: some View {
        let shown = Array(lines.prefix(400))
        let highlighted = Self.highlight(shown)
        let offset = (startLine ?? 1) - 1
        let digits = String((shown.compactMap(\.number).max() ?? 1) + offset).count
        let gutter = CGFloat(digits) * 8 + 20
        GeometryReader { geometry in
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
        .background(Theme.terminalBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(path.map { "Changes to \(($0 as NSString).lastPathComponent), " } ?? "")\(Self.summary(lines))")
    }

    @ViewBuilder
    private func row(_ line: LineDiff.Line, text: AttributedString, index: Int, in all: [LineDiff.Line],
                     number: Int?, gutter: CGFloat, width: CGFloat) -> some View {
        let changed = line.kind != .context
        let tint = Self.tint(line.kind)
        // Consecutive changed lines of one kind read as one block.
        let first = changed && (index == 0 || all[index - 1].kind != line.kind)
        let last = changed && (index + 1 == all.count || all[index + 1].kind != line.kind)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: first ? Self.radius : 0, bottomLeadingRadius: last ? Self.radius : 0,
            bottomTrailingRadius: last ? Self.radius : 0, topTrailingRadius: first ? Self.radius : 0
        )
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(Theme.monoFont.monospacedDigit())
                .foregroundStyle(changed ? Theme.textPrimary : Theme.textTertiary)
                .padding(.trailing, 10)
                .frame(width: gutter, height: Self.rowHeight, alignment: .trailing)
                .background(changed ? tint.opacity(0.55) : Color.clear)
            Text(Self.marker(line.kind))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 26)
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize()
                .padding(.trailing, 16)
        }
        .frame(minWidth: width, minHeight: Self.rowHeight, alignment: .leading)
        .background(changed ? tint.opacity(0.2) : Color.clear)
        .clipShape(shape)
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

    var body: some View {
        let columns = header.count
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(header[column], bold: true)
                }
            }
            .background(Theme.card)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(Theme.divider)
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < row.count ? row[column] : "", bold: false)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String, bold: Bool) -> some View {
        Text(MarkdownView.inline(text))
            .font(.system(size: 12.5, weight: bold ? .semibold : .regular))
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
