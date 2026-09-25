import Foundation

/// Closing a tab or pane that's running something doesn't end it straight
/// away: the pane moves, still running, into a workspace Octet keeps out of
/// sight, where ⌘⇧T, the toast or the palette bring it back whole. After the
/// grace period in Settings it's closed for real. An idle shell closes as it
/// always did; there's nothing in it to lose.
@MainActor
final class ClosedTabsController: ObservableObject {
    /// Oldest first; ⌘⇧T reopens the last.
    @Published private(set) var records: [ClosedTabRecord] = []

    private let client: EngineClient
    private let url: URL
    private var lastSnapshot: EngineSnapshot = .empty
    /// Terminals on their way in or out, left alone until the move lands.
    private var moving: Set<String> = []

    init(client: EngineClient,
         url: URL = EngineSession.supportDirectory.appendingPathComponent("closed-tabs.json")) {
        self.client = client
        self.url = url
        records = ClosedTabsJournal.load(from: url).records
    }

    /// How long a closed tab waits; zero closes at once.
    private var keep: TimeInterval { SettingsStore.shared.values.keepClosedTabsMinutes * 60 }

    /// Takes the whole snapshot, holding workspace included.
    func observe(_ snapshot: EngineSnapshot) {
        lastSnapshot = snapshot
        let kept = ClosedTabs.reconcile(records, with: snapshot).filter { !moving.contains($0.terminalId) }
            + records.filter { moving.contains($0.terminalId) }
        if kept != records {
            records = kept.sorted { $0.closedAt < $1.closedAt }
            save()
        }
        for record in ClosedTabs.expired(records, keep: keep) where !moving.contains(record.terminalId) {
            closeForGood(record)
        }
        steerAwayFromHolding(snapshot)
    }

    private var steering = false

    /// Closing a workspace's last tab lets the server focus the next
    /// workspace, which can be the holding one, and a window following the
    /// server's focus would then show a closed tab. Focus goes to a workspace
    /// you can see instead, or a fresh one when none is left.
    private func steerAwayFromHolding(_ snapshot: EngineSnapshot) {
        guard !steering, let holding = ClosedTabs.holdingWorkspace(in: snapshot),
              snapshot.focusedWorkspaceId == holding.workspaceId || (snapshot.focusedWorkspaceId == nil && holding.focused)
        else { return }
        steering = true
        let client = self.client
        let other = snapshot.workspaces.first { $0.workspaceId != holding.workspaceId }?.workspaceId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let other {
                _ = try? client.call("workspace.focus", ["workspace_id": other])
            } else {
                _ = try? client.call("workspace.create", ["cwd": NSHomeDirectory(), "focus": true])
            }
            DispatchQueue.main.async { self?.steering = false }
        }
    }

    /// The pane a closed tab is waiting in.
    func pane(for record: ClosedTabRecord) -> EnginePane? {
        ClosedTabs.panes(for: [record], in: lastSnapshot)[record.terminalId]
    }

    /// Closes `panes`: those running something wait in the holding
    /// workspace, and `closeRest` ends whatever is left (the tab itself, or
    /// an idle pane). If a move fails nothing is ended, so a slip never costs
    /// what was running.
    func close(panes: [EnginePane], title: String, workspace: EngineWorkspace?,
               closeRest: @escaping @MainActor () -> Void) {
        guard keep > 0, !panes.isEmpty else { return closeRest() }
        let client = self.client
        let holding = ClosedTabs.holdingWorkspace(in: lastSnapshot)?.workspaceId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let busy = panes.compactMap { pane -> (EnginePane, ShellJob)? in
                guard pane.terminalId != nil,
                      let job = (try? client.call("pane.process_info", ["pane_id": pane.paneId])).flatMap(ShellRecovery.job(in:))
                else { return nil }
                return (pane, job)
            }
            guard !busy.isEmpty else {
                DispatchQueue.main.async { closeRest() }
                return
            }
            var holdingId = holding
            var parked: [ClosedTabRecord] = []
            var failure: Error?
            let now = Date()
            for (pane, job) in busy {
                let name = title == TabAutoName.unnamedLabel ? job.name : title
                var destination: [String: Any] = ["type": "new_tab", "workspace_id": holdingId ?? ""]
                if holdingId == nil {
                    destination = ["type": "new_workspace", "label": ClosedTabs.workspaceLabel, "tab_label": name]
                }
                do {
                    let result = try client.call("pane.move", ["pane_id": pane.paneId, "destination": destination, "focus": false])
                    holdingId = holdingId ?? EngineCreated(result: result).workspaceId
                    parked.append(ClosedTabRecord(terminalId: pane.terminalId!, title: name,
                                                  workspaceId: workspace?.workspaceId, workspaceLabel: workspace?.label ?? "",
                                                  cwd: pane.effectiveCwd, command: job.command, closedAt: now))
                } catch {
                    failure = error
                    break
                }
            }
            let leftBehind = panes.count > parked.count
            DispatchQueue.main.async {
                guard let self else { return }
                self.records.append(contentsOf: parked)
                self.moving.formUnion(parked.map(\.terminalId))
                self.save()
                // The next snapshot shows them in the holding workspace.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.moving.subtract(parked.map(\.terminalId))
                }
                if let failure {
                    ToastCenter.shared.fail(nil, "Couldn't keep \(title) running, so it's still open",
                                            detail: String(describing: failure))
                    return
                }
                if leftBehind { closeRest() }
                self.announce(parked)
            }
        }
    }

    /// Ends a closed tab for good.
    func closeForGood(_ record: ClosedTabRecord) {
        forget(record)
        guard let pane = pane(for: record) else { return }
        let client = self.client
        DispatchQueue.global(qos: .utility).async {
            _ = try? client.call("tab.close", ["tab_id": pane.tabId])
        }
    }

    /// Ends every closed tab now.
    func closeAll() {
        for record in records { closeForGood(record) }
    }

    /// Drops the record, for a tab that's been reopened or ended.
    func forget(_ record: ClosedTabRecord) {
        records.removeAll { $0.terminalId == record.terminalId }
        save()
    }

    private func announce(_ parked: [ClosedTabRecord]) {
        guard let last = parked.last else { return }
        let minutes = Int(keep / 60)
        let running = parked.count == 1
            ? "\(last.command.map { ShellRecovery.short($0) } ?? "It") is still running"
            : "\(parked.count) panes are still running"
        ToastCenter.shared.info(
            "Closed \(last.title)",
            detail: "\(running), kept for \(minutes) min. ⌘⇧T reopens it.",
            after: 8,
            action: .init(title: "Reopen") { KeyWindow.act { $0.reopenClosedTab(last) } }
        )
    }

    private func save() {
        let journal = ClosedTabsJournal(records: records), url = self.url
        DispatchQueue.global(qos: .utility).async { journal.save(to: url) }
    }
}
