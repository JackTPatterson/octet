import SwiftUI

/// The round button floating at the plane's bottom right, after T3 Code's:
/// it opens a popover to comment on the PR or review it. Drafts live on the
/// model, so closing the popover doesn't lose them.
struct PullRequestCommentButton: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        Button { open.toggle() } label: {
            OctetIcon("message", size: 16)
                .foregroundStyle(hovered || open ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.ultraThinMaterial))
                .background(Circle().fill(Theme.card.opacity(0.85)))
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("Comment or review")
        .accessibilityLabel("Comment or review")
        .popover(isPresented: $open, arrowEdge: .top) {
            PullRequestComposer(model: model, detail: detail) { open = false }
        }
    }
}

private struct PullRequestComposer: View {
    enum Mode: Hashable { case comment, review }

    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let close: () -> Void
    @State private var mode: Mode = .comment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Line comments held for the review count on its tab, so you
            // see they'll go with it.
            let pending = model.pendingComments.count
            OctetSegmented(selection: $mode, items: [(.comment, "Comment"), (.review, pending > 0 ? "Review (\(pending))" : "Review")])
            switch mode {
            case .comment: comment
            case .review: review
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(Theme.card)
        // Line comments waiting means a review is what you came to send.
        .onAppear { if !model.pendingComments.isEmpty { mode = .review } }
    }

    private var comment: some View {
        VStack(alignment: .leading, spacing: 8) {
            PullRequestTextEditor(placeholder: "Leave a comment", text: $model.commentDraft)
            HStack(spacing: 6) {
                Spacer()
                if detail.isOpen {
                    OctetButton(title: "Close with Comment", kind: .secondary, compact: true) {
                        model.postComment(closing: true)
                        close()
                    }
                    .disabled(empty(model.commentDraft) || model.busy.contains("comment"))
                }
                OctetButton(title: model.busy.contains("comment") ? "Posting…" : "Comment", kind: .primary, compact: true) {
                    model.postComment(closing: false)
                    close()
                }
                .disabled(empty(model.commentDraft) || model.busy.contains("comment"))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Comment (⌘↩)")
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            OctetSegmented(selection: $model.reviewVerdict, items: [
                (.comment, "Comment"), (.approve, "Approve"), (.requestChanges, "Request Changes"),
            ])
            PullRequestTextEditor(placeholder: model.reviewVerdict == .requestChanges
                                      ? "Summarize your review (required)" : "Summarize your review",
                                  text: $model.reviewDraft)
            HStack {
                let pending = model.pendingComments.count
                if pending > 0 {
                    Text("With \(pending) line \(pending == 1 ? "comment" : "comments")")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                OctetButton(title: model.busy.contains("review") ? "Submitting…" : "Submit Review",
                            kind: .primary, compact: true) {
                    model.submitReview()
                    close()
                }
                .disabled(!model.canSubmitReview || model.busy.contains("review"))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Submit (⌘↩)")
            }
        }
    }

    private func empty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The composer's editor: Octet's multi-line field at a fixed height,
/// focused as the composer opens so you can start typing.
private struct PullRequestTextEditor: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        OctetTextEditor(placeholder: placeholder, text: $text, minHeight: 120, maxHeight: 120, autofocus: true)
    }
}
