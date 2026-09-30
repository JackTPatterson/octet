import SwiftUI

/// A Claude background session's live transcript, read from its log, with
/// its actions, for the agents hub.
struct AgentDetail: View {
    @EnvironmentObject private var window: WindowContext
    let agent: BackgroundAgent
    @ObservedObject var store: SessionStore
    @State private var conversation = AgentConversation()
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("\(stateLabel) · \(abbreviateHome(agent.cwd))")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                actions
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
                            ItemRow(item: item, running: false)
                                .padding(.leading, item.parent == nil ? 0 : 18)
                                .id(item.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
                .onChange(of: conversation.items.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .onAppear { load(); startPolling() }
        .onDisappear { timer?.invalidate() }
    }

    private var stateLabel: String {
        switch (agent.kind, agent.state) {
        case (.interactive, _): "open in a terminal"
        case (_, .needsInput): "needs input"
        case (_, .working): "working"
        case (_, .done): "completed"
        case (_, .idle): "idle"
        }
    }

    @ViewBuilder private var actions: some View {
        if agent.kind == .background {
            OctetButton(title: "Bring Back Here", kind: .primary, compact: true) {
                guard let workspace = workspaceId else { return }
                AgentsStore.shared.bringBack(agent, workspaceId: workspace)
            }
            .help("Stop the background run and continue this conversation in Octet")
            OctetButton(title: "Open in Terminal", icon: "terminal", kind: .secondary, compact: true) {
                window.applyLayout(AgentsStore.attachLayout(agent).merging(
                    workspaceId.map { ["workspace_id": $0] } ?? [:]) { $1 },
                    failure: "Couldn't open \(agent.name) in a terminal")
                AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId)
            }
            if agent.state == .working || agent.state == .needsInput {
                OctetButton(title: "Stop", kind: .secondary, compact: true) { AgentsStore.shared.stop(agent) }
            }
            OctetButton(title: "Remove", kind: .ghost, compact: true) {
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

    private func load() {
        let agent = self.agent
        DispatchQueue.global(qos: .userInitiated).async {
            let text = AgentsStore.logPath(for: agent).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            let replayed = AgentConversation.replay(lines: text.components(separatedBy: "\n"))
            DispatchQueue.main.async {
                if replayed.items != conversation.items { conversation = replayed }
            }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { load() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
