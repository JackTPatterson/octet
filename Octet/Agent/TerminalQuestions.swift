import Foundation

/// Questions terminal agents are waiting on in tabs out of sight. Their
/// screens are read through the engine, as the twin reads the tab in front,
/// so the question can be answered from the window corner instead.
@MainActor
final class TerminalQuestionWatcher: ObservableObject {
    struct Pending: Equatable, Identifiable {
        let paneId: String
        let tabId: String?
        let agent: String?
        /// The tab's name, so the corner says which agent is asking.
        let place: String?
        let approval: TwinApproval

        var id: String {
            ([paneId, approval.question] + approval.options.map(\.id)).joined(separator: "|")
        }
    }

    @Published private(set) var pending: Pending?
    private weak var window: WindowContext?
    private var timer: Timer?
    private var reading = false
    /// An answered prompt stays on screen until the agent redraws; it is not
    /// offered again in that time.
    private var answered: Set<String> = []
    static let interval: TimeInterval = 1

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let window, !reading else { return }
        guard SettingsStore.shared.values.agentQuickAnswers else {
            if pending != nil { pending = nil }
            return
        }
        let snapshot = window.store.snapshot
        let front = window.displayedFocusedTabId
        let waiting = snapshot.agents.filter {
            $0.agentStatus == .blocked && $0.tabId != front && !$0.isSubagentViewer
        }
        let waitingPanes = Set(waiting.map(\.paneId))
        answered = answered.filter { id in waitingPanes.contains { id.hasPrefix($0 + "|") } }
        guard !waiting.isEmpty else {
            if pending != nil { pending = nil }
            return
        }
        let labels = Dictionary(snapshot.tabs.map { ($0.tabId, $0.label) }) { first, _ in first }
        let client = window.store.client
        let answered = self.answered
        reading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: Pending?
            for agent in waiting {
                guard let read = try? client.call("pane.read", ["pane_id": agent.paneId, "source": "visible"]),
                      let text = (read["read"] as? [String: Any])?["text"] as? String,
                      let approval = TwinApprovals.detect(screen: text) else { continue }
                let candidate = Pending(paneId: agent.paneId, tabId: agent.tabId, agent: agent.agent,
                                        place: agent.tabId.flatMap { labels[$0] }, approval: approval)
                if !answered.contains(candidate.id) {
                    found = candidate
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if found != self.pending { self.pending = found }
            }
        }
    }

    func answer(_ option: TwinApproval.Option, to question: Pending) {
        answered.insert(question.id)
        pending = nil
        guard let client = window?.store.client else { return }
        let text = option.needsReturn ? option.key + "\r" : option.key
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("pane.send_text", ["pane_id": question.paneId, "text": text]) }
            if case .failure(let error) = outcome {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't answer the agent", detail: String(describing: error))
                }
            }
        }
    }
}
