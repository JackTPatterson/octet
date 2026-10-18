import Foundation

// The pure parts of the transcript's T3 Code features: which files a turn
// changed, which media a reply links to, how a quoted passage reads in the
// composer, and where a search lands in a command's output.

// MARK: - Changed files per turn

/// The files one agent turn edited through its edit tools, after T3 Code's
/// changed-files tree under each turn.
struct TurnChanges: Equatable {
    struct File: Equatable, Identifiable {
        /// As the agent wrote it, absolute where it could be resolved.
        let path: String
        var added: Int
        var removed: Int
        /// The change's lines from every edit to it this turn, in order.
        var lines: [LineDiff.Line]
        /// Made by a Write: a new file, or one rewritten whole.
        var created: Bool

        var id: String { path }
    }

    /// The person's message that started the turn.
    let promptId: String
    let promptAt: Date
    /// The next prompt's time, which ends this turn's checkpoint window.
    let nextPromptAt: Date?
    /// The turn's last item: the card sits under it.
    let lastItemId: String
    /// 1-based, counting the person's messages.
    let number: Int
    var files: [File]

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// Every turn that edited files, oldest first. The turn still running
    /// (the last one while `running`) is left out: its tree comes when it ends.
    static func derive(_ items: [AgentItem], cwd: String? = nil, running: Bool = false) -> [TurnChanges] {
        var turns: [TurnChanges] = []
        var number = 0
        var current: TurnChanges?
        var order: [String] = []
        var byPath: [String: File] = [:]

        func close(next: Date?) {
            guard var turn = current else { return }
            turn = TurnChanges(promptId: turn.promptId, promptAt: turn.promptAt, nextPromptAt: next,
                               lastItemId: turn.lastItemId, number: turn.number,
                               files: order.compactMap { byPath[$0] })
            if !turn.files.isEmpty { turns.append(turn) }
            current = nil
            order = []
            byPath = [:]
        }

        for item in items where !item.queued {
            if case .user = item.kind {
                close(next: item.createdAt)
                number += 1
                current = TurnChanges(promptId: item.id, promptAt: item.createdAt, nextPromptAt: nil,
                                      lastItemId: item.id, number: number, files: [])
                continue
            }
            guard current != nil else { continue }
            current = TurnChanges(promptId: current!.promptId, promptAt: current!.promptAt, nextPromptAt: nil,
                                  lastItemId: item.id, number: current!.number, files: [])
            guard case .tool(let call) = item.kind, !call.isError else { continue }
            for change in Self.changes(in: call, cwd: cwd) {
                if var file = byPath[change.path] {
                    file.added += change.added
                    file.removed += change.removed
                    file.lines += change.lines
                    file.created = file.created || change.created
                    byPath[change.path] = file
                } else {
                    order.append(change.path)
                    byPath[change.path] = change
                }
            }
        }
        if running { current = nil }
        close(next: nil)
        return turns
    }

    /// What one tool call changed: Claude Code's Edit, MultiEdit, Write and
    /// NotebookEdit, OpenCode's edits under the same names, and Codex's
    /// `fileChange` (drawn as Edit, carrying its `changes`).
    static func changes(in call: AgentToolCall, cwd: String?) -> [File] {
        guard let input = call.inputObject else { return [] }
        if let codex = input["changes"] as? [[String: Any]] {
            return codex.compactMap { change in
                guard let raw = change["path"] as? String, !raw.isEmpty else { return nil }
                let diff = change["diff"] as? String ?? ""
                let lines = Self.unifiedLines(diff)
                let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? change["kind"] as? String
                return File(path: resolve(raw, cwd: cwd),
                            added: lines.filter { $0.kind == .added }.count,
                            removed: lines.filter { $0.kind == .removed }.count,
                            lines: lines, created: kind == "add")
            }
        }
        let tools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
        guard tools.contains(call.name) else { return [] }
        let raw = input["file_path"] as? String ?? input["filePath"] as? String
            ?? input["notebook_path"] as? String ?? input["path"] as? String
        guard let raw, !raw.isEmpty else { return [] }
        let lines = call.diff ?? []
        return [File(path: resolve(raw, cwd: cwd),
                     added: lines.filter { $0.kind == .added }.count,
                     removed: lines.filter { $0.kind == .removed }.count,
                     lines: lines, created: call.name == "Write")]
    }

