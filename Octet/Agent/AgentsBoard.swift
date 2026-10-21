import SwiftUI

/// A Claude background session's live transcript, read from its log, with
/// its actions, for the agents hub.
struct AgentDetail: View {
    @EnvironmentObject private var window: WindowContext
    let agent: BackgroundAgent
    @ObservedObject var store: SessionStore
    @StateObject private var transcript: HubTranscriptModel

    init(agent: BackgroundAgent, store: SessionStore) {
        self.agent = agent
        self.store = store
        _transcript = StateObject(wrappedValue: HubTranscriptModel(source: .claude(agent)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HubDetailHeader(vendor: "claude", title: agent.name, status: AgentsHubList.status(agent),
                            crumbs: ["Background", abbreviateHome(agent.cwd)]) { actions }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HubTranscript(model: transcript, cwd: agent.cwd, running: agent.state == .working) {
                if transcript.logMissing { missingLogNote }
            }
        }
        .onAppear { transcript.start() }
        .onDisappear { transcript.stop() }
    }

    @ViewBuilder private var actions: some View {
        if agent.kind == .background {
            // Resuming needs the conversation log.
            if !transcript.logMissing {
                OctetButton(title: "Bring Back Here", kind: .primary, compact: true) {
                    guard let workspace = workspaceId else { return }
                    AgentsStore.shared.bringBack(agent, workspaceId: workspace)
                }
                .help("Stop the background run and continue this conversation in Octet")
            }
            OctetButton(title: "Open in Terminal", icon: "terminal", kind: .secondary, compact: true) {
                window.applyLayout(AgentsStore.attachLayout(agent).merging(
                    workspaceId.map { ["workspace_id": $0] } ?? [:]) { $1 },
                    failure: "Couldn't open \(agent.name) in a terminal")
                AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
            }
            if agent.state == .working || agent.state == .needsInput {
                OctetButton(title: "Stop", icon: "pause.circle", kind: .secondary, compact: true) { AgentsStore.shared.stop(agent) }
            }
            OctetIconButton(icon: "trash", help: "Remove") {
                ConfirmCenter.shared.ask(
                    title: "Remove \(agent.name)?",
                    message: "It leaves the agents list. The conversation stays on disk and can still be resumed.",
                    confirmTitle: "Remove",
                    destructive: true
                ) { _ in AgentsStore.shared.remove(agent) }
            }
        } else {
            Text("Open in another terminal; shown read-only.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// The workspace for the session's folder, or the focused one.
    private var workspaceId: String? {
        store.snapshot.workspaces.first { store.snapshot.directory(ofWorkspace: $0.workspaceId) == agent.cwd }?.workspaceId
            ?? window.focusedWorkspace?.workspaceId
    }

    /// Why the transcript is short, when only the job's timeline is left.
    private var missingLogNote: some View {
        HubCallout(icon: "info.circle.fill", title: "The full conversation is no longer on disk",
                   message: "Claude Code deletes conversation logs after its cleanup period (30 days unless cleanupPeriodDays in ~/.claude/settings.json says otherwise), so it can't be brought back. Below is what the job kept of each step.",
                   tint: Theme.textTertiary)
    }
}
