import AppKit
import Foundation

/// The visual twin: Octet's own interface to whatever agent is in the focused
/// pane. Agents write their turns to disk as structured lines, so the twin
/// reads that rather than scraping a terminal, draws it natively, and sends
/// what you type back to the real agent — which keeps every agent's own
/// features intact while the interface stops being a TUI.
@MainActor
final class TwinSession: ObservableObject {
    /// The conversation as read from the agent's own session file.
    @Published private(set) var conversation = TwinConversation()
    /// The agent the twin is showing, when there is one.
    @Published private(set) var agent: EngineAgent?
    /// The question the agent is waiting on, read off the screen.
    @Published private(set) var approval: TwinApproval?
    /// Why the twin has nothing to show, when it doesn't.
    @Published private(set) var notice: String?
    /// What you are typing back to the agent.
    @Published var draft = ""
    /// Panes showing the twin instead of the terminal.
    @Published private(set) var shownPanes: Set<String> = []
    /// What you have sent that the agent hasn't written down yet.
    @Published private(set) var pending: [TwinPendingMessage] = []

    private unowned let window: WindowContext
    private var store: SessionStore { window.store }
    private var tail: TwinTail?
    private var source: TwinSource?
    private var attachedPane: String?
    private var locating = false
    private var lastLocate = Date.distantPast
    /// How often to look again while an agent has written nothing.
    private static let locateInterval: TimeInterval = 2
    private var timer: Timer?
    private var reading = false
    /// Panes the twin has already opened itself for, so closing it sticks.
    private var autoOpened: Set<String> = []

    init(window: WindowContext) {
        self.window = window
    }

    // MARK: - Visibility

    var focusedPaneId: String? { window.focusedPaneId }

    var isVisible: Bool {
        guard SettingsStore.shared.values.visualTwin,
              AgentCenter.shared.active(in: window.focusedWorkspace?.workspaceId) == nil,
              AgentCenter.shared.board(in: window.focusedWorkspace?.workspaceId) == nil,
              focusedAgent != nil, let paneId = focusedPaneId else { return false }
        return shownPanes.contains(paneId)
    }

    /// Whether the focused pane is running something the twin can show.
    var canShow: Bool { focusedAgent != nil }

    var focusedAgent: EngineAgent? {
        guard let paneId = focusedPaneId else { return nil }
        return store.snapshot.agents.first { $0.paneId == paneId }
    }