    /// A unified diff's body as lines; headers and hunk markers are dropped.
    static func unifiedLines(_ diff: String) -> [LineDiff.Line] {
        var result: [LineDiff.Line] = []
        var old = 0, new = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { continue }
            if line.hasPrefix("@@") {
                // @@ -12,3 +12,4 @@
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 1
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 1
                }
                continue
            }
            if line.hasPrefix("+") {
                result.append(.init(kind: .added, text: String(line.dropFirst()), newNumber: new)); new += 1
            } else if line.hasPrefix("-") {
                result.append(.init(kind: .removed, text: String(line.dropFirst()), oldNumber: old)); old += 1
            } else if line.hasPrefix(" ") {
                result.append(.init(kind: .context, text: String(line.dropFirst()), oldNumber: old, newNumber: new))
                old += 1; new += 1
            }
        }
        return result
    }

    static func resolve(_ path: String, cwd: String?) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") { return (path as NSString).expandingTildeInPath }
        guard let cwd else { return path }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// `path` as it reads under `root`, else whole.
    static func relative(_ path: String, to root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// The changed files as a folder tree, single-child folders joined
/// ("Sources/App") as T3 Code's tree does.
indirect enum ChangedFileNode: Equatable, Identifiable {
    case folder(name: String, path: String, children: [ChangedFileNode])
    case file(name: String, file: TurnChanges.File)

    var id: String {
        switch self {
        case .folder(_, let path, _): "dir:" + path
        case .file(_, let file): file.path
        }
    }

    var name: String {
        switch self {
        case .folder(let name, _, _), .file(let name, _): name
        }
    }

    var added: Int {
        switch self {
        case .folder(_, _, let children): children.reduce(0) { $0 + $1.added }
        case .file(_, let file): file.added
        }
    }

    var removed: Int {
        switch self {
        case .folder(_, _, let children): children.reduce(0) { $0 + $1.removed }
        case .file(_, let file): file.removed
        }
    }

    /// Folders first, then files, each by name; paths shown under `root`.
    static func tree(_ files: [TurnChanges.File], root: String?) -> [ChangedFileNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [(String, TurnChanges.File)] = []
        }
        let top = Folder()
        for file in files {
            var parts = TurnChanges.relative(file.path, to: root).split(separator: "/").map(String.init)
            guard let name = parts.popLast() else { continue }
            var folder = top
            for part in parts {
                if let next = folder.folders[part] { folder = next } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append((name, file))
        }
        func build(_ folder: Folder, prefix: String) -> [ChangedFileNode] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                var name = key
                var current = folder.folders[key]!
                // Join a chain of folders holding only one folder each.
                while current.files.isEmpty, current.folders.count == 1, let (child, next) = current.folders.first {
                    name += "/" + child
                    current = next
                }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return ChangedFileNode.folder(name: name, path: path, children: build(current, prefix: path))
            }
            let files = folder.files.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                .map { ChangedFileNode.file(name: $0.0, file: $0.1) }
            return folders + files
        }
        return build(top, prefix: "")
    }
}

// MARK: - Media links

/// An image or video a reply links to or names, after T3 Code's inline media.
struct TranscriptMediaLink: Equatable, Identifiable {
    enum Kind: Equatable { case image, video }
    let kind: Kind
    /// A file URL for paths, else the web address.
    let url: URL
    /// As written in the reply.
    let source: String

    var id: String { url.absoluteString }
    var isFile: Bool { url.isFileURL }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// More than this many is a listing, not something to preview.
    static let limit = 8

