import SwiftUI

/// The completion menu under the command line: what fits at the caret, from
/// PATH, this folder, this repo, and what you have run before. As wide as
/// its entries need, within `maxWidth`; while Tab's values are still on
/// their way, a loading row in their place, and "No completions" when none
/// came.
struct CompletionMenuView: View {
    @ObservedObject var editor: PromptEditor
    /// Room to the window's edge from where the menu starts.
    var maxWidth: CGFloat = Self.widest

    static let narrowest: CGFloat = 220
    static let widest: CGFloat = 440

    var body: some View {
        OctetPalettePanel(style: .floating, divider: .none) {
            VStack(alignment: .leading, spacing: 1) {
                if editor.isSearchingHistory {
                    Text("History".uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.top, Theme.Space.sm)
                }
                if editor.completionsOpen {
                    list
                } else if let notice = editor.completionNotice {
                    noticeRow(notice)
                }
            }
            .frame(minWidth: min(Self.narrowest, maxWidth), maxWidth: max(Self.narrowest, min(Self.widest, maxWidth)),
                   alignment: .leading)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                OctetAnimatedList(items: editor.completions,
                                  highlighted: editor.completionIndex,
                                  horizontalPadding: 7,
                                  verticalPadding: 3,
                                  highlight: { editor.selectCompletion($0) },
                                  choose: { completion in
                                      guard let index = editor.completions.firstIndex(where: { $0.id == completion.id }) else { return }
                                      editor.selectCompletion(index)
                                      editor.acceptCompletion()
                                  }) { completion, selected in
                    CompletionRow(completion: completion, selected: selected)
                }
                .padding(Theme.Space.xs)
            }
            .frame(maxHeight: 220)
            .onChange(of: editor.completionIndex) { _, index in
                guard editor.completions.indices.contains(index) else { return }
                proxy.scrollTo(editor.completions[index].id)
            }
        }
    }

    private func noticeRow(_ notice: PromptEditor.CompletionNotice) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if notice == .loading { LoadingLine(width: 16) }
            Text(notice == .loading ? "Loading completions…" : "No completions")
                .font(Theme.Text.body)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.md + 3)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}

private struct CompletionRow: View {
    let completion: Completion
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            OctetIcon(completion.kind.symbol, size: 12)
                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                .frame(width: 12)
            Text(completion.shown)
                .font(Theme.monoFont)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            if !completion.detail.isEmpty {
                Text(completion.detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}
