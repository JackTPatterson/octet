import SwiftUI

/// What Chat mode opens to, after T3 Chat's empty state: a short heading, the
/// composer in the middle of the page, and a few starters under it. It is a
/// fresh, unsent conversation, so the composer is the conversation's own (model,
/// effort, attachments, slash commands); the first message sends it, and the
/// page becomes the conversation's transcript.
struct ChatHomeView: View {
    @ObservedObject var session: AgentSession
    @StateObject private var dropdowns = OctetDropdownState()
    @StateObject private var bridge = ConversationBridge()
    @StateObject private var questions = QuestionDraftModel()

    /// Starters fill the composer rather than send, so they can be edited.
    static let starters: [Starter] = [
        .init(icon: "search", title: "Explain this project", prompt: "Give me a tour of this project: what it does, how it's laid out, and where to start reading."),
        .init(icon: "tool.edit", title: "Find and fix a bug", prompt: "Look for a bug in this project, explain what's wrong, and fix it."),
        .init(icon: "flask", title: "Write tests", prompt: "Find the least-tested part of this project and write tests for it."),
        .init(icon: "branch", title: "Review my changes", prompt: "Review my uncommitted changes and tell me what you'd fix before committing."),
    ]

    struct Starter: Identifiable {
        let icon: String
        let title: String
        let prompt: String
        var id: String { title }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 6) {
                Text("What should we build?")
                    .font(Theme.Text.title1)
                    .foregroundStyle(ChatStyle.text)
                Text(abbreviateHome(session.cwd))
                    .font(ChatStyle.meta)
                    .foregroundStyle(ChatStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = session.startupError {
                    Text(error).font(ChatStyle.meta).foregroundStyle(Theme.danger)
                }
            }
            .padding(.bottom, 22)
            Composer(session: session, dropdowns: dropdowns, bridge: bridge, questions: questions)
                .chatColumn()
            HStack(spacing: 8) {
                ForEach(Self.starters) { starter in
                    StarterChip(starter: starter) { bridge.prefill = ConversationBridge.Prefill(text: starter.prompt) }
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 24)
            Spacer(minLength: 0).frame(maxHeight: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatStyle.page)
        .octetDropdownHost(dropdowns)
    }
}

private struct StarterChip: View {
    let starter: ChatHomeView.Starter
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = Capsule()
        Button(action: action) {
            HStack(spacing: 6) {
                OctetIcon(starter.icon, size: 12)
                Text(starter.title).font(ChatStyle.meta)
            }
            .foregroundStyle(hovered ? ChatStyle.text : ChatStyle.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(shape.fill(hovered ? ChatStyle.hover : Color.clear))
            .overlay(shape.strokeBorder(ChatStyle.inputBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(starter.prompt)
    }
}

/// The corner control in Chat mode that opens this window's terminal.
struct ModeSwitchButton: View {
    @ObservedObject var window: WindowContext

    var body: some View {
        OctetButton(title: window.mode.other.title, icon: window.mode.other == .workspace ? "terminal" : "message", kind: .ghost, compact: true) {
            window.mode = window.mode.other
        }
        .help("Switch this window to \(window.mode.other.title) mode (⌘K, “Switch to \(window.mode.other.title) Mode”)")
        .padding(10)
    }
}

extension WindowContext {
    /// The conversation Chat mode shows when there's no terminal to fall back
    /// to: the one in front, or a new one in this workspace.
    @discardableResult
    func ensureChatConversation() -> AgentSession? {
        guard let workspaceId = focusedWorkspace?.workspaceId else { return nil }
        if let active = AgentCenter.shared.active(in: workspaceId) { return active }
        let folder = store.snapshot.directory(ofWorkspace: workspaceId) ?? NSHomeDirectory()
        let engine = AgentSession.Engine.preferred
        // Claude starts on its first message; the others need their process up
        // to take one, so they warm as soon as the page is.
        return AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: folder, engine: engine, start: engine != .claude)
    }
}
