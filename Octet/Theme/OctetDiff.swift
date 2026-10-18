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

    /// The theme's green: the terminal's own ANSI green.
    static var added: Color { Color(hex: TerminalTheme.named(SettingsStore.shared.values.themeName).ansi[2]) }

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
/// pane rather than scroll sideways.
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
            Text(DiffStyle.marker(kind))
                .font(DiffStyle.font)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: DiffStyle.rowHeight)
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
        .clipShape(shape)
    }
}

extension DiffLineRow {
    /// A line from a parsed `git diff`, numbered by the new file (the old
    /// one's for a removed line).
    init(_ line: ReviewDiff.Line, text: AttributedString? = nil, gutter: CGFloat,
         edges: (first: Bool, last: Bool), wraps: Bool = false, minWidth: CGFloat = 0) {
        self.init(kind: DiffLineKind(line.kind), number: line.newNumber ?? line.oldNumber,
                  text: text ?? AttributedString(line.text.isEmpty ? " " : line.text),
                  gutter: gutter, first: edges.first, last: edges.last, wraps: wraps, minWidth: minWidth)
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
