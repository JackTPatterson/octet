import Foundation

/// Layout decisions shared by the native panel and its regression tests.
enum AgentPresentationLogic {
    /// Only a real, uninspected process root can require an initial skeleton.
    /// Idle conversations have no root; an empty completed scan is valid data.
    static func showsInitialRuntimeLoading(rowCount: Int, scanning: Bool,
                                           hasUnscannedPane: Bool, hasUnscannedNativeRoot: Bool) -> Bool {
        rowCount == 0 && scanning && (hasUnscannedPane || hasUnscannedNativeRoot)
    }
    // The selected agent view must never change terminal geometry. Only an
    // explicit panel resize or a window resize changes this width.
    static func panelWidth(normal: CGFloat, available: CGFloat) -> CGFloat {
        min(normal, max(260, available - 300))
    }
    static func visibleIDs(_ ordered: [(id: String, depth: Int)], collapsed: Set<String>) -> Set<String> {
        var hiddenDepth: Int?
        var visible = Set<String>()
        for row in ordered {
            if let hidden = hiddenDepth, row.depth > hidden { continue }
            visible.insert(row.id)
            hiddenDepth = collapsed.contains(row.id) ? row.depth : nil
        }
        return visible
    }
}

/// How the Agents tab arranges a workspace: one group per root agent (a
/// terminal agent or a conversation), the tree of what it started under it.
enum RuntimeGrouping {
    struct Group: Equatable {
        let id: String
        let focused: Bool
        let state: AgentState
        let recency: Date?
    }

    /// The focused root first, then the loudest state, then the most recent.
    static func order(_ groups: [Group]) -> [String] {
        groups.sorted { a, b in
            if a.focused != b.focused { return a.focused }
            if a.state.priority != b.state.priority { return a.state.priority > b.state.priority }
            let ra = a.recency ?? .distantPast, rb = b.recency ?? .distantPast
            if ra != rb { return ra > rb }
            return a.id < b.id
        }.map(\.id)
    }

    /// Which groups start open: all of up to three; past that the focused
    /// one (or the first, when none is).
    static func initiallyExpanded(_ ordered: [String], focused: String?) -> Set<String> {
        if ordered.count <= 3 { return Set(ordered) }
        if let focused, ordered.contains(focused) { return [focused] }
        return Set(ordered.prefix(1))
    }

    struct Row: Equatable {
        let id: String
        let parent: String?
        let finished: Bool
    }

    /// The rows that fold into "Finished (n)": finished ones with nothing
    /// unfinished beneath them, so a live subagent never loses its parent.
    static func finished(_ rows: [Row]) -> Set<String> {
        var live = Set<String>()
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where !row.finished {
            var parent = row.parent
            var seen = Set<String>()
            while let id = parent, seen.insert(id).inserted {
                live.insert(id)
                parent = byID[id]?.parent
            }
        }
        return Set(rows.filter { $0.finished && !live.contains($0.id) }.map(\.id))
    }

    /// "3 subagents · 2 tasks · 1 monitor", for a group's header.
    static func summary(subagents: Int, tasks: Int, monitors: Int) -> String {
        var parts: [String] = []
        if subagents > 0 { parts.append(subagents == 1 ? "1 subagent" : "\(subagents) subagents") }
        if tasks > 0 { parts.append(tasks == 1 ? "1 task" : "\(tasks) tasks") }
        if monitors > 0 { parts.append(monitors == 1 ? "1 monitor" : "\(monitors) monitors") }
        return parts.joined(separator: " · ")
    }
}

/// Which finished rows in the Agents tab have been seen, and which were
/// dismissed. A subagent or task that finished or failed while you were
/// elsewhere is unread until you open it, go to it, or mark it read (Warp's
/// rules). Root agents' unread state is `AttentionRouter`'s, not this.
struct RuntimeSeen: Codable, Equatable {
    /// Oldest first, so the oldest go when the list is full.
    private(set) var seen: [String] = []
    private(set) var dismissed: [String] = []
    static let limit = 2000

    init() {}

    /// Finished or failed and not yet seen.
    func isUnread(id: String, state: AgentState) -> Bool {
        (state == .done || state == .failed) && !seen.contains(id)
    }

    func isDismissed(_ id: String) -> Bool { dismissed.contains(id) }

    mutating func markRead<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids where !seen.contains(id) { seen.append(id) }
        if seen.count > Self.limit { seen.removeFirst(seen.count - Self.limit) }
    }

    mutating func markUnread(_ id: String) { seen.removeAll { $0 == id } }

    mutating func dismiss<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids where !dismissed.contains(id) { dismissed.append(id) }
        if dismissed.count > Self.limit { dismissed.removeFirst(dismissed.count - Self.limit) }
        markRead(ids)
    }

    mutating func restore<S: Sequence>(_ ids: S) where S.Element == String {
        let ids = Set(ids)
        dismissed.removeAll { ids.contains($0) }
    }
}

/// Background jobs' state files, read again only when they change: the
/// panel used to read each one from disk on every redraw.
final class BackgroundJobCache {
    private var cache: [String: (modified: Date?, job: BackgroundJob?)] = [:]

    func load(id: String, home: String = NSHomeDirectory()) -> BackgroundJob? {
        let path = home + "/.claude/jobs/" + id + "/state.json"
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = cache[id], hit.modified == modified { return hit.job }
        let job = BackgroundJob.load(id: id, home: home)
        cache[id] = (modified, job)
        return job
    }
}
