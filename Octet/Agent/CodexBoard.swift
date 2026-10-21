import SwiftUI

/// A Codex session's transcript, live, with a reply field and its actions.
struct CodexDetail: View {
    @EnvironmentObject private var window: WindowContext
    let agent: BackgroundAgent
    @ObservedObject var store: SessionStore
    @StateObject private var transcript: HubTranscriptModel
    @State private var reply = ""

    init(agent: BackgroundAgent, store: SessionStore) {
        self.agent = agent
        self.store = store
        _transcript = StateObject(wrappedValue: HubTranscriptModel(source: .codex(agent)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HubDetailHeader(vendor: "codex", title: agent.name, status: AgentsHubList.status(agent),
                            crumbs: ["Background", abbreviateHome(agent.cwd)]) {
                OctetButton(title: "Resume in Terminal", icon: "terminal", kind: .primary, compact: true) {
                    window.applyLayout(CodexAgentsStore.resumeLayout(agent).merging(
                        workspaceId.map { ["workspace_id": $0] } ?? [:]) { $1 },
                        failure: "Couldn't open \(agent.name) in a terminal")
                    AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
                }
                OctetButton(title: "Archive", kind: .secondary, compact: true) { CodexAgentsStore.shared.archive(agent) }
                OctetIconButton(icon: "trash", help: "Delete") {
                    ConfirmCenter.shared.ask(
                        title: "Delete \(agent.name)?",
                        message: "Codex removes this session for good. This can't be undone.",
                        confirmTitle: "Delete", destructive: true
                    ) { _ in CodexAgentsStore.shared.delete(agent) }
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            // A quote goes into the reply, as it would into a composer.
            HubTranscript(model: transcript, cwd: agent.cwd, running: agent.state == .working, quote: { passage in
                let quoted = passage.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                reply = reply.isEmpty ? quoted + "\n" : reply + "\n" + quoted + "\n"
            })
            HStack(spacing: 6) {
                OctetTextField(placeholder: "Reply to this session (queued until it takes input)", text: $reply) { send() }
                OctetButton(title: "Queue", icon: "arrow.up", kind: .primary, compact: true) { send() }
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
        .onAppear { transcript.start() }
        .onDisappear { transcript.stop() }
    }

    private var workspaceId: String? {
        store.snapshot.workspaces.first { store.snapshot.directory(ofWorkspace: $0.workspaceId) == agent.cwd }?.workspaceId
            ?? window.focusedWorkspace?.workspaceId
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        CodexAgentsStore.shared.reply(agent, message: text)
        reply = ""
    }
}
