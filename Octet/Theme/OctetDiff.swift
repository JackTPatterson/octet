import SwiftUI

/// Octet's one way of drawing a changed line, used wherever a diff shows:
/// conversations, the review, the Diff plane and pull requests. Each run of
/// changed lines reads as one rounded, tinted block with a solid number
/// column, plain +/- markers and syntax colours, in the theme's own green
/// and red.
enum DiffLineKind: Equatable {
    case context, added, removed

    init(_ kind: ReviewDiff.Line.Kind) {
        switch kind {
        case .context: self = .context
        case .added: self = .added
        case .removed: self = .removed
        }
    }

    init(_ kind: LineDiff.Line.Kind) {
        switch kind {
        case .context: self = .context
        case .added: self = .added
        case .removed: self = .removed
        }
    }
}

@MainActor
enum DiffStyle {
    static let rowHeight: CGFloat = 21
    static let radius: CGFloat = 5
    static let font = Font.system(size: 12.5, design: .monospaced)

    /// The theme's success green, the same one the file marks use.
    static var added: Color { Theme.success }

    static func tint(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: added
        case .removed: Theme.danger
        case .context: Theme.textTertiary
        }
    }

    static func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: ""
        }
    }

    /// Wide enough for the biggest line number.
    nonisolated static func gutterWidth(maxNumber: Int) -> CGFloat {
        CGFloat(String(max(1, maxNumber)).count) * 8 + 20
    }

    /// Whether line `index` opens and closes a run of changed lines, so the
    /// run's block rounds only its outer corners: a removed line sitting
    /// right above an added one meets it flush, with no notch between.
    nonisolated static func edges(_ kinds: [DiffLineKind], at index: Int) -> (first: Bool, last: Bool) {
        guard kinds[index] != .context else { return (false, false) }
        return (index == 0 || kinds[index - 1] == .context, index + 1 == kinds.count || kinds[index + 1] == .context)
    }
}

/// One diff line in Octet's style. `wraps` lets long lines wrap in a narrow
/// pane rather than scroll sideways. The one renderer every diff uses, in
/// one column or as a side of the split view.
struct DiffLineRow: View {
    let kind: DiffLineKind
    let number: Int?
    let text: AttributedString
    let gutter: CGFloat
    var first = false
    var last = false
    var wraps = false
    /// Rows span at least this wide, so a short line's tint reads as the
    /// whole line in a pane that scrolls sideways.
    var minWidth: CGFloat = 0
    /// No marker column: the split view's sides say which is which.
    var showsMarker = true
    /// Shift-click selection for a note on several lines.
    var selected = false

    var body: some View {
        let changed = kind != .context
        let tint = DiffStyle.tint(kind)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: first ? DiffStyle.radius : 0, bottomLeadingRadius: last ? DiffStyle.radius : 0,
            bottomTrailingRadius: last ? DiffStyle.radius : 0, topTrailingRadius: first ? DiffStyle.radius : 0
        )
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(Theme.monoFont.monospacedDigit())
                .foregroundStyle(changed ? Theme.textPrimary : Theme.textTertiary)
                .padding(.trailing, 10)
                .frame(width: gutter, alignment: .trailing)
                .frame(minHeight: DiffStyle.rowHeight)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(changed ? tint.opacity(0.55) : Color.clear)
            if showsMarker {
                Text(DiffStyle.marker(kind))
                    .font(DiffStyle.font)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 26, height: DiffStyle.rowHeight)
            } else {
                Spacer().frame(width: 8)
            }
            Group {
                if wraps {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text).fixedSize()
                }
            }
            .font(DiffStyle.font)
            .padding(.vertical, 2)
            .padding(.trailing, 16)
        }
        .frame(minWidth: minWidth, minHeight: DiffStyle.rowHeight, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(changed ? tint.opacity(0.2) : Color.clear)
        .overlay { if selected { Theme.accent.opacity(0.16) } }
        .clipShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(kind: kind, number: number, text: text))
    }

    static func accessibilityText(kind: DiffLineKind, number: Int?, text: AttributedString) -> String {
        let what = kind == .added ? "Added" : kind == .removed ? "Removed" : "Line"
        return "\(what)\(number.map { " \($0)" } ?? ""): \(String(text.characters))"
    }
}

