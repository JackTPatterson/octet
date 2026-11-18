import Foundation

/// Closes the tabs Octet opened for an agent's own work (a delegated task or
/// review, a task another Mac sent) once that agent has finished and sat idle
/// for the same delay subagent tabs use. Nothing closes while it's in front,
/// and an agent that's given more work starts the wait again.
@MainActor
final class AgentTabCloser {
    static let shared = AgentTabCloser()

    /// Panes whose agent has finished, and since when each has been idle.
    private var finished: [String: Date?] = [:]
    private var closing: Set<String> = []
    private var timer: Timer?
    private weak var store: SessionStore?

    /// The agent in `pane` has finished; close its tab once it has been idle
    /// for the delay, unless the setting keeps tabs open.
    func closeWhenSettled(pane: String, store: SessionStore) {
        self.store = store
        finished[pane] = .some(nil)
        startTimer()
        observe(store.snapshot)
    }

    func observe(_ snapshot: EngineSnapshot, now: Date = Date()) {
        guard !finished.isEmpty else { return }
        let delay = TimeInterval(SettingsStore.shared.values.subagentTabClosing.seconds)
        for (id, idleSince) in finished {
            guard let pane = snapshot.panes.first(where: { $0.paneId == id }) else {
                finished[id] = nil
                closing.remove(id)
                continue
            }
            let status = snapshot.agents.first { $0.paneId == id }?.agentStatus ?? pane.agentStatus
            if status == .working || status == .blocked {
                finished[id] = .some(nil)
                continue
            }
            guard let since = idleSince else {
                finished[id] = .some(now)
                continue
            }
            let inFront = pane.focused || snapshot.focusedTabId == pane.tabId
            guard delay > 0, !inFront, now.timeIntervalSince(since) >= delay, !closing.contains(id) else { continue }
            close(pane, in: snapshot)
        }
        if finished.isEmpty { stopTimer() }
    }

    private func close(_ pane: EnginePane, in snapshot: EngineSnapshot) {
        guard let client = store?.client else { return }
        closing.insert(pane.paneId)
        let alone = snapshot.panes.filter { $0.tabId == pane.tabId }.count <= 1
        let (method, params) = alone ? ("tab.close", ["tab_id": pane.tabId]) : ("pane.close", ["pane_id": pane.paneId])
        DispatchQueue.global(qos: .utility).async {
            let closed = (try? client.call(method, params)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let closer = AgentTabCloser.shared
                    closer.closing.remove(pane.paneId)
                    if closed { closer.finished[pane.paneId] = nil }
                    closer.store?.scheduleRefresh()
                }
            }
        }
    }

    /// The engine's snapshots only come when something changes, so a quiet
    /// session still needs a clock to notice the delay has passed.
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let closer = AgentTabCloser.shared
                guard let snapshot = closer.store?.snapshot else { return closer.stopTimer() }
                closer.observe(snapshot)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
