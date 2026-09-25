import Foundation

/// Prefix features shared by the native composers. Claude Code, Codex,
/// OpenCode, Pi and Qwen Code all document `/` commands, `@` file mentions,
/// and `!` shell input; the agents still own what each prefix ultimately does.
enum AgentComposerSyntax {
    struct Reference: Identifiable, Equatable {
        let path: String
        var id: String { path }
    }

    struct Mention: Equatable {
        let query: String
        let range: Range<String.Index>
    }

    /// The unfinished @ token nearest the caret. Email-like text is ignored.
    static func mention(in text: String) -> Mention? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || "([{".contains(before) else { return nil }
        }
        let suffix = text[text.index(after: at)...]
        guard !suffix.contains(where: { $0.isWhitespace }) else { return nil }
        return Mention(query: String(suffix), range: at..<text.endIndex)
    }

    /// Project-relative files for @ autocomplete. Hidden/build/vendor trees
    /// are omitted both for signal and to keep typing latency bounded.
    static func references(in cwd: String, matching query: String, limit: Int = 8) -> [Reference] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: URL(fileURLWithPath: cwd),
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let ignored = Set([".git", ".build", "build", "DerivedData", "node_modules", "Pods", ".next"])
        // A session opened in the home folder would otherwise walk into the
        // privacy-protected folders, and macOS asks about each one.
        let home = NSHomeDirectory()
        let protected = Set(["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]
            .map { home + "/" + $0 })
        var matches: [(Reference, Int)] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(cwd.hasSuffix("/") ? cwd.count : cwd.count + 1))
            if ignored.contains(url.lastPathComponent) || protected.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let score: Int
            if query.isEmpty { score = 0 }
            else if relative.localizedCaseInsensitiveContains(query) {
                score = relative.lowercased().hasPrefix(query.lowercased()) ? 2_000 : 1_000
            } else if let fuzzy = FuzzyMatcher.match(query, in: relative) { score = fuzzy.score }
            else { continue }
            matches.append((Reference(path: relative), score - relative.count))
            if matches.count > 400 { break }
        }
        return matches.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Shell lines explicitly marked by an agent for direct execution. Only
    /// a leading `!` counts; fenced examples and ordinary prose do not.
    static func suggestedShellCommands(in items: [AgentItem]) -> [String] {
        var latest: String?
        for item in items.reversed() {
            if case .text(let text) = item.kind { latest = text; break }
            // Once a new active prompt has been submitted, suggestions from
            // the preceding response are stale. Queued follow-ups do not
            // invalidate the response they are waiting behind.
            if case .user = item.kind, !item.queued { return [] }
        }
        guard let text = latest else { return [] }
        var commands: [String] = []
        var fenced = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced, line.hasPrefix("!"), !line.hasPrefix("!!") else { continue }
            let command = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            commands.append(command)
        }
        return commands
    }
}
