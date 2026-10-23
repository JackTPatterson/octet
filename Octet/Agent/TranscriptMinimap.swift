import SwiftUI

/// A thin rail beside the transcript with a strip for each of your prompts,
/// where it sits in the conversation. Hovering one shows the prompt and how
/// the reply began; clicking goes there. ⌘↑ and ⌘↓ in an empty message box
/// step between them too.
struct TranscriptMinimap: View {
    let marks: [TranscriptPromptMark]
    /// The prompt nearest the top of the view.
    let current: String?
    let jump: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height - 16, 1)
            ZStack(alignment: .topTrailing) {
                ForEach(marks) { mark in
                    let isCurrent = mark.id == current
                    Button { jump(mark.id) } label: {
                        Capsule()
                            .fill(isCurrent || hovered == mark.id ? Theme.accent : Theme.textTertiary.opacity(0.45))
                            .frame(width: hovered == mark.id ? 14 : 10, height: 3)
                            .frame(width: 18, height: 9, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hovered = inside ? mark.id : (hovered == mark.id ? nil : hovered)
                        if inside { Haptics.tick() }
                    }
                    .offset(y: 8 + mark.position * height - 4.5)
                    .accessibilityLabel("Go to your prompt: \(mark.prompt)")
                }
                if let hovered, let mark = marks.first(where: { $0.id == hovered }) {
                    preview(mark)
                        .offset(x: -24, y: min(max(0, 8 + mark.position * height - 20), max(0, proxy.size.height - 110)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .frame(width: 22)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your prompts")
    }

    private func preview(_ mark: TranscriptPromptMark) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(mark.prompt)
                .font(Theme.Text.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
            if let reply = mark.reply {
                Text(reply)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(Theme.Space.md)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .fixedSize()
    }
}
