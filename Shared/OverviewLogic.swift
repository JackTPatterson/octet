import Foundation

// The pure decisions behind the Overview tab's sections, kept apart from the
// views so they can be tested: what state a runtime is in, where a tree's
// connector lines go, how far a plan has got, how a TODO.md is grouped, how
// Agent Setup is summed up, which sections are folded, and which fold away
// to a single quiet line.

// MARK: - Runtime rows

/// Where a subagent, task or monitor stands, in the shared vocabulary
/// (`AgentState`), from real signals rather than the words a row shows: a
/// tool call's error flag and result, the session server's status.
enum RuntimeStates {
    /// A subagent started by a conversation's Agent/Task call: failed when
    /// the call errored, done once it returned, otherwise still working.
    static func subagent(isError: Bool, hasResult: Bool) -> AgentState {
        if isError { return .failed }
        return hasResult ? .done : .working
    }

    /// A subagent in a tab of its own, as the session server reports it.
    /// Unknown is still a running process: it reads as working.
    static func subagentTab(_ status: EngineAgentStatus) -> AgentState {
        status == .unknown ? .working : AgentState(status)
    }

    /// A background shell command: running until its call errors. A
    /// background call returns at once ("running in background"), so a
    /// result alone doesn't mean it's finished.
    static func backgroundTask(isError: Bool, exitCode: Int?) -> AgentState {
        if isError { return .failed }
        if let exitCode { return exitCode == 0 ? .done : .failed }
        return .working
    }

    /// A background task's exit code, when its output says ("exit code 2",
    /// "exited with code 2", "Exit code: 2").
    static func exitCode(in output: String?) -> Int? {
        guard let output else { return nil }
        let pattern = #"(?i)exit(?:ed)?(?: with)? code:? *(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[range])
    }

    /// "1 subagent", "3 subagents".
    static func subagentCount(_ count: Int) -> String {
        count == 1 ? "1 subagent" : "\(count) subagents"
    }
}

/// The panel's count line ("2 working · 1 needs you · 1 failed · 3 done"),
/// from the rows' states.
enum RuntimeCount {
    struct Count: Equatable {
        let count: Int
        let label: String
        /// The loudest state counted, for its colour.
        let state: AgentState
    }

    /// The Agents tab's header: one part per bucket that has anything
    /// ("1 needs you · 3 working · 2 done"), each the colour of its loudest
    /// state. Idle isn't counted: a quiet agent isn't news.
    static func buckets(_ states: [AgentState]) -> [(bucket: AgentState.Bucket, count: Int, label: String, state: AgentState)] {
        [AgentState.Bucket.needsYou, .working, .done].compactMap { bucket in
            let matched = states.filter { $0.bucket == bucket }
            guard !matched.isEmpty else { return nil }
            let label: String = switch bucket {
            case .needsYou: matched.count == 1 ? "needs you" : "need you"
            case .working: "working"
            case .done: "done"
            case .idle: "idle"
            }
            return (bucket, matched.count, label, AgentState.rollUp(matched))
        }
    }

    static func counts(_ states: [AgentState]) -> [Count] {
        let groups: [(label: (Int) -> String, match: (AgentState) -> Bool)] = [
            ({ $0 == 1 ? "needs you" : "need you" }, { $0.needsYou || $0 == .planReady }),
            ({ _ in "failed" }, { $0 == .failed }),
            ({ _ in "working" }, { $0.bucket == .working }),
            ({ _ in "done" }, { $0 == .done }),
        ]
        return groups.compactMap { group in
            let matched = states.filter(group.match)
            guard !matched.isEmpty else { return nil }
            return Count(count: matched.count, label: group.label(matched.count), state: AgentState.rollUp(matched))
        }
    }
}

/// A plan's steps as a strip of up to ten segments (T3 Code's and Warp's
/// task meter): one per step, or per group of steps in a longer plan.
struct TodoMeter: Equatable {
    let segments: [AgentTodo.Status]
    let done: Int
    let total: Int

    static let maxSegments = 10

    init?(_ statuses: [AgentTodo.Status]) {
        guard !statuses.isEmpty else { return nil }
        total = statuses.count
        done = statuses.filter { $0 == .completed }.count
        if statuses.count <= Self.maxSegments {
            segments = statuses
        } else {
            // A longer plan: each segment stands for a run of steps, and
            // reads as its least finished step.
            let per = Double(statuses.count) / Double(Self.maxSegments)
            segments = (0..<Self.maxSegments).map { index in
                let slice = statuses[Int((Double(index) * per).rounded(.down))..<min(statuses.count, Int((Double(index + 1) * per).rounded(.down)))]
                if slice.contains(.inProgress) { return .inProgress }
                if slice.contains(.pending) { return .pending }
                return .completed
            }
        }
    }

    /// "3/7".
    var label: String { "\(done)/\(total)" }
    /// "3 of 7 tasks complete".
    var spoken: String { "\(done) of \(total) tasks complete" }
}

/// What a runtime row says beside its state.
enum RuntimeText {
    /// The detail worth saying beside the icon: nothing for the generic words
    /// that the icon already says ("Running", "Active"), the word itself for
    /// a state the icon alone doesn't spell out, a countdown as it is.
    static func label(forDetail detail: String) -> String? {
        let generic: Set<String> = ["running", "working", "active", "background", "watching", "model", "parent", ""]
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        return generic.contains(trimmed.lowercased()) ? nil : trimmed
    }

