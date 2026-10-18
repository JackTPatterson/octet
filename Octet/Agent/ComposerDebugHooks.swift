import Foundation

#if DEBUG
/// Verification hooks for the composer's T3 Code features, reached through
/// `OCTET_OPEN_WINDOW=conversation:<id>`. None of them talks to an agent.
@MainActor
enum ComposerDebugHooks {
    static func run(_ id: String?, session: AgentSession, dropdowns: OctetDropdownState, setText: @escaping (String) -> Void) {
        switch id {
        case "stash":
            // A seeded stash with its menu open.
            PromptStashStore.shared.debugSeed(project: session.cwd)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dropdowns.openId = ComposerStashControls.menuId }
        case "stashbadge":
            // The badge and the stash button beside a draft.
            PromptStashStore.shared.debugSeed(project: session.cwd)
            setText("Draft that could be stashed with ⌘S")
        case "plan":
            loadPlan(into: session)
        case "slash":
            session.agentCommands = sampleCommands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { setText("/rv") }
        case "slashdesc":
            session.agentCommands = sampleCommands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { setText("/summar") }
        case "long":
            setText(String(repeating: "Explain how the retry loop handles a dropped connection. ", count: 650))
        case "toolong":
            setText(String(repeating: "Explain how the retry loop handles a dropped connection. ", count: 2_300))
        default:
            break
        }
    }

    /// Commands as Claude Code's `initialize` lists them.
    static var sampleCommands: [SlashCommand] {
        SlashCommands.claudePublished([
            ["name": "review", "description": "Review a pull request"],
            ["name": "compact", "description": "Clear conversation history but keep a summary in context",
             "argumentHint": "<optional custom summarization instructions>"],
            ["name": "security-review", "description": "Complete a security review of the pending changes"],
            ["name": "release-notes", "description": "View release notes"],
            ["name": "resume", "description": "Resume a conversation"],
            ["name": "model", "description": "Set the AI model for Claude Code", "argumentHint": "<model>"],
            ["name": "pr-comments", "description": "Get comments from a GitHub pull request"],
        ])
    }

    /// A finished plan-mode turn that ended on ExitPlanMode, as Claude Code
    /// leaves it when the plan is sent back for changes.
    static func loadPlan(into session: AgentSession) {
        session.permissionMode = .plan
        let plan = """
        # Make upload retries give up

        1. Count attempts outside the retry closure in `UploadClient.retryUpload`
        2. Stop after `maxAttempts` with exponential backoff
        3. Add a test for the give-up path
        """
        var conversation = session.conversation
        conversation.appendUser("The upload retry loop never gives up. Plan a fix.")
        conversation.items.append(AgentItem(id: "debug-read", kind: .tool(AgentToolCall(
            name: "Read", summary: "UploadClient.swift", input: "", result: "…"))))
        let input = try? JSONSerialization.data(withJSONObject: ["plan": plan])
        conversation.items.append(AgentItem(id: "debug-plan", kind: .tool(AgentToolCall(
            name: "ExitPlanMode", summary: "", input: plan, inputData: input,
            result: "The user wants to keep planning.", isError: true))))
        conversation.items.append(AgentItem(id: "debug-plan-text", kind: .text("Here's the plan. Tell me what to change, or approve it.")))
        conversation.isRunning = false
        session.conversation = conversation
    }
}
#endif
