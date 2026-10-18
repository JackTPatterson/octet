import Foundation

// The pure decisions behind the Overview tab's sections, kept apart from the
// views so they can be tested: what state a runtime is in, where a tree's
// connector lines go, how far a plan has got, how a TODO.md is grouped, how
// Agent Setup is summed up, which sections are folded, and which fold away
// to a single quiet line.

// MARK: - Runtime rows

/// Where a subagent, task or monitor stands, drawn as an icon as well as a
/// colour so it never rests on colour alone.
enum RuntimeState: Equatable {
    case running, waiting, failed, done

    /// Read from the word the row carries ("Running", "Needs input", "Failed", …).
    /// Anything that isn't one of the others is under way: a timer, a
    /// countdown, "Active", "Watching".
    static func classify(detail: String) -> RuntimeState {
        let text = detail.lowercased()
        if text.contains("fail") || text.contains("error") || text.contains("exited") || text.contains("crash") {
            return .failed
        }
        if text.contains("needs input") || text.contains("waiting") || text.contains("paused") {
            return .waiting
        }
        if text.contains("finished") || text.contains("done") || text.contains("complete") {
            return .done
        }
        return .running
    }

    /// The detail worth saying beside the icon: nothing for the generic words
    /// that the icon already says ("Running", "Active"), the word itself for
    /// a state the icon alone doesn't spell out, a countdown as it is.
    static func label(forDetail detail: String) -> String? {
        let generic: Set<String> = ["running", "working", "active", "background", "watching", "model", "parent", ""]
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        return generic.contains(trimmed.lowercased()) ? nil : trimmed
    }

    var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .done: "Finished"
        }
    }

    /// The last non-empty line of some output, for a one-line preview.
    static func lastLine(of output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
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
