import Foundation

/// fzf-style fuzzy matching: the query must appear as a case-insensitive
/// subsequence; consecutive runs, word starts, and early matches score higher.
enum FuzzyMatcher {
    struct Match: Equatable {
        let score: Int
        /// Character offsets in the candidate that matched, for highlighting.
        let indices: [Int]
    }

    /// `tight` keeps only matches whose every character follows the one
    /// before or starts a word: for long secondary text, like a folder path,
    /// where a scattered subsequence matches almost any query.
    static func match(_ query: String, in candidate: String, tight: Bool = false) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let original = Array(candidate)
        guard needle.count <= original.count else { return nil }
        // Lowercased whole, not a string per character; lowercasing that
        // changes the length (rare) falls back so indices still line up.
        let lowered = Array(candidate.lowercased())
        let haystack = lowered.count == original.count ? lowered : original.map { Character($0.lowercased()) }

        // Greedy forward pass to prove a match exists, then a backward pass from
        // the end of that match to tighten it (fzf v1).
        var forward: [Int] = []
        var qi = 0
        for (i, char) in haystack.enumerated() where qi < needle.count && char == needle[qi] {
            forward.append(i)
            qi += 1
        }
        guard qi == needle.count, let end = forward.last else { return nil }

        var indices: [Int] = []
        qi = needle.count - 1
        var i = end
        while i >= 0 && qi >= 0 {
            if haystack[i] == needle[qi] {
                indices.append(i)
                qi -= 1
            }
            i -= 1
        }
        indices.reverse()
        if tight {
            for (n, index) in indices.enumerated() where !(n > 0 && indices[n - 1] == index - 1) {
                guard isWordStart(index, in: original) else { return nil }
            }
        }

        var score = 0
        for (n, index) in indices.enumerated() {
            score += 16
            if n > 0 && indices[n - 1] == index - 1 { score += 12 }
            if isWordStart(index, in: original) { score += 10 }
            if n > 0 { score -= min(index - indices[n - 1] - 1, 8) }
        }
        if let first = indices.first {
            score -= min(first, 12)
            if first == 0 { score += 10 }
        }
        // Spaces are left out of both sides, as the match leaves them out of
        // the query: "new tab" is a prefix of "New Tab".
        if haystack.lazy.filter({ !$0.isWhitespace }).starts(with: needle) { score += 20 }
        return Match(score: score, indices: indices)
    }

    private static func isWordStart(_ index: Int, in chars: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        if " /-_:.·—".contains(previous) { return true }
        return previous.isLowercase && chars[index].isUppercase
    }
}
