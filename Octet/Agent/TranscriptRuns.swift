import SwiftUI

/// Tool calls one after another, folded into one line that says what they
/// did ("Read 3 files and ran 2 commands"), after T3 Code's work log; open,
/// it shows each call's own row. A failed call tints the line; while the
/// last call runs it reads in the present tense.
struct ToolRunRow: View {
    let items: [AgentItem]
    let running: Bool
    @Binding var expanded: Bool
    /// The find bar's marks for one of its calls.
    var marks: (String) -> TranscriptFindMarks? = { _ in nil }
    @State private var hovered = false

    var body: some View {
        let calls = items.compactMap { item -> AgentToolCall? in
            if case .tool(let call) = item.kind { return call } else { return nil }
        }
        let live = running && calls.contains { $0.result == nil }
        let failed = calls.filter(\.isError).count
        let interrupted = !running && calls.contains { $0.result == nil }
        let summary = ToolRunSummary.text(calls, live: live)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.sm) {
                    OctetIcon("chevron.right", size: 11)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    OctetIcon(failed > 0 ? "exclamationmark.triangle.fill" : "tool.other", size: 14)
                        .foregroundStyle(failed > 0 ? Theme.danger : Theme.textTertiary)
                    Text(summary)
                        .font(Theme.Text.bodyMedium)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if failed > 0 {
                        Text(failed == 1 ? "1 failed" : "\(failed) failed")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.danger)
                    }
                    if interrupted {
                        Text("Interrupted").font(Theme.Text.caption).foregroundStyle(Theme.warning)
                    }
                    Spacer(minLength: Theme.Space.xs)
                    if live { LoadingLine(width: 14) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover.opacity(0.6) : .clear))
            .onHover { hovered = $0 }
            .accessibilityLabel(summary + (failed > 0 ? ", \(failed) failed" : "") + (interrupted ? ", interrupted" : ""))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows each tool call")
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        ItemRow(item: item, running: running).equatable()
                            .environment(\.transcriptFindMarks, marks(item.id))
                            .id(item.id)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border).frame(width: 1).padding(.leading, 5)
                }
            }
        }
    }
}

/// The model's reasoning: while it's still thinking, the last lines of it
/// as they come; once done, one line saying how long it took, which opens
/// to the whole of it.
struct ThinkingBlock: View {
    let text: String
    let live: Bool
    let duration: TimeInterval?

    var body: some View {
        if live {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.sm) {
                    LoadingLine(width: 12)
                    Text("Thinking…").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textTertiary)
                }
                Text(Self.preview(text))
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .mask(LinearGradient(colors: [.black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Thinking")
        } else {
            Disclosure(title: duration.map { "Thought for \(AgentElapsed.text($0))" } ?? "Thought",
                       tint: Theme.textTertiary) {
                FoundText(text)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The tail of the reasoning so far, a few lines' worth.
    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
        return lines.joined(separator: "\n")
    }
}

/// How long the turn has been going, with what it's doing. Its own timeline
/// redraws this line each second and nothing else.
struct WorkingLine: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            LoadingLine(width: 14)
            if let started = session.turnStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("Working for \(AgentElapsed.text(context.date.timeIntervalSince(started)))")
                        .font(Theme.Text.bodyMedium.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("Working").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textSecondary)
            }
            AgentActivityText(text: session.activity)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.md)
            Text("Esc to stop")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
