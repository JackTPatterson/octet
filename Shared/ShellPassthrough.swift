import Foundation

/// `!` in a conversation's composer, as in Claude Code's terminal: the rest
/// of the line runs in the conversation's folder, its output shows in the
/// conversation, and it goes to the agent with your next message so it
/// knows what you saw. Nothing is sent to the agent when the command runs.
/// OpenCode runs `!` itself; every other agent gets it from Octet.
enum ShellPassthrough {
    struct Run: Equatable {
        var command: String
        var output: String
        var status: Int32?
    }

    /// The command in `!command`, or nil when the message isn't one.
    static func command(in message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return nil }
        let command = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// How much output goes to the agent per command.
    static let outputLimit = 6000

    /// Long output, kept to its start and its end, where errors and
    /// summaries usually are.
    static func clip(_ output: String, limit: Int = outputLimit) -> String {
        guard output.count > limit else { return output }
        let head = output.prefix(limit / 3)
        let tail = output.suffix(limit - limit / 3)
        let skipped = output.count - head.count - tail.count
        return head + "\n… \(skipped) characters left out …\n" + tail
    }

    /// What goes before your next message: each command and what it printed,
    /// in the tags Claude Code uses for its own `!` commands.
    static func context(_ runs: [Run]) -> String {
        let blocks = runs.map { run in
            var block = "<bash-input>\(run.command)</bash-input>\n<bash-stdout>\(clip(run.output))</bash-stdout>"
            if let status = run.status, status != 0 { block += "\n<bash-exit-code>\(status)</bash-exit-code>" }
            return block
        }
        let lead = runs.count == 1
            ? "I ran this command myself in the project folder; here's what it printed:"
            : "I ran these commands myself in the project folder; here's what they printed:"
        return ([lead] + blocks).joined(separator: "\n\n")
    }

    /// The message the agent gets: the commands' output, then yours. A
    /// slash command goes as it is, so it still works; the output waits for
    /// the next ordinary message.
    static func outgoing(_ message: String, runs: [Run]) -> (text: String, usedRuns: Bool) {
        guard !runs.isEmpty, !message.hasPrefix("/") else { return (message, false) }
        return (context(runs) + "\n\n" + message, true)
    }
}
