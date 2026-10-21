import Foundation

@MainActor
extension AgentSession {
    /// The conversation's state in the shared vocabulary. Approving a plan
    /// (ExitPlanMode) is a permission prompt, so it reads as approval; a
    /// plan the last turn ended on in plan mode, with nothing asked, reads
    /// as Plan ready.
    var agentState: AgentState {
        let running = conversation.isRunning
        let planReady = !running && permissionMode == .plan && pendingPermission == nil
            && ComposerPlanFollowUp.latestPlan(in: conversation.items, planMode: true, running: false) != nil
        let unseen = AttentionRouter.shared.hasUnseenFinish(id)
        let state = AgentState.conversation(
            pendingPermission: pendingPermission != nil,
            pendingQuestion: pendingQuestion != nil,
            isRunning: running,
            // A turn's error is news until it's seen, like a finish; one that
            // stopped the agent starting stays until it's fixed.
            failed: startupError != nil || launchFailure != nil || (conversation.lastError != nil && unseen),
            planReady: planReady,
            unseenFinish: unseen
        )
        // Stopped at a usage limit, with nothing asked of you: it's waiting
        // for the limit to reset, not done.
        if conversation.limitHit != nil, state == .done || state == .idle || state == .failed { return .waiting }
        return state
    }

    /// Subagents it has started this turn that haven't reported back.
    var runningSubagents: Int {
        guard conversation.isRunning else { return 0 }
        return conversation.items.filter { item in
            guard item.parent == nil, case .tool(let call) = item.kind else { return false }
            return (call.name == "Task" || call.name == "Agent") && call.result == nil
        }.count
    }

    /// The last thing it wrote, as one line.
    var lastReplyPreview: String? {
        for item in conversation.items.reversed() {
            if case .text(let text) = item.kind, !text.isEmpty { return plainPreview(text) }
        }
        return nil
    }
}
