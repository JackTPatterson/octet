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

    /// The @ token the caret is in: from the `@` up to the caret is what's
    /// being looked for, and picking a file replaces the whole token, up to
    /// the next space. `caret` is a UTF-16 offset, as the text view gives
    /// it; nil reads it as the end of the text. Email-like text is ignored.
    static func mention(in text: String, caret: Int? = nil) -> Mention? {
        let utf16 = text.utf16
        let offset = min(max(caret ?? utf16.count, 0), utf16.count)
        guard let caretIndex = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex)?
            .samePosition(in: text) else { return nil }
        let before = text[..<caretIndex]
        // The token runs back from the caret to the nearest space.
        let tokenStart = before.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let token = text[tokenStart..<caretIndex]
        guard let at = token.lastIndex(of: "@") else { return nil }
        if at > tokenStart {
            let previous = text[text.index(before: at)]
            guard "([{".contains(previous) else { return nil }
        }
        let tokenEnd = text[caretIndex...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        return Mention(query: String(text[text.index(after: at)..<caretIndex]), range: at..<tokenEnd)
    }

    /// How a file outside the message goes into it as a mention: relative
    /// to the project when it's inside it, else in full; quoted when it has
    /// spaces, so the agent reads it as one path.
    static func mentionPath(_ path: String, cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        let shown = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        return shown.contains(where: \.isWhitespace) ? "\"" + shown + "\"" : shown
    }

    /// Project-relative files for @ autocomplete, best first. The list of
    /// files comes from `ReferenceIndex`, which asks git in a repository (so
    /// `.gitignore` is respected) and keeps the answer per folder.
    static func references(in cwd: String, matching query: String, limit: Int = 8) -> [Reference] {
        rank(ReferenceIndex.shared.files(in: cwd), matching: query, limit: limit)
    }

    /// Ranks paths against what's typed: a prefix beats a substring beats a
    /// fuzzy match, and shorter paths win ties.
    static func rank(_ paths: [String], matching query: String, limit: Int = 8) -> [Reference] {
        var matches: [(Reference, Int)] = []
        let lowered = query.lowercased()
        for relative in paths {
            let score: Int
            if query.isEmpty { score = 0 }
            else if relative.localizedCaseInsensitiveContains(query) {
                let name = (relative as NSString).lastPathComponent.lowercased()
                score = relative.lowercased().hasPrefix(lowered) || name.hasPrefix(lowered) ? 2_000 : 1_000
            } else if let fuzzy = FuzzyMatcher.match(query, in: relative) { score = fuzzy.score }
            else { continue }
            matches.append((Reference(path: relative), score - relative.count))
        }
        return matches.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Every file under `cwd` without asking git: hidden, build and vendor
    /// trees are left out, for signal and to keep the walk bounded.
    static func walk(_ cwd: String, cap: Int = 20_000) -> [String] {
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
        var paths: [String] = []
        for case let url as URL in enumerator {
            if ignored.contains(url.lastPathComponent) || protected.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            paths.append(String(url.path.dropFirst(cwd.hasSuffix("/") ? cwd.count : cwd.count + 1)))
            if paths.count >= cap { break }
        }
        return paths
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

/// The files @ mentions choose from, per folder. In a git repository it's
/// what `git ls-files` lists, tracked and untracked but not ignored, so
/// `.gitignore` decides; elsewhere it's a bounded walk. Either is read once
/// and kept for a short while, not repeated on every keystroke.
final class ReferenceIndex: @unchecked Sendable {
    static let shared = ReferenceIndex()
    /// How long a folder's list is trusted before it's read again.
    var lifetime: TimeInterval = 30
    private var cache: [String: (files: [String], at: Date)] = [:]
    private let lock = NSLock()

    func files(in cwd: String, now: Date = Date()) -> [String] {
        lock.lock()
        if let entry = cache[cwd], now.timeIntervalSince(entry.at) < lifetime {
            lock.unlock()
            return entry.files
        }
        lock.unlock()
        let files = Self.gitFiles(in: cwd) ?? AgentComposerSyntax.walk(cwd)
        lock.lock()
        cache[cwd] = (files, now)
        lock.unlock()
        return files
    }

    /// Forgets a folder's list, e.g. after files were added.
    func invalidate(_ cwd: String) {
        lock.lock()
        cache[cwd] = nil
        lock.unlock()
    }

    /// `git ls-files` relative to `cwd`, or nil outside a repository.
    static func gitFiles(in cwd: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // Deduplicated: a file both staged and changed is listed twice.
        var seen = Set<String>()
        return data.split(separator: 0).compactMap { bytes in
            let path = String(decoding: bytes, as: UTF8.self)
            return path.isEmpty || !seen.insert(path).inserted ? nil : path
        }
    }
}