    /// The last non-empty line of some output, for a one-line preview.
    static func lastLine(of output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// How long ago, as Orca's dashboard says it: "just now", "4m", "2h", "3d".
    static func ago(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "just now" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h" }
        return "\(total / 86_400)d"
    }

    /// The first non-empty line, for a result or an error on one line.
    static func firstLine(of output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// How one row of a tree hangs off the rows above it: a line down each level
/// that still has siblings coming, and an elbow (closing, if it's the last
/// child) at its own level.
struct TreeGuide: Equatable {
    /// One per ancestor level above the elbow: a line runs through it.
    var verticals: [Bool]
    /// The last child of its parent, so the elbow ends the line.
    var isLast: Bool
}

enum TreeGuides {
    /// `depths` is each row's depth, in display order (a parent before its
    /// children, as `RuntimeTree.order` gives them).
    static func compute(depths: [Int]) -> [TreeGuide] {
        depths.indices.map { index in
            let depth = depths[index]
            guard depth > 0 else { return TreeGuide(verticals: [], isLast: true) }
            func continues(at level: Int) -> Bool {
                for next in depths[(index + 1)...] {
                    if next == level { return true }
                    if next < level { return false }
                }
                return false
            }
            return TreeGuide(verticals: (0..<(depth - 1)).map { continues(at: $0 + 1) },
                             isLast: !continues(at: depth))
        }
    }
}

// MARK: - Todos

/// How far a plan has got.
struct TodoProgress: Equatable {
    let done: Int
    let total: Int

    init(_ todos: [AgentTodo]) {
        total = todos.count
        done = todos.completedCount
    }

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var isComplete: Bool { total > 0 && done == total }
    var remaining: Int { total - done }
    /// "3 of 5", or "Done" once every step is.
    var summary: String { isComplete ? "Done" : "\(done) of \(total)" }
}

enum TodoSteps {
    /// A plan's steps split for the panel: the ones still to do, in the
    /// agent's order with the step under way marked by its status, and the
    /// finished ones that fold behind "n done".
    static func split(_ todos: [AgentTodo]) -> (open: [AgentTodo], done: [AgentTodo]) {
        (todos.filter { $0.status != .completed }, todos.filter { $0.status == .completed })
    }
}

/// A TODO.md's items under their headings.
struct ProjectTodoGroup: Equatable, Identifiable {
    /// The `#` heading, nil for items above any heading.
    let title: String?
    let items: [ProjectTodoList.Item]
    var id: String { title ?? "" }
}

enum ProjectTodoGrouping {
    /// Items by heading, headings in the order they first appear, so a
    /// heading met twice in the file is one group.
    static func groups(_ items: [ProjectTodoList.Item]) -> [ProjectTodoGroup] {
        var order: [String?] = []
        var byTitle: [String?: [ProjectTodoList.Item]] = [:]
        for item in items {
            if byTitle[item.section] == nil { order.append(item.section) }
            byTitle[item.section, default: []].append(item)
        }
        return order.map { ProjectTodoGroup(title: $0, items: byTitle[$0] ?? []) }
    }
}

// MARK: - Agent Setup

enum AgentSetupSummary {
    static func isMCP(_ rule: String) -> Bool { rule.hasPrefix("mcp__") }

    /// "12 allowed commands · 2 MCP"; nil when nothing is allowed. Counts
    /// each rule once however many files hold it.
    static func summary(rules: [String]) -> String? {
        let unique = Array(Set(rules))
        let mcp = unique.filter(isMCP).count
        let commands = unique.count - mcp
        var parts: [String] = []
        if commands > 0 { parts.append(commands == 1 ? "1 allowed command" : "\(commands) allowed commands") }
        if mcp > 0 { parts.append("\(mcp) MCP") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A rule as the person would say it: `Bash(git status:*)` is
    /// "git status *", `mcp__linear__create_issue` is "linear · create_issue".
    /// Anything else stays as written.
    static func display(rule: String) -> String {
        if rule.hasPrefix("Bash("), rule.hasSuffix(")") {
            let inner = String(rule.dropFirst(5).dropLast())
            return inner.hasSuffix(":*") ? String(inner.dropLast(2)) + " *" : inner
        }
        if isMCP(rule) {
            let parts = rule.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return "\(parts[0]) · \(parts.dropFirst().joined(separator: " · "))" }
            if let only = parts.first, !only.isEmpty { return only }
        }
        return rule
    }
}

// MARK: - Folding

/// Which sections are folded. Most open until folded; one that starts
/// folded (Agent Setup) stays so until opened, and both are remembered.
struct FoldState: Equatable {
    var folded: Set<String> = []
    var opened: Set<String> = []

    func isOpen(_ key: String, opensByDefault: Bool = true) -> Bool {
        opensByDefault ? !folded.contains(key) : opened.contains(key)
    }

    mutating func set(_ key: String, open: Bool, opensByDefault: Bool = true) {
        if opensByDefault {
            if open { folded.remove(key) } else { folded.insert(key) }
        } else {
            if open { opened.insert(key) } else { opened.remove(key) }
        }
    }
}

enum OverviewSections {
    /// A section with nothing in it folds to a single quiet line (its title
    /// and "None"), unless it's still being read, when it shows its skeleton.
    static func isQuiet(count: Int, loading: Bool) -> Bool { count == 0 && !loading }
}
