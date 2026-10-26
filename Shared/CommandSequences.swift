import Foundation

/// What you usually run next. Built once from history as a table of
/// command → what followed it, so a prediction is a dictionary lookup rather
/// than a search: after `git add .`, the line already reads `git commit -m`.
struct CommandSequences {
    /// Counts of what followed each command, and how recently.
    private struct Following {
        var counts: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
    }

    private var table: [String: Following] = [:]
    /// Commands by folder, so the same project's habits win there.
    private var byDirectory: [String: [String: Int]] = [:]

    init() {}

    /// Builds the table from history in order, oldest first.
    init(history: [String]) {
        for (index, command) in history.enumerated() {
            guard index > 0 else { continue }
            add(previous: history[index - 1], next: command, at: index)
        }
    }

    mutating func add(previous: String, next: String, at position: Int) {
        let key = Self.key(for: previous)
        let value = next.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, key != Self.key(for: next) else { return }
        var following = table[key] ?? Following()
        following.counts[value, default: 0] += 1
        following.lastSeen[value] = position
        table[key] = following
    }

    /// Records that a command was run in a folder, for the folder's own habits.
    mutating func add(command: String, in directory: String?) {
        guard let directory, !command.isEmpty else { return }
        byDirectory[directory, default: [:]][command, default: 0] += 1
    }

    /// How many times `command` was run in `directory`.
    func count(of command: String, in directory: String?) -> Int {
        guard let directory else { return 0 }
        return byDirectory[directory]?[command] ?? 0
    }

    /// What usually follows `command`, best first.
    func next(after command: String?, limit: Int = 5) -> [String] {
        guard let command, let following = table[Self.key(for: command)] else { return [] }
        return following.counts
            .sorted { first, second in
                first.value == second.value
                    ? (following.lastSeen[first.key] ?? 0) > (following.lastSeen[second.key] ?? 0)
                    : first.value > second.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// What you run most in this folder, for an empty prompt.
    func common(in directory: String?, limit: Int = 5) -> [String] {
        guard let directory, let counts = byDirectory[directory] else { return [] }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// The prediction for a prefix: what follows the last command, filtered by
    /// what has been typed so far. Empty prefix means the whole prediction.
    func prediction(after previous: String?, matching prefix: String, in directory: String? = nil) -> String? {
        let candidates = next(after: previous) + common(in: directory)
        guard !prefix.isEmpty else { return candidates.first }
        return candidates.first { $0.hasPrefix(prefix) && $0 != prefix }
    }

    /// Sequences key on the first two words: `git add .` and `git add -p`
    /// lead to the same place.
    static func key(for command: String) -> String {
        command.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
