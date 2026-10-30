import SwiftUI

/// What the parts of one conversation's view ask of each other: the queue
/// drawer and the transcript put a message back in the composer to edit, and
/// the composer's keys move the transcript between prompts.
@MainActor
final class ConversationBridge: ObservableObject {
    /// A draft for the composer to take: a queued message to edit, or a
    /// past prompt to edit and send again.
    struct Draft: Equatable {
        enum Purpose: Equatable {
            /// Return updates this held follow-up in place.
            case editHeld(UUID)
            /// Return sends it again from where `itemId` was, going back to
            /// before that message first.
            case resend(itemId: String, revertFiles: Bool)
        }
        let id = UUID()
        let text: String
        let attachments: [AgentSession.Attachment]
        let purpose: Purpose
        /// For a resend: how many files going back would put back.
        var revertableFiles = 0
    }

    /// A step between prompts the transcript should make.
    struct Jump: Equatable {
        enum Direction { case previous, next }
        let id = UUID()
        let direction: Direction
    }

    /// Words for the composer to start from (a starter on the Chat page),
    /// editable and not yet sent, unlike a `Draft`.
    struct Prefill: Equatable {
        let id = UUID()
        let text: String
    }

    @Published var draft: Draft?
    @Published var prefill: Prefill?
    /// What the composer is doing with the draft it took, for its banner.
    @Published var editing: Draft.Purpose?
    /// For the resend being edited: how many files going back would put back.
    @Published var lastDraftRevertable = 0
    @Published var jump: Jump?

    func edit(_ prompt: AgentSession.HeldPrompt) {
        draft = Draft(text: prompt.text, attachments: prompt.attachments, purpose: .editHeld(prompt.id))
    }

    func jumpToPrompt(_ direction: Jump.Direction) {
        jump = Jump(direction: direction)
    }
}
