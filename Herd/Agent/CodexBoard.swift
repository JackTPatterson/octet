import SwiftUI

/// Codex's sessions, as `codex agents` lists them, with the selected one's
/// transcript and a reply field (Codex can queue a message to a session).
/// Opens from Codex tabs; Esc returns.
struct CodexBoard: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var codex = CodexAgentsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var selected: String?
    @State private var task = ""

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 400).zIndex(1)
            Rectangle().fill(Theme.divider).frame(width: 1).zIndex(1)
            // The detail slides out from behind the list, and back under it.
            ZStack {
                if let agent = codex.agents.first(where: { $0.id == selected }) {
                    CodexDetail(agent: agent, store: store)
                        .id(agent.id)
                        .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                } else {
                    VStack(spacing: 6) {
                        Text("Select a session").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        Text("Its conversation shows here, and you can reply.").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(motion.animation(.sidebar), value: selected)
        }
        .background(Theme.terminalBackground)
        .onExitCommand { AgentCenter.shared.board = nil }
        .onAppear { if selected == nil { selected = (codex.needsInput + codex.working + codex.finished).first?.id } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                if let brand = AgentBrand.forAgent("codex") {
                    AgentLogo(brand: brand, size: 16).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex agents").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(codex.needsInput.count) awaiting input · \(codex.working.count) working · \(codex.finished.count) done")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                HerdButton(title: "Close", kind: .ghost, compact: true) { AgentCenter.shared.board = nil }
                    .help("Back (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                HerdTextField(placeholder: "Describe a task for Codex to run", text: $task) { start() }
                HerdButton(title: "Start", kind: .primary, compact: true) { start() }
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Needs input", codex.needsInput)
                    section("Working", codex.working)
                    section("Recent", codex.finished)
                    if codex.loaded && codex.agents.isEmpty {
                        Text("No Codex sessions yet. Start one above.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(14)
                    }
                    if let error = codex.lastError {
                        Text(error).font(Theme.captionFont).foregroundStyle(Theme.danger).padding(14)
                    }
                    if !codex.loaded { LoadingLine(width: 40).padding(14) }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BackgroundAgent]) -> some View {
        if !list.isEmpty {
            Text(title.uppercased())
                .font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            ForEach(list) { agent in
                AgentRow(agent: agent, lastLine: codex.previews[agent.id].flatMap { $0.isEmpty ? nil : $0 },
                         selected: selected == agent.id)
                    .onTapGesture { selected = agent.id }
                    .padding(.horizontal, 6)
            }
        }
    }

    private func start() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cwd = store.focusedWorkspace.flatMap { store.snapshot.directory(ofWorkspace: $0.workspaceId) } ?? NSHomeDirectory()
        CodexAgentsStore.shared.start(task: text, cwd: cwd)
        task = ""
    }
}

/// A Codex session's transcript, live, with a reply field and its actions.
private struct CodexDetail: View {
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
                HerdButton(title: "Resume in Terminal", icon: "terminal", kind: .secondary, compact: true) {
                    CodexAgentsStore.shared.resume(agent, client: store.client, workspaceId: workspaceId)
                }
                HerdButton(title: "Archive", kind: .ghost, compact: true) { CodexAgentsStore.shared.archive(agent) }
                HerdButton(title: "Delete", kind: .ghost, compact: true) {
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
                .onChange(of: conversation.items.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 6) {
                HerdTextField(placeholder: "Reply to this session (queued until it takes input)", text: $reply) { send() }
                HerdButton(title: "Queue", icon: "arrow.up", kind: .primary, compact: true) { send() }
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
            ?? store.focusedWorkspace?.workspaceId
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

/// Opens the Codex agents board from Codex tabs.
struct CodexAgentsButton: View {
    @ObservedObject private var codex = CodexAgentsStore.shared
    @ObservedObject private var center = AgentCenter.shared
    @State private var hovered = false

    var body: some View {
        let waiting = codex.needsInput.count
        let open = center.board == .codex
        Button { center.board = open ? nil : .codex } label: {
            HStack(spacing: 4) {
                if let brand = AgentBrand.forAgent("codex") { AgentLogo(brand: brand, size: 12) }
                HerdIcon("tool.agent", size: 14)
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.terminalBackground)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Capsule().fill(Color(hex: "FFC107")))
                }
            }
            .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(open ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Codex agents (⌘⇧A)" + (waiting > 0 ? ": \(waiting) waiting on you" : ""))
        .accessibilityLabel("Codex agents" + (waiting > 0 ? ", \(waiting) need input" : ""))
    }
}
