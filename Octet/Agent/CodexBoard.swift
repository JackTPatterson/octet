import SwiftUI

/// A Codex session's transcript, live, with a reply field and its actions.
struct CodexDetail: View {
    @EnvironmentObject private var window: WindowContext
    let agent: BackgroundAgent
    @ObservedObject var store: SessionStore
    @State private var conversation = AgentConversation()
    @State private var timer: Timer?
    @State private var reply = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("\(stateLabel) · \(abbreviateHome(agent.cwd))")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                OctetButton(title: "Resume in Terminal", icon: "terminal", kind: .secondary, compact: true) {
                    window.applyLayout(CodexAgentsStore.resumeLayout(agent).merging(
                        workspaceId.map { ["workspace_id": $0] } ?? [:]) { $1 },
                        failure: "Couldn't open \(agent.name) in a terminal")
                    AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
                }
                OctetButton(title: "Archive", kind: .ghost, compact: true) { CodexAgentsStore.shared.archive(agent) }
                OctetButton(title: "Delete", kind: .ghost, compact: true) {
                    ConfirmCenter.shared.ask(
                        title: "Delete \(agent.name)?",
                        message: "Codex removes this session for good. This can't be undone.",
                        confirmTitle: "Delete", destructive: true
                    ) { _ in CodexAgentsStore.shared.delete(agent) }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.chrome)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conversation.items.filter { item in
                            if case .thinking(let text) = item.kind { return !text.isEmpty }
                            return true
                        }) { item in
                            ItemRow(item: item, running: false).id(item.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
                .octetScrollIndicators()
                .onChange(of: conversation.items.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 6) {
                OctetTextField(placeholder: "Reply to this session (queued until it takes input)", text: $reply) { send() }
                OctetButton(title: "Queue", icon: "arrow.up", kind: .primary, compact: true) { send() }
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(Theme.chrome)
        }
        .onAppear { load(); startPolling() }
        .onDisappear { timer?.invalidate() }
    }

    private var stateLabel: String {
        switch agent.state {
        case .needsInput: "needs input"
        case .working: "working"
        case .done, .idle: "done"
        }
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

    private func load() {
        guard let path = CodexAgentsStore.shared.rolloutPaths[agent.id] else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let twin = TwinTranscript.parse(agent: "codex", lines: text.components(separatedBy: "\n"))
            let replayed = AgentConversation(twin: twin)
            DispatchQueue.main.async { if replayed.items != conversation.items { conversation = replayed } }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { load() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
