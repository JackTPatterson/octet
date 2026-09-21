import SwiftUI

/// The completion menu under the command line: what fits at the caret, from
/// PATH, this folder, this repo, and what you have run before.
struct CompletionMenuView: View {
    @ObservedObject var editor: PromptEditor

    var body: some View {
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
                    LazyVStack(spacing: 1) {
                        ForEach(Array(editor.completions.enumerated()), id: \.element.id) { index, completion in
                            CompletionRow(completion: completion, selected: index == editor.completionIndex)
                                .id(completion.id)
                                .onTapGesture {
                                    editor.selectCompletion(index)
                                    editor.acceptCompletion()
                                }
                        }
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
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

private struct CompletionRow: View {
    let completion: Completion
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            HerdIcon(completion.kind.symbol, size: 12)
                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                .frame(width: 12)
            Text(completion.value)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(selected ? Theme.cardSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}
