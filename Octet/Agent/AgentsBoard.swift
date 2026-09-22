import SwiftUI

/// Claude Code's agent view, natively: every Claude Code session, grouped
/// the way its agent view groups them, with a live transcript of the
/// selected one. Claude only; ← from an empty composer opens it, Esc returns.
struct AgentsBoard: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var agents = AgentsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var selected: String?
    @State private var task = ""

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 400)
                .zIndex(1)
            Rectangle().fill(Theme.divider).frame(width: 1).zIndex(1)
            // The detail slides out from behind the list, and back under it.
            ZStack {
                if let agent = agents.agents.first(where: { $0.sessionId == selected }) {
                    AgentDetail(agent: agent, store: store)
                        .id(agent.sessionId)
                        .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                } else {
                    VStack(spacing: 6) {
                        Text("Select a session").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        Text("Its conversation shows here, live.").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(motion.animation(.sidebar), value: selected)
        }
        .background(Theme.terminalBackground)
        .onExitCommand { AgentCenter.shared.showingBoard = false }
        .onAppear {
            if selected == nil { selected = (agents.needsInput + agents.working + agents.finished).first?.sessionId }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                if let brand = AgentBrand.forAgent("claude") {
                    AgentLogo(brand: brand, size: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude agents").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(agents.needsInput.count) awaiting input · \(agents.working.count) working · \(agents.finished.count) completed")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                OctetButton(title: "Close", kind: .ghost, compact: true) { AgentCenter.shared.showingBoard = false }
                    .help("Back (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                OctetTextField(placeholder: "Describe a task for a new Claude background session", text: $task) { dispatch() }
                OctetButton(title: "Start", kind: .primary, compact: true) { dispatch() }
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Needs input", agents.needsInput)
                    section("Working", agents.working)
                    section("Completed", agents.finished)
                    section("Open in terminals", agents.interactive)
                    if agents.loaded && agents.agents.isEmpty {
                        Text("No Claude Code sessions yet. Start one above, or press ← in an empty message to send a conversation here.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(14)
                    }
                    if let error = agents.lastError {
                        Text(error).font(Theme.captionFont).foregroundStyle(Theme.danger).padding(14)
                    }
                    if !agents.loaded {
                        LoadingLine(width: 40).padding(14)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BackgroundAgent]) -> some View {
        if !list.isEmpty {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(list) { agent in
                AgentRow(agent: agent, lastLine: agents.lastLines[agent.sessionId], selected: selected == agent.sessionId)
                    .onTapGesture { selected = agent.sessionId }
                    .padding(.horizontal, 6)
            }
        }
    }

    private func dispatch() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cwd = window.focusedWorkspace.flatMap { store.snapshot.directory(ofWorkspace: $0.workspaceId) } ?? NSHomeDirectory()
        AgentsStore.shared.dispatch(task: text, cwd: cwd, model: "claude-sonnet-5", effort: nil,
                                    mode: AgentSession.PermissionMode.auto.rawValue)
        task = ""
    }
}

/// One session: its state, name, latest message, folder and age.
struct AgentRow: View {
    let agent: BackgroundAgent
    let lastLine: String?
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateMark(agent: agent)
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let lastLine {
                    Text(lastLine)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(abbreviateHome(agent.cwd)).lineLimit(1).truncationMode(.middle)
                    if let started = agent.startedAt {
                        Text("·")
                        Text(UsageMeter.relative(started))
                    }
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Needs input in amber, working as the loading line, done as a tick,
/// terminal sessions as a terminal mark.
struct StateMark: View {
    let agent: BackgroundAgent

    var body: some View {
        switch (agent.kind, agent.state) {
        case (.interactive, _):
            OctetIcon("terminal", size: 13).foregroundStyle(Theme.textTertiary)
        case (_, .needsInput):
            Circle().fill(Color(hex: "FFC107")).frame(width: 8, height: 8).padding(.top, 4)
        case (_, .working):
            LoadingLine(width: 12).padding(.top, 6)
        case (_, .done):
            OctetIcon("checkmark", size: 13).foregroundStyle(Theme.accent)
        case (_, .idle):
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 8, height: 8).padding(.top, 4)
        }
    }
}

/// A session's live transcript, read from its log, with its actions.
private struct AgentDetail: View {
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