    static func kind(of path: String) -> Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// The media `text` names, first mention first: Markdown images and
    /// links, bare web addresses, and absolute, home or `./` paths; a plain
    /// relative path only inside a code span. Fenced code is skipped, since
    /// it's code, not a pointer at a file.
    static func links(in text: String, cwd: String? = nil) -> [TranscriptMediaLink] {
        let prose = withoutFences(text)
        var found: [(Int, String)] = []
        let patterns = [
            // ![alt](target "title") and [label](target)
            #"!?\[[^\]\n]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)"#,
            // Bare web addresses.
            #"(?<![\(\[<])\bhttps?://[^\s<>()\[\]"'`]+"#,
            // file:// addresses.
            #"(?<![\(\[<])\bfile://[^\s<>()\[\]"'`]+"#,
            // Absolute, home and dot-relative paths.
            #"(?<![\w/\.:\(\[])(?:~|\.{1,2})?/[^\s<>()\[\]"'`*]+"#,
            // Any path inside a code span.
            #"`([^`\s]+)`"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(prose.startIndex..., in: prose)
            for match in expression.matches(in: prose, range: range) {
                let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? 1 : 0
                guard let swiftRange = Range(match.range(at: group), in: prose) else { continue }
                found.append((match.range.location, String(prose[swiftRange])))
            }
        }
        var seen = Set<String>()
        var links: [TranscriptMediaLink] = []
        for (_, raw) in found.sorted(by: { $0.0 < $1.0 }) {
            guard let link = link(raw, cwd: cwd), seen.insert(link.id).inserted else { continue }
            links.append(link)
            if links.count == limit { break }
        }
        return links
    }

    /// One candidate as a link, or nil when it isn't media.
    static func link(_ raw: String, cwd: String?) -> TranscriptMediaLink? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, ".,;:!?)]}'\"".contains(last) { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let url = URL(string: value), url.host != nil, let kind = kind(of: url.path) else { return nil }
            return TranscriptMediaLink(kind: kind, url: url, source: value)
        }
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), let kind = kind(of: url.path) else { return nil }
            return TranscriptMediaLink(kind: kind, url: url, source: value)
        }
        guard !value.contains("://"), let kind = kind(of: value) else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        let path: String
        if decoded.hasPrefix("/") || decoded.hasPrefix("~") {
            path = (decoded as NSString).expandingTildeInPath
        } else if let cwd {
            path = ((cwd as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
        } else {
            return nil
        }
        return TranscriptMediaLink(kind: kind, url: URL(fileURLWithPath: path), source: value)
    }

    /// `text` with fenced code blocks blanked out, keeping offsets close.
    static func withoutFences(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return ""
            }
            return inFence ? "" : line
        }.joined(separator: "\n")
    }
}

// MARK: - Quoting a reply

/// A passage of a reply quoted into the composer, after T3 Code's citations:
/// a Markdown blockquote the agent reads as "this part".
enum TranscriptQuote {
    /// Longer passages are cut, as T3 Code caps a citation.
    static let maxLength = 4000

    enum Action: Equatable { case quote, ask }

    /// `text` as a Markdown blockquote, trimmed and capped.
    static func blockquote(_ text: String) -> String {
        var passage = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return "" }
        if passage.count > maxLength { passage = String(passage.prefix(maxLength)) + "…" }
        return passage.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// What the composer holds after quoting `passage` into `draft`: the
    /// quote goes after whatever is there, a blank line apart, and the
    /// cursor's line follows it (with a question started, to ask about it).
    static func inserting(_ passage: String, into draft: String, action: Action = .quote) -> String {
        let quote = blockquote(passage)
        guard !quote.isEmpty else { return draft }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = trimmed.isEmpty ? "" : draft.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n\n"
        let tail = action == .ask ? "\n\nCan you explain this part?" : "\n\n"
        return lead + quote + tail
    }
}

// MARK: - Searching command output

enum CommandOutputSearch {
    /// The lines of `text` containing `query`, ignoring case, as 0-based
    /// line indexes. An empty query matches nothing.
    static func matchingLines(_ lines: [String], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return lines.indices.filter { lines[$0].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Output with terminal colour codes taken out, for reading and search.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}
