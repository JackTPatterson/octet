import Foundation

/// Best of N: one task given to several agents at once, each in a worktree
/// of its own from the same commit, so their work can be compared and the
/// best kept (Conductor's and Crystal's way of working).
enum BestOfN {
    /// One agent's go at the task.
    struct Attempt: Codable, Equatable, Identifiable {
        let task: String
        let agent: String
        let branch: String
        let checkout: String
        /// The commit every attempt started from, to compare against.
        let base: String
        let started: Date
        var id: String { checkout }
    }

    /// An agent that can take a task on its command line.
    struct Runner: Equatable {
        let id: String
        let name: String
        let executable: String
    }

    /// Claude Code and Codex both start on a prompt given as an argument.
    static let supported = ["claude", "codex"]

    /// Who tries the task: each supported agent once; with only one, it
    /// goes twice, since one attempt compares with nothing.
    static func plan(_ available: [Runner]) -> [Runner] {
        let usable = supported.compactMap { id in available.first { $0.id == id } }
        return usable.count == 1 ? usable + usable : usable
    }

    /// `try/<first words of the task>-<agent>`, numbered when an agent goes
    /// more than once or the name is taken.
    static func branches(task: String, runners: [Runner], existing: Set<String>) -> [String] {
        let words = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        let slug = words.isEmpty ? "task" : words.joined(separator: "-")
        var taken = existing
        return runners.map { runner in
            let base = "try/\(slug)-\(runner.id)"
            var name = base
            var number = 2
            while taken.contains(name) {
                name = "\(base)-\(number)"
                number += 1
            }
            taken.insert(name)
            return name
        }
    }

    /// The line that starts the agent on the task in its worktree's shell.
    static func command(for runner: Runner, task: String, quote: (String) -> String) -> String {
        "\(quote(runner.executable)) \(quote(task))"
    }
}
