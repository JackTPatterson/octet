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
        // T3 Code's group header: "Ran 3 commands", its icon in the work
        // log's column, the chevron at the end.
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    OctetIcon(failed > 0 ? "exclamationmark.triangle.fill" : "tool.other", size: 16)
                        .foregroundStyle(failed > 0 ? ChatStyle.removed : ChatStyle.faintIcon)
                        .frame(width: ChatStyle.workIconColumn)
                    Text(summary)
                        .font(ChatStyle.body)
                        .foregroundStyle(ChatStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if failed > 0 {
                        Text(failed == 1 ? "1 failed" : "\(failed) failed")
                            .font(ChatStyle.meta)
                            .foregroundStyle(ChatStyle.removed)
                    }
                    if interrupted {
                        Text("Interrupted").font(ChatStyle.meta).foregroundStyle(ChatStyle.warning)
                    }
                    Spacer(minLength: 4)
                    if live { LoadingLine(width: 14) }
                    OctetIcon("chevron.right", size: 12)
                        .foregroundStyle(ChatStyle.faintIcon)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                }
                .frame(minHeight: ChatStyle.workRowHeight)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(hovered ? ChatStyle.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(summary + (failed > 0 ? ", \(failed) failed" : "") + (interrupted ? ", interrupted" : ""))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows each tool call")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        ItemRow(item: item, running: running).equatable()
                            .environment(\.transcriptFindMarks, marks(item.id))
                            .id(item.id)
                    }
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
            WorkLogDisclosure(title: duration.map { "Thought for \(AgentElapsed.text($0))" } ?? "Thought",
                              icon: "brain") {
                FoundText(text)
                    .font(ChatStyle.body)
                    .lineSpacing(ChatStyle.bodyLineSpacing)
                    .foregroundStyle(ChatStyle.text)
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

    // T3 Code's working row: "Working for 12s" in the muted colour on a
    // 24pt line, with a hairline under it, in the chat column.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let started = session.turnStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("Working for \(AgentElapsed.text(context.date.timeIntervalSince(started)))")
                        .font(ChatStyle.body.monospacedDigit())
                        .foregroundStyle(ChatStyle.mutedText)
                }
            } else {
                Text("Working").font(ChatStyle.body).foregroundStyle(ChatStyle.mutedText)
            }
            AgentActivityText(text: session.activity)
                .font(ChatStyle.body)
                .foregroundStyle(ChatStyle.faintIcon)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("Esc to stop")
                .font(ChatStyle.meta)
                .foregroundStyle(ChatStyle.faintIcon)
        }
        .frame(minHeight: ChatStyle.workRowHeight)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(ChatStyle.rowRule).frame(height: 1) }
        .chatColumn()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
