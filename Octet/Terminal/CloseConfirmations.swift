import Foundation

extension SessionStore {
    /// Asks before closing `panes` when that would stop something running in
    /// them, an agent or a command; idle shells close without asking. With
    /// closed tabs kept running (Settings › Keep closed tabs running) nothing
    /// stops on close, it waits to be reopened, so there's nothing to ask.
    /// `place` names what's closing: "tab", "pane".
    func confirmClosing(_ panes: [EnginePane], place: String, then close: @escaping @MainActor () -> Void) {
        let settings = SettingsStore.shared.values
        guard settings.confirmCloseRunning, settings.keepClosedTabsMinutes <= 0, !panes.isEmpty else { return close() }
        let agents = snapshot.agents
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let work = panes.compactMap { pane -> ClosingWork? in
                if let agent = ClosingWork.agent(in: pane, agents: agents) { return agent }
                guard let job = (try? client.call("pane.process_info", ["pane_id": pane.paneId])).flatMap(ShellRecovery.job(in:))
                else { return nil }
                return ClosingWork(command: job.command)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.ask(ClosePrompt.question(for: work, place: place), then: close) }
            }
        }
    }

    /// Octet's own dialog for `question`, or straight on when there's none.
    static func ask(_ question: ClosePrompt?, then close: @escaping @MainActor () -> Void) {
        guard let question else { return close() }
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: question.title,
            message: question.message,
            items: question.items,
            confirmTitle: question.confirmTitle,
            destructive: true,
            suppressTitle: "Don't ask again for running terminals",
            onConfirm: { suppress in
                if suppress { SettingsStore.shared.values.confirmCloseRunning = false }
                close()
            }
        ))
    }
}
