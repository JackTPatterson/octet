import Foundation

/// A tab closed while something ran in it. Its pane isn't ended: it moves,
/// still running, into a workspace Octet keeps out of sight, and comes back
/// whole when reopened. Only after the grace period is it really closed.
struct ClosedTabRecord: Codable, Equatable, Identifiable {
    /// The pane's terminal, which keeps its id wherever the pane moves.
    let terminalId: String
    var title: String
    /// Where it was closed from, to say so and to reopen it there.
    var workspaceId: String?
    var workspaceLabel: String
    var cwd: String?
    /// What was running when it closed.
    var command: String?
    var closedAt: Date

    var id: String { terminalId }
}

enum ClosedTabs {
    /// The workspace closed tabs wait in. Never shown: `visible` takes it out
    /// of every snapshot Octet draws.
    static let workspaceLabel = "Octet · Recently Closed"

    static func holdingWorkspace(in snapshot: EngineSnapshot) -> EngineWorkspace? {
        snapshot.workspaces.first { $0.label == workspaceLabel }
    }

    /// The snapshot without the holding workspace and everything in it.
    static func visible(_ snapshot: EngineSnapshot) -> EngineSnapshot {
        guard let holding = holdingWorkspace(in: snapshot)?.workspaceId else { return snapshot }
        let tabs = snapshot.tabs.filter { $0.workspaceId != holding }
        let panes = snapshot.panes.filter { $0.workspaceId != holding }
        let tabIds = Set(tabs.map(\.tabId)), paneIds = Set(panes.map(\.paneId))
        return EngineSnapshot(
            workspaces: snapshot.workspaces.filter { $0.workspaceId != holding },
            tabs: tabs,
            panes: panes,
            agents: snapshot.agents.filter { $0.workspaceId != holding && paneIds.contains($0.paneId) },
            focusedWorkspaceId: snapshot.focusedWorkspaceId == holding ? nil : snapshot.focusedWorkspaceId,
            focusedTabId: snapshot.focusedTabId.flatMap { tabIds.contains($0) ? $0 : nil },
            focusedPaneId: snapshot.focusedPaneId.flatMap { paneIds.contains($0) ? $0 : nil }
        )
    }

    /// The pane each record's terminal is in now, inside the holding workspace.
    static func panes(for records: [ClosedTabRecord], in snapshot: EngineSnapshot) -> [String: EnginePane] {
        guard let holding = holdingWorkspace(in: snapshot)?.workspaceId else { return [:] }
        var found: [String: EnginePane] = [:]
        for pane in snapshot.panes where pane.workspaceId == holding {
            if let terminal = pane.terminalId, records.contains(where: { $0.terminalId == terminal }) {
                found[terminal] = pane
            }
        }
        return found
    }

    /// Records kept: still waiting in the holding workspace, and not past
    /// `keep`. A pane there that Octet has no record of (its list was lost)
    /// is adopted as closed now, so it still expires.
    static func reconcile(_ records: [ClosedTabRecord], with snapshot: EngineSnapshot,
                          now: Date = Date()) -> [ClosedTabRecord] {
        guard let holding = holdingWorkspace(in: snapshot)?.workspaceId else { return [] }
        let waiting = snapshot.panes.filter { $0.workspaceId == holding }
        let live = Set(waiting.compactMap(\.terminalId))
        var kept = records.filter { live.contains($0.terminalId) }
        for pane in waiting {
            guard let terminal = pane.terminalId, !kept.contains(where: { $0.terminalId == terminal }) else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            kept.append(ClosedTabRecord(terminalId: terminal, title: tab?.label ?? "Closed tab",
                                        workspaceId: nil, workspaceLabel: "", cwd: pane.effectiveCwd,
                                        command: nil, closedAt: now))
        }
        return kept.sorted { $0.closedAt < $1.closedAt }
    }

    /// Records whose grace period has run out.
    static func expired(_ records: [ClosedTabRecord], keep: TimeInterval, now: Date = Date()) -> [ClosedTabRecord] {
        records.filter { now.timeIntervalSince($0.closedAt) >= keep }
    }
}

/// On-disk list: `~/Library/Application Support/Octet/closed-tabs.json`.
struct ClosedTabsJournal: Codable, Equatable {
    var records: [ClosedTabRecord] = []

    static func load(from url: URL) -> ClosedTabsJournal {
        guard let data = try? Data(contentsOf: url) else { return ClosedTabsJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ClosedTabsJournal.self, from: data)) ?? ClosedTabsJournal()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