/// One row of the side-by-side view: the old file's line on the left and
/// the new one's on the right, each drawn as `DiffLineRow` draws it and
/// wrapping, so a long line is never clipped. A side with nothing reads as
/// an empty, faintly filled cell.
struct DiffSplitLineRow: View {
    let pair: ReviewDiff.Hunk.Pair
    let colors: DiffFileColors
    let gutter: CGFloat
    /// The edges of each side's run of changes, for its corners.
    var leftEdges: (first: Bool, last: Bool) = (false, false)
    var rightEdges: (first: Bool, last: Bool) = (false, false)
    var isSelected: (ReviewDiff.Line) -> Bool = { _ in false }
    /// A click on a side's line; nil leaves the rows inert.
    var tap: ((ReviewDiff.Line) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(pair.left, number: pair.left?.oldNumber, edges: leftEdges)
            Rectangle().fill(Theme.divider).frame(width: 1)
            side(pair.right, number: pair.right?.newNumber, edges: rightEdges)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func side(_ line: ReviewDiff.Line?, number: Int?, edges: (first: Bool, last: Bool)) -> some View {
        if let line {
            let row = DiffLineRow(kind: DiffLineKind(line.kind), number: number, text: colors.text(line),
                                  gutter: gutter, first: edges.first, last: edges.last, wraps: true,
                                  showsMarker: false, selected: isSelected(line))
                .opacity(line.kind == .context ? 0.85 : 1)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let tap {
                DiffHoverTap(help: "Leave a note on this line") { tap(line) } label: { row }
            } else {
                row
            }
        } else {
            Theme.card.opacity(0.5)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: DiffStyle.rowHeight, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }
}

/// A clickable diff line with the hover wash and a note mark, shared by
/// the unified and split rows.
struct DiffHoverTap<Label: View>: View {
    let help: String
    var showsMark = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .background { if hovered { Theme.hover } }
                .overlay(alignment: .leading) {
                    if hovered && showsMark {
                        OctetIcon("text.bubble", size: 11).foregroundStyle(Theme.accent).padding(.leading, 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// A file's lines with their syntax colours, carried down the file across
/// hunks, and the words that changed inside each edited line marked in
/// the line's own tint. Kept per file so scrolling and refreshes reuse it.
struct DiffFileColors {
    private let lines: [Int: AttributedString]

    func text(_ line: ReviewDiff.Line) -> AttributedString {
        lines[line.index] ?? AttributedString(line.text.isEmpty ? " " : line.text)
    }

    subscript(index: Int) -> AttributedString? { lines[index] }

    @MainActor
    init(_ file: ReviewDiff.File) {
        let spans = file.syntaxSpans()
        var changed: [Int: [Range<Int>]] = [:]
        for hunk in file.hunks { changed.merge(IntralineDiff.ranges(in: hunk)) { $1 } }
        var result: [Int: AttributedString] = [:]
        for hunk in file.hunks {
            for line in hunk.lines {
                var text = AttributedString()
                for span in spans[line.index] ?? [] {
                    var piece = AttributedString(span.text)
                    piece.foregroundColor = CodeColors.color(span.kind)
                    text += piece
                }
                if let ranges = changed[line.index] {
                    let tint = DiffStyle.tint(DiffLineKind(line.kind)).opacity(0.38)
                    for range in ranges {
                        let characters = text.characters
                        guard range.upperBound <= characters.count else { continue }
                        let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
                        let upper = characters.index(lower, offsetBy: range.count)
                        text[lower..<upper].backgroundColor = tint
                    }
                }
                result[line.index] = text.characters.isEmpty ? AttributedString(" ") : text
            }
        }
        lines = result
    }

    /// The colours for `file`, worked out once per version of it and theme.
    @MainActor
    static func of(_ file: ReviewDiff.File) -> DiffFileColors { DiffColorCache.shared.colors(for: file) }
}

/// Recent files' colours. A refresh hands back equal files, which compare
/// far faster than they colour; a theme change starts over.
@MainActor
final class DiffColorCache {
    static let shared = DiffColorCache()
    private var entries: [String: (file: ReviewDiff.File, colors: DiffFileColors)] = [:]
    private var order: [String] = []
    private var theme = ""
    private let limit = 300

    func colors(for file: ReviewDiff.File) -> DiffFileColors {
        let current = SettingsStore.shared.values.themeName
        if current != theme { entries = [:]; order = []; theme = current }
        if let entry = entries[file.path], entry.file == file { return entry.colors }
        let colors = DiffFileColors(file)
        if entries[file.path] == nil { order.append(file.path) }
        entries[file.path] = (file, colors)
        if order.count > limit {
            let dropped = order.removeFirst()
            entries[dropped] = nil
        }
        return colors
    }
}

/// A changed file's mark in the theme's tones.
extension ChangeMark {
    @MainActor var color: Color {
        switch tone {
        case .success: Theme.success
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }
}

/// The one changed-file row: status letter in its tone, the name, its
/// folder truncated in the middle, and +/- counts, with room for each
/// list's own extras (who edited it, notes, Viewed, hover actions). Used
/// by the Git panel, the Diff plane, the review and pull requests.
struct DiffFileRow<Leading: View, Trailing: View>: View {
    let path: String
    let mark: ChangeMark
    let added: Int?
    let removed: Int?
    var binary = false
    var emphasized = true
    /// A file several folders deep keeps its name and loses the middle of
    /// its folder first.
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading()
            Text(mark.letter)
                .font(Theme.Text.mono(10, weight: .bold))
                .foregroundStyle(mark.color)
                .frame(width: 10)
                .help(mark.name)
                .accessibilityHidden(true)
            Text((path as NSString).lastPathComponent)
                .font(emphasized ? Theme.uiFontMedium : Theme.uiFont)
                .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(path), \(mark.name.lowercased())")
    }
}

/// The +/- counts at a file row's end, or "bin" for a binary file.
struct DiffFileCounts: View {
    let added: Int?
    let removed: Int?
    var binary = false

    var body: some View {
        if binary {
            Text("bin").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
        } else {
            DiffStatLabel(added: added ?? 0, removed: removed ?? 0).fixedSize()
        }
    }
}

extension DiffFileRow where Leading == EmptyView {
    init(path: String, mark: ChangeMark, added: Int?, removed: Int?, binary: Bool = false, emphasized: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(path: path, mark: mark, added: added, removed: removed, binary: binary, emphasized: emphasized,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

/// A folded file's reason and the way to open it anyway: "Lockfile ·
/// Show diff".
struct DiffCollapsedNote: View {
    let reason: DiffCollapse
    let show: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(reason.title())
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Text(reason == .lockfile || reason == .generated ? "Folded: a tool writes this file." : "Folded: too long to read here.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            OctetButton(title: "Show diff", kind: .ghost, compact: true, action: show)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

extension DiffLineRow {
    /// A line from a parsed `git diff`, numbered by the new file (the old
    /// one's for a removed line).
    init(_ line: ReviewDiff.Line, text: AttributedString? = nil, gutter: CGFloat,
         edges: (first: Bool, last: Bool), wraps: Bool = false, minWidth: CGFloat = 0, selected: Bool = false) {
        self.init(kind: DiffLineKind(line.kind), number: line.newNumber ?? line.oldNumber,
                  text: text ?? AttributedString(line.text.isEmpty ? " " : line.text),
                  gutter: gutter, first: edges.first, last: edges.last, wraps: wraps, minWidth: minWidth,
                  selected: selected)
    }
}

extension ReviewDiff.Hunk {
    /// The kinds of its lines, for `DiffStyle.edges`.
    var lineKinds: [DiffLineKind] { lines.map { DiffLineKind($0.kind) } }
}

extension ReviewDiff.File {
    /// The gutter for this file's biggest line number.
    var gutterWidth: CGFloat {
        DiffStyle.gutterWidth(maxNumber: hunks.flatMap(\.lines).map(\.number).max() ?? 1)
    }
}
