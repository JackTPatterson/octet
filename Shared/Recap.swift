import Foundation

/// What every agent did while you were away from Octet, from Octet's own
/// record of each run: what it changed and ran, how it ended, and what it
/// said last. Conversations in Octet are read off their transcripts, item by
/// item since you left; agents running in a terminal by the status changes
/// Octet saw.
struct Recap: Equatable {
    /// How a run stands now, most urgent first.
    enum Outcome: Int, Comparable, CaseIterable {
        case needsYou, stuck, finished, working

        static func < (lhs: Outcome, rhs: Outcome) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .stuck: "Stuck"
            case .finished: "Finished"
            case .working: "Still working"
            }
        }
    }

    struct Run: Identifiable, Equatable {
        enum Source: Equatable {
            /// An Octet conversation, by its session id.
            case conversation(String)
            /// An agent in a terminal pane.
            case terminal(paneId: String, tabId: String?)
        }

        let id: String
        let source: Source
        /// `claude`, `codex`, …
        let agent: String?
        let title: String
        let workspaceId: String?
        var outcome: Outcome
        /// Paths edited, in the order first touched, without repeats.
        var files: [String] = []
        var commands = 0
        var toolCalls = 0
        var failedTools = 0
        /// Turns that ran to the end.
        var turns = 0
        /// What it's asking, when it needs you; why, when it's stuck.
        var reason: String?
        /// The last thing it said.
        var lastMessage: String?
        var workedFor: TimeInterval?
        /// Whether what it edited was tested afterwards.
        var verification: Verification?
        /// When it last did something, for reading the latest first.
        var lastActivity: Date?

        /// "Edited 4 files · ran 7 commands · worked 12m".
        var summary: String {
            var parts: [String] = []
            if !files.isEmpty { parts.append("edited \(Recap.count(files.count, "file"))") }
            if commands > 0 { parts.append("ran \(Recap.count(commands, "command"))") }
            if parts.isEmpty, toolCalls > 0 { parts.append("used \(Recap.count(toolCalls, "tool"))") }
            if failedTools > 0 { parts.append("\(failedTools) failed") }
            if let worked = AgentActivityWatcher.durationLabel(workedFor) { parts.append("worked \(worked)") }
            if parts.isEmpty { return outcome == .working ? "Started working" : "No changes" }
            let line = parts.joined(separator: " · ")
            return line.prefix(1).uppercased() + line.dropFirst()
        }
    }

    let leftAt: Date
    let cameBackAt: Date
    var runs: [Run]

    var away: TimeInterval { cameBackAt.timeIntervalSince(leftAt) }

    /// Worth a card: something happened, beyond a run that was already
    /// working and still is with nothing new.
    var isWorthShowing: Bool { !runs.isEmpty }

    func runs(_ outcome: Outcome) -> [Run] { runs.filter { $0.outcome == outcome } }

    /// "3 finished, 1 needs you".
    var headline: String {
        let parts = Outcome.allCases.compactMap { outcome -> String? in
            let count = runs(outcome).count
            guard count > 0 else { return nil }
            switch outcome {
            case .needsYou: return "\(count) need\(count == 1 ? "s" : "") you"
            case .stuck: return "\(count) stuck"
            case .finished: return "\(count) finished"
            case .working: return "\(count) still working"
            }
        }
        return parts.isEmpty ? "Nothing happened" : parts.joined(separator: ", ")
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// Runs in the order to read them: what needs you first, then the one
    /// that did something most recently.
    static func ordered(_ runs: [Run]) -> [Run] {
        runs.sorted { a, b in
            if a.outcome != b.outcome { return a.outcome < b.outcome }
            let at = a.lastActivity ?? .distantPast, bt = b.lastActivity ?? .distantPast
            if at != bt { return at > bt }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// What's new in `self` next to what's still unread in `older`: runs
    /// from this time, then the older ones not looked at yet that this
    /// time has nothing new on. Coming back twice before reading the first
    /// recap keeps both.
    func merged(unread older: Recap?) -> Recap {
        guard let older else { return self }
        let ids = Set(runs.map(\.id))
        let kept = older.runs.filter { !ids.contains($0.id) }
        return Recap(leftAt: min(leftAt, older.leftAt), cameBackAt: cameBackAt, runs: Recap.ordered(runs + kept))
    }

    /// Whether it should open itself: something needs you or is stuck.
    var isUrgent: Bool { runs.contains { $0.outcome == .needsYou || $0.outcome == .stuck } }
}

/// When you count as away from Octet, for the recap: the screen is locked
/// or asleep, no Octet window can be seen (hidden, minimised or covered;
/// another app in front with Octet still on screen is you still there), or
/// you haven't touched the Mac for `idleAfter`, which counts from when you
/// last did.
enum RecapPresence {
    struct Signals: Equatable {
        var locked = false
        var octetVisible = true
        /// Seconds since the last keyboard, mouse or trackpad input.
        var idleSeconds: TimeInterval = 0
    }

    /// Since when you've been away, or nil while you're here.
    static func awaySince(_ signals: Signals, now: Date, idleAfter: TimeInterval) -> Date? {
        if signals.locked || !signals.octetVisible { return now }
        if signals.idleSeconds >= idleAfter { return now.addingTimeInterval(-signals.idleSeconds) }
        return nil
    }
}

// MARK: - Conversations

extension Recap {
    /// Where a conversation stood when you left.
    struct ConversationMark: Equatable {
        var itemIds: Set<String>
        var wasRunning: Bool
        var lastError: String?
    }

    /// How a conversation stands now.
    struct ConversationNow {
        var id: String
        var agent: String?
        var title: String
        var workspaceId: String?
        var items: [AgentItem]
        var isRunning: Bool
        var lastError: String?
        /// The permission or question it's waiting on, if any.
        var waitingOn: String?
    }

    /// What a conversation did since `mark`; nil when it did nothing and
    /// isn't waiting on you.
    static func run(_ now: ConversationNow, since mark: ConversationMark) -> Run? {
        let new = now.items.filter { !mark.itemIds.contains($0.id) }
        var run = Run(id: "conversation-\(now.id)", source: .conversation(now.id), agent: now.agent,
                      title: now.title, workspaceId: now.workspaceId, outcome: .finished)
        var seenFiles = Set<String>()
        for item in new {
            switch item.kind {
            case .tool(let call):
                run.toolCalls += 1
                if call.isError { run.failedTools += 1 }
                if isCommand(call.name) { run.commands += 1 }
                for path in editedPaths(call) where seenFiles.insert(path).inserted { run.files.append(path) }
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, item.parent == nil { run.lastMessage = excerpt(trimmed) }
            case .user:
                // Each message sent starts a turn; one sent before you left
                // and still running counts when it ends.
                break
            case .thinking, .notice:
                break
            }
        }
        // Subagents' own tool calls show in the counts; their messages don't
        // stand in for the main agent's.
        let times = new.map(\.createdAt)
        if let first = times.min(), let last = times.max(), last > first { run.workedFor = last.timeIntervalSince(first) }
        run.lastActivity = times.max()
        let verdict = Verification.assess(new)
        if verdict != .noEdits { run.verification = verdict }
        let userTurns = new.filter { if case .user = $0.kind { return true } else { return false } }.count
        let ended = (mark.wasRunning ? 1 : 0) + userTurns - (now.isRunning ? 1 : 0)
        run.turns = max(ended, 0)

        let newError = now.lastError.flatMap { $0 != mark.lastError ? $0 : nil }
        if let waiting = now.waitingOn {
            run.outcome = .needsYou
            run.reason = waiting
        } else if let newError {
            run.outcome = .stuck
            run.reason = excerpt(newError)
        } else if now.isRunning {
            run.outcome = .working
            // Already working when you left and nothing new to say: leave it out.
            if new.isEmpty { return nil }
        } else if new.isEmpty && !mark.wasRunning {
            return nil
        } else {
            run.outcome = .finished
        }
        return run
    }

    static func isCommand(_ tool: String) -> Bool {
        ["Bash", "BashOutput", "Shell", "shell", "bash", "exec_command"].contains(tool)
    }

    /// The files a tool call changed: an edit's path, Codex's changes, or
    /// the files a patch names.
    static func editedPaths(_ call: AgentToolCall) -> [String] {
        let edits: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "ApplyPatch", "apply_patch"]
        guard edits.contains(call.name), !call.isError else { return [] }
        let input = call.inputObject ?? [:]
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String {
            return [path]
        }
        if let changes = input["changes"] as? [[String: Any]] {
            return changes.compactMap { $0["path"] as? String }
        }
        // A patch: its "*** Update File: x" lines.
        let text = (input["patch"] as? String) ?? (input["input"] as? String) ?? call.input
        var paths: [String] = []
        for line in text.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                paths.append(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if paths.isEmpty, !call.summary.isEmpty, call.name == "Edit" {
            // Codex's file changes keep only names in the summary.
            paths = call.summary.components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        return paths
    }

    /// One or two lines of what it said: the first paragraph, cut short.
    static func excerpt(_ text: String, limit: Int = 220) -> String {
        let paragraph = text.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        let flat = paragraph.split(whereSeparator: \.isNewline).map { plain(String($0)) }.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// A line of Markdown as it reads: no heading, quote or bullet marks,
    /// no emphasis or code ticks, links as their text.
    static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["###### ", "##### ", "#### ", "### ", "## ", "# ", "> ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
            break
        }
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        return text
    }
}

// MARK: - Agents in the terminal

extension Recap {
    /// The status changes of agents running in terminals while you're away.
    struct TerminalLog: Equatable {
        struct Pane: Equatable {
            var agent: String?
            var title: String
            var tabId: String?
            var workspaceId: String?
            var first: EngineAgentStatus
            var last: EngineAgentStatus
            var finishedTimes = 0
            var worked: TimeInterval = 0
            var workingSince: Date?
            /// When its status last changed.
            var changedAt: Date?
        }

        private(set) var panes: [String: Pane] = [:]

        init() {}

        /// Takes in one snapshot.
        mutating func observe(_ snapshot: EngineSnapshot, now: Date = Date()) {
            let labels = Dictionary(snapshot.tabs.map { ($0.tabId, $0.label) }, uniquingKeysWith: { first, _ in first })
            for agent in snapshot.agents where !agent.isSubagentViewer {
                let status = agent.agentStatus
                let label = agent.tabId.flatMap { labels[$0] } ?? ""
                let title = TabAutoName.isUnnamed(label) ? (AgentBrand.forAgent(agent.agent)?.displayName ?? agent.name ?? "Agent") : label
                guard var pane = panes[agent.paneId] else {
                    panes[agent.paneId] = Pane(agent: agent.agent, title: title, tabId: agent.tabId, workspaceId: agent.workspaceId,
                                               first: status, last: status, workingSince: status == .working ? now : nil)
                    continue
                }
                pane.title = title
                if status != pane.last {
                    if pane.last == .working, let since = pane.workingSince {
                        pane.worked += now.timeIntervalSince(since)
                        pane.workingSince = nil
                        if status == .done || status == .idle { pane.finishedTimes += 1 }
                    }
                    if status == .working { pane.workingSince = now }
                    pane.last = status
                    pane.changedAt = now
                }
                panes[agent.paneId] = pane
            }
        }

        /// What each pane did, as runs; panes where nothing changed are left out.
        func runs(now: Date = Date()) -> [Run] {
            panes.compactMap { paneId, pane in
                var worked = pane.worked
                if let since = pane.workingSince { worked += now.timeIntervalSince(since) }
                let outcome: Outcome
                switch pane.last {
                case .blocked: outcome = .needsYou
                case .working:
                    // Working when you left and working still, without a stop between.
                    guard pane.first != .working || pane.finishedTimes > 0 else { return nil }
                    outcome = .working
                case .done, .idle:
                    guard pane.finishedTimes > 0 else { return nil }
                    outcome = .finished
                case .unknown:
                    return nil
                }
                var run = Run(id: "terminal-\(paneId)", source: .terminal(paneId: paneId, tabId: pane.tabId), agent: pane.agent,
                              title: pane.title, workspaceId: pane.workspaceId, outcome: outcome)
                run.turns = pane.finishedTimes
                run.workedFor = worked > 0 ? worked : nil
                run.lastActivity = pane.changedAt
                if outcome == .needsYou { run.reason = "Waiting on you in its terminal" }
                return run
            }
        }
    }
}
