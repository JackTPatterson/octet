import Foundation

/// A conversation, written down so another can pick it up: what was asked,
/// where it got to, the plan, the files it changed and the last commands it
/// ran. Built from the transcript alone, with no model in the loop, so it is
/// instant and says only what happened. Used to carry on in another agent
/// when one hits its limit, and to start fresh when a conversation has
/// grown too long.
enum HandoffBrief {
    enum Reason: Equatable {
        /// The agent hit its usage limit.
        case limit
        /// Moving the work to another agent.
        case switching(from: String)
        /// The same agent, a clean context.
        case fresh
        /// Set aside until something outside it happened, which now has.
        case waited(on: String)
    }

    struct Input {
        var agentName: String
        var cwd: String
        var branch: String?
        var items: [AgentItem]
        var reason: Reason

        init(agentName: String, cwd: String, branch: String? = nil, items: [AgentItem], reason: Reason) {
            self.agentName = agentName
            self.cwd = cwd
            self.branch = branch
            self.items = items
            self.reason = reason
        }
    }

    /// The most a brief says; a long one costs the new conversation what the
    /// old one was running out of.
    static let limit = 6000

    static func build(_ input: Input) -> String {
        var sections: [String] = []
        let place = abbreviate(input.cwd) + (input.branch.map { " on \($0)" } ?? "")
        sections.append(opening(input, place: place))

        let asked = requests(in: input.items)
        if !asked.isEmpty {
            sections.append("## What was asked\n" + asked.map { "- " + clip($0, $0 == asked.first ? 700 : 300) }.joined(separator: "\n"))
        }
        if let last = lastReply(in: input.items) {
            sections.append("## Where it got to\n" + clip(last, 900))
        }
        if let todos = AgentTodos.latest(in: input.items), !todos.isEmpty {
            let lines = todos.prefix(20).map { "- [\($0.status == .completed ? "x" : " ")] \(clip($0.text, 140))" }
            sections.append("## The plan\n" + lines.joined(separator: "\n"))
        }
        let files = changedFiles(in: input.items, cwd: input.cwd)
        if !files.isEmpty {
            let shown = files.prefix(25).map { "- \($0.path)" + ($0.edits > 1 ? " (\($0.edits) edits)" : "") }
            let more = files.count > 25 ? ["- and \(files.count - 25) more"] : []
            sections.append("## Files it changed\n" + (shown + more).joined(separator: "\n"))
        }
        let commands = lastCommands(in: input.items, count: 5)
        if !commands.isEmpty {
            sections.append("## The last commands it ran\n" + commands.map { "- `\(clip($0.command, 160))`" + ($0.failed ? " (failed)" : "") }.joined(separator: "\n"))
        }
        if let check = Verification.assess(input.items).message {
            sections.append("## Checks\n\(check).")
        }
        sections.append("Look at `git status` and `git diff` for the real state of the files, then carry on from here. Don't redo what's already done.")
        return clip(sections.joined(separator: "\n\n"), limit)
    }

    private static func opening(_ input: Input, place: String) -> String {
        switch input.reason {
        case .limit:
            "Carrying on work started in \(input.agentName) in \(place). That conversation stopped because it hit its usage limit."
        case .switching(let from):
            "Carrying on work started in \(from) in \(place)."
        case .fresh:
            "Carrying on work in \(place). The conversation had grown long, so this one starts clean with a summary of it."
        case .waited(let on):
            "Carrying on work started in \(input.agentName) in \(place), set aside until \(on). That has happened, and the conversation it was in is gone, so this is a summary of it."
        }
    }

    // MARK: - Reading the transcript

    /// What the person asked: the first message, and the last few after it.
    static func requests(in items: [AgentItem]) -> [String] {
        let messages = items.compactMap { item -> String? in
            guard case .user(let text) = item.kind, !item.queued else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.hasPrefix("/") ? nil : trimmed
        }
        guard messages.count > 6 else { return messages }
        return [messages[0]] + messages.suffix(5)
    }

    /// The last thing the agent itself said (not a subagent's).
    static func lastReply(in items: [AgentItem]) -> String? {
        for item in items.reversed() where item.parent == nil {
            if case .text(let text) = item.kind {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// The files edited, in the order first touched, with how often.
    static func changedFiles(in items: [AgentItem], cwd: String) -> [(path: String, edits: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            guard case .tool(let call) = item.kind else { continue }
            for path in Recap.editedPaths(call) {
                let shown = relative(path, to: cwd)
                if counts[shown] == nil { order.append(shown) }
                counts[shown, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0] ?? 1) }
    }

    static func lastCommands(in items: [AgentItem], count: Int) -> [(command: String, failed: Bool)] {
        let all = items.compactMap { item -> (String, Bool)? in
            guard case .tool(let call) = item.kind, Recap.isCommand(call.name) else { return nil }
            let command = (call.inputObject?["command"] as? String) ?? call.summary
            let flat = command.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return flat.isEmpty ? nil : (flat, call.isError)
        }
        return all.suffix(count).map { (command: $0.0, failed: $0.1) }
    }

    // MARK: - Text

    static func relative(_ path: String, to cwd: String) -> String {
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Cut at a word, with an ellipsis.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
