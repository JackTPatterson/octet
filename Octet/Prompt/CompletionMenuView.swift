import SwiftUI

/// The completion menu under the command line: what fits at the caret, from
/// PATH, this folder, this repo, and what you have run before.
struct CompletionMenuView: View {
    @ObservedObject var editor: PromptEditor

    var body: some View {
        OctetPalettePanel(style: .floating, divider: .none) {
            VStack(alignment: .leading, spacing: 1) {
                if editor.isSearchingHistory {
                    Text("history")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                }
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
                        .padding(4)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: editor.completionIndex) { _, index in
                        guard editor.completions.indices.contains(index) else { return }
                        proxy.scrollTo(editor.completions[index].id)
                    }
                }
            }
            .frame(width: 340, alignment: .leading)
        }
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
            Spacer(minLength: 4)
            if !completion.detail.isEmpty {
                Text(completion.detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