    func toggle() {
        guard let paneId = focusedPaneId else { return }
        if shownPanes.contains(paneId) {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let paneId = focusedPaneId else { return }
        guard focusedAgent != nil else {
            ToastCenter.shared.fail(nil, "No agent in this pane", detail: "The twin shows an agent's conversation.")
            return
        }
        open(paneId, takeFocus: true)
    }

    /// Shows the twin for one pane, which may not be the one you are looking
    /// at: an agent started in a background tab has its twin ready when you
    /// get there.
    private func open(_ paneId: String, takeFocus: Bool) {
        shownPanes.insert(paneId)
        if takeFocus, window.isKey {
            // While the twin is up it owns the keyboard: the agent underneath
            // must not catch what you meant to type here.
            TwinComposerFocus.request()
        }
        guard paneId == focusedPaneId else { return }
        refreshAttachment()
        startTimer()
    }

    func hide() {
        guard let paneId = focusedPaneId else { return }
        shownPanes.remove(paneId)
        // Don't reopen it behind the user's back.
        autoOpened.insert(paneId)
        stopTimerIfIdle()
        OctetTerminalRuntime.focusTerminal()
    }

    /// Called from the snapshot loop: opens for agents as they start, follows
    /// focus, and forgets panes that have gone.
    func snapshotChanged() {
        let panes = Set(store.snapshot.panes.map(\.paneId))
        shownPanes.formIntersection(panes)
        autoOpened.formIntersection(panes)
        let settings = SettingsStore.shared.values
        if settings.visualTwin, settings.twinByDefault {
            // Every pane that starts an agent, not only the one in front:
            // running `claude` in a tab is what asks for the twin.
            for agent in store.snapshot.agents where !autoOpened.contains(agent.paneId) {
                autoOpened.insert(agent.paneId)
                open(agent.paneId, takeFocus: agent.paneId == focusedPaneId)
            }
        }
        if shouldWatch {
            if isVisible { refreshAttachment() }
            startTimer()
        } else {
            approval = nil
            stopTimerIfIdle()
        }
    }

    // MARK: - Reading

    /// Points the twin at the focused pane's session file. An agent that has
    /// only just started hasn't written one yet, so this keeps looking rather
    /// than giving up on the first pass — or, worse, showing the conversation
    /// it had last time.
    private func refreshAttachment() {
        guard let agent = focusedAgent else { return }
        if attachedPane != agent.paneId {
            attachedPane = agent.paneId
            conversation = TwinConversation()
            approval = nil
            tail = nil
            source = nil
            notice = nil
            pending = []
            lastLocate = .distantPast
        }
        self.agent = agent
        guard source == nil, !locating, Date().timeIntervalSince(lastLocate) >= Self.locateInterval else { return }
        locating = true
        lastLocate = Date()

        let record = agent.terminalId.flatMap { store.recovery.record(forTerminal: $0) }
        let sessionId = agent.sessionReference ?? record?.sessionId
        var cwds = agent.searchCwds
        for extra in [record?.cwd, record?.currentCwd].compactMap({ $0 }) where !cwds.contains(extra) {
            cwds.append(extra)
        }
        let kind = agent.agent
        // Only a session touched since this agent started belongs to it.
        let since = sessionId == nil ? record?.firstSeen : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = TwinSources.locate(agent: kind, sessionId: sessionId, cwds: cwds, since: since)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.locating = false
                guard self.attachedPane == agent.paneId else { return }
                guard let found else {
                    let name = AgentBrand.forAgent(kind)?.displayName ?? "This agent"
                    self.notice = "\(name) hasn't written to its session yet. Send it something, or press ⌘⇧V for the terminal."
                    return
                }
                self.source = found
                self.tail = TwinTail(format: found.format ?? kind)
                self.notice = nil
                self.read()
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard !shouldWatch else { return }
        timer?.invalidate()
        timer = nil
    }

    /// The twin also watches the focused terminal while hidden when quick
    /// answers are enabled, so a prompt can slide out of the window corner.
    private var shouldWatch: Bool {
        isVisible || (SettingsStore.shared.values.agentQuickAnswers && focusedAgent?.agentStatus == .blocked)
    }

    private func tick() {
        guard shouldWatch else {
            stopTimerIfIdle()
            return
        }
        if isVisible {
            refreshAttachment()
            read()
        }
        readApproval()
    }

    /// Pulls whatever the agent has written since the last pass.
    private func read() {
        guard !reading, let tail, let source else { return }
        reading = true
        let pane = attachedPane
        DispatchQueue.global(qos: .userInitiated).async {
            var working = tail
            let changed = working.pull(path: source.path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.attachedPane == pane else { return }
                self.tail = working
                if changed { self.conversation = working.conversation }
                self.settlePending()
                if working.conversation.messages.isEmpty, self.notice == nil, working.started {
                    self.notice = "This session is empty so far."
                } else if !working.conversation.messages.isEmpty {
                    self.notice = nil
                }
            }
        }
    }

    /// Clears the messages the agent has now written into its session.
    private func settlePending() {
        guard !pending.isEmpty else { return }
        let settled = TwinPending.settle(pending, against: TwinRows.build(conversation))
        if settled != pending { pending = settled }
    }

    /// Approvals never reach the session file — they are a question drawn on
    /// screen — so the twin reads the screen for them, and only while the
    /// agent is actually waiting.
    private func readApproval() {
        guard let agent = focusedAgent, agent.agentStatus == .blocked else {
            if approval != nil { approval = nil }
            return
        }
        guard window.isKey else { return }
        let screen = OctetTerminalRuntime.screenText() ?? ""
        let detected = TwinApprovals.detect(screen: screen)
        if detected != approval { approval = detected }
    }

    // MARK: - Writing back

    /// Sends what you typed to the real agent, as if you had typed it there.
    /// It shows in the conversation straight away and settles into the real
    /// turn once the agent writes it down.
    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let paneId = attachedPane else { return }
        draft = ""
        pending.append(TwinPendingMessage(text: text))
        prompt(text, to: paneId)
    }

    /// Answers the question on screen.
    func answer(_ option: TwinApproval.Option) {
        guard let paneId = attachedPane ?? focusedPaneId else { return }
        approval = nil
        send(option.needsReturn ? option.key + "\r" : option.key, to: paneId)
    }

    /// Escape, the way every agent reads "stop".
    func interrupt() {
        guard let paneId = attachedPane else { return }
        send("\u{1b}", to: paneId)
    }

    private func prompt(_ text: String, to paneId: String) {
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            // `agent.prompt` types and submits in one step for agents the
            // engine knows; falling back keeps the twin working for the rest.
            let outcome = Result { try client.call("agent.prompt", ["target": paneId, "text": text]) }
            if case .failure = outcome {
                let fallback = Result {
                    try client.call("pane.send_text", ["pane_id": paneId, "text": text + "\r"])
                }
                if case .failure(let error) = fallback {
                    DispatchQueue.main.async {
                        ToastCenter.shared.fail(nil, "Couldn't send that to the agent", detail: String(describing: error))
                    }
                }
            }
        }
    }

    private func send(_ text: String, to paneId: String) {
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("pane.send_text", ["pane_id": paneId, "text": text]) }
            if case .failure(let error) = outcome {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't answer the agent", detail: String(describing: error))
                }
            }
        }
    }
}
