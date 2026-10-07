import Foundation

/// Carrying a conversation on elsewhere: in another agent when one hits its
/// limit or isn't the right one for the job, or in a fresh conversation of
/// the same agent when the context has grown too long. The new conversation
/// is in the same workspace and folder, and its first message is a brief
/// written from the old one's transcript.
@MainActor
enum ConversationHandoff {
    /// The agents, other than `session`'s own, that are installed here and
    /// have a conversation view in Octet.
    static func otherEngines(than session: AgentSession) -> [AgentSession.Engine] {
        let installed = Set(AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id))
        let all: [AgentSession.Engine] = [.claude, .codex, .opencode, .pi, .qwen]
        return all.filter { $0 != session.engine && installed.contains($0.agent) }
    }

    /// Whether there's anything to carry over.
    static func canHandOff(_ session: AgentSession) -> Bool {
        session.conversation.items.contains { if case .user = $0.kind { return true } else { return false } }
    }

    /// Opens the new conversation and sends it the brief.
    @discardableResult
    static func continueConversation(_ session: AgentSession, in engine: AgentSession.Engine,
                                     reason: HandoffBrief.Reason? = nil, store: SessionStore) -> AgentSession {
        let reason = reason ?? (engine == session.engine ? .fresh : .switching(from: session.engine.displayName))
        let brief = HandoffBrief.build(.init(
            agentName: session.engine.displayName, cwd: session.cwd, branch: store.branches[session.workspaceId],
            items: session.conversation.items, reason: reason))
        let next = AgentCenter.shared.newConversation(workspaceId: session.workspaceId, cwd: session.cwd, engine: engine)
        let base = session.title.hasSuffix(" (continued)") ? String(session.title.dropLast(" (continued)".count)) : session.title
        next.title = String("\(base) (continued)".prefix(60))
        next.send(brief)
        ToastCenter.shared.info(engine == session.engine ? "Started fresh" : "Continuing in \(engine.displayName)",
                                detail: "It has a summary of the work so far: what was asked, the plan, the files changed and the last commands.")
        return next
    }
}
