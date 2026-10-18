import Foundation

/// Ranks slash commands the way T3 Code's composer does: an exact name
/// first, then names that start with what's typed, then a word inside the
/// name starting with it (`/review` for `rev`, `/git:amend` for `am`), then
/// the text anywhere in the name, then a loose in-order match of its
/// letters. A command whose description holds what's typed ranks between
/// the two. Lower scores rank higher; ties go alphabetically.
enum SlashCommandSearch {
    struct Result: Identifiable, Equatable {
        let command: SlashCommand
        let score: Int
        /// Offsets into `command.insertion` that matched, to highlight.
        let nameIndices: [Int]
        /// Offsets into `command.summary` that matched, when it was the
        /// description that matched.
        let summaryIndices: [Int]

        var id: String { command.id }
    }

    /// Words inside a name start after one of these.
    static let boundaryMarkers: [Character] = ["-", "_", "/", ":", " ", "."]

    /// The commands matching `query` (with or without its leading `/`),
    /// searched through every submenu, best first. An empty query keeps the
    /// top level as it is.
    static func search(_ query: String, in commands: [SlashCommand]) -> [Result] {
        let needle = normalize(query)
        guard !needle.isEmpty else {
            return commands.map { Result(command: $0, score: 0, nameIndices: [], summaryIndices: []) }
        }
        var seen = Set<String>()
        var results: [Result] = []
        for command in commands.flatMap(\.flattened) where seen.insert(command.id).inserted {
            if let result = score(command, needle) { results.append(result) }
        }
        return results.sorted { first, second in
            first.score == second.score
                ? first.command.insertion.localizedCaseInsensitiveCompare(second.command.insertion) == .orderedAscending
                : first.score < second.score
        }
    }

    /// Trimmed, lowercased, leading slashes dropped.
    static func normalize(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }

    private static func score(_ command: SlashCommand, _ needle: String) -> Result? {
        let name = command.insertion.hasPrefix("/") ? String(command.insertion.dropFirst()) : command.insertion
        let offset = command.insertion.count - name.count
        var best: Result?
        func consider(_ score: Int, _ nameIndices: [Int], _ summaryIndices: [Int]) {
            guard best.map({ score < $0.score }) ?? true else { return }
            best = Result(command: command, score: score, nameIndices: nameIndices, summaryIndices: summaryIndices)
        }
        // The full name, the bare name of a submenu entry, and any alias.
        if let match = rank(name.lowercased(), needle, fuzzy: true) {
            consider(match.score, match.indices.map { $0 + offset }, [])
        }
        if command.name.lowercased() != name.lowercased(), let match = rank(command.name.lowercased(), needle, fuzzy: true),
           let start = name.lowercased().range(of: command.name.lowercased(), options: .backwards) {
            let base = name.distance(from: name.startIndex, to: start.lowerBound) + offset
            consider(match.score, match.indices.map { $0 + base }, [])
        }
        for alias in command.aliases {
            if let match = rank(alias.lowercased(), needle, fuzzy: true) { consider(match.score, [], []) }
        }
        // What it does: after a name that holds the text, ahead of a loose
        // match of the name's letters, and never loosely itself.
        if !command.summary.isEmpty, let match = rank(command.summary.lowercased(), needle, fuzzy: false, base: 20) {
            consider(match.score, [], match.indices)
        }
        return best
    }

    struct Rank: Equatable {
        let score: Int
        let indices: [Int]
    }

    /// T3 Code's `scoreQueryMatch`: exact, prefix, word start, anywhere,
    /// then (for names) in-order letters. Both sides already lowercased.
    static func rank(_ value: String, _ query: String, fuzzy: Bool, base: Int = 0) -> Rank? {
        guard !value.isEmpty, !query.isEmpty else { return nil }
        let chars = Array(value), needle = Array(query)
        let penalty = min(64, max(0, chars.count - needle.count))
        let span = { (start: Int) in Array(start..<(start + needle.count)) }
        if chars == needle { return Rank(score: base, indices: span(0)) }
        if chars.starts(with: needle) { return Rank(score: base + 2 + penalty, indices: span(0)) }
        let occurrences = (0...max(0, chars.count - needle.count)).filter { start in
            start + needle.count <= chars.count && Array(chars[start..<(start + needle.count)]) == needle
        }
        if let boundary = occurrences.first(where: { $0 > 0 && boundaryMarkers.contains(chars[$0 - 1]) }) {
            return Rank(score: base + 4 + boundary * 2 + penalty, indices: span(boundary))
        }
        if let anywhere = occurrences.first {
            return Rank(score: base + 6 + anywhere * 2 + penalty, indices: span(anywhere))
        }
        guard fuzzy, let loose = subsequence(chars, needle) else { return nil }
        return Rank(score: base + 100 + loose.score, indices: loose.indices)
    }

    /// Letters in order with gaps, penalised for where the match starts, the
    /// gaps between letters and how long the name runs past it.
    static func subsequence(_ value: [Character], _ query: [Character]) -> Rank? {
        guard !query.isEmpty else { return Rank(score: 0, indices: []) }
        var indices: [Int] = []
        var gaps = 0
        for (index, char) in value.enumerated() where indices.count < query.count && char == query[indices.count] {
            if let previous = indices.last { gaps += index - previous - 1 }
            indices.append(index)
        }
        guard indices.count == query.count, let first = indices.first, let last = indices.last else { return nil }
        let spread = last - first + 1 - query.count
        let length = min(64, value.count - query.count)
        return Rank(score: first * 2 + gaps * 3 + spread + length, indices: indices)
    }
}
