import Foundation

/// One chip the status bar under the terminal can show: one of Octet's own,
/// or one a plugin contributes.
struct StatusItemDescriptor: Equatable, Identifiable {
    enum Scope: String, Codable {
        /// About this Mac's folder: hidden while the pane is logged in elsewhere.
        case local
        /// About the machine an SSH session is logged into.
        case remote
        /// Shown either way.
        case any
    }

    let id: String
    let name: String
    let summary: String
    /// What the chip reads in Settings' preview.
    let sample: String
    /// An SF Symbol, or nil when `iconPath` or the chip draws its own.
    var symbol: String?
    /// An image in a plugin's folder.
    var iconPath: String?
    /// The chip's text colour as hex; nil for the theme's text colour.
    var color: String?
    var enabledByDefault: Bool
    var scope: Scope = .local
    var pluginId: String?
}

/// What a plugin's status command printed: the chip's text on the first
/// line, then optional `key: value` lines.
struct StatusItemOutput: Equatable {
    enum Tone: String {
        case normal, muted, success, warning, danger
    }

    var text: String
    var tone: Tone = .normal
    var help: String?
    var url: URL?

    /// nil when the command printed nothing, which hides the chip.
    static func parse(_ output: String) -> StatusItemOutput? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        var result = StatusItemOutput(text: String(first.prefix(60)))
        for line in lines.drop(while: { $0 != first }).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "tone": result.tone = Tone(rawValue: value.lowercased()) ?? .normal
            case "help": result.help = value.replacingOccurrences(of: "\\n", with: "\n")
            case "url": result.url = URL(string: value).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
            default: break
            }
        }
        return result
    }
}

enum StatusBarItems {
    /// Octet's own chips, in their default order.
    static let builtIns: [StatusItemDescriptor] = [
        .init(id: "builtin.ssh", name: "SSH host", summary: "The machine this pane is logged into",
              sample: "jack@pve", symbol: "network", enabledByDefault: true, scope: .any),
        .init(id: "builtin.agent", name: "Agent", summary: "The agent in this pane and whether it needs you",
              sample: "Claude Code working", enabledByDefault: true, scope: .any),
        .init(id: "builtin.account", name: "Account", summary: "The agent account this folder uses, when it isn't the default",
              sample: "Claude · Work", symbol: "person.crop.circle", enabledByDefault: true, scope: .local),
        .init(id: "builtin.remoteControl", name: "Remote Control",
              summary: "While the agent in this pane is open in claude.ai or the Claude app",
              sample: "Remote", enabledByDefault: true, scope: .any),
        .init(id: "builtin.runtime", name: "Runtime version", summary: "The project's toolchain and the version that runs here",
              sample: "v25.6.1", enabledByDefault: true),
        .init(id: "builtin.directory", name: "Directory", summary: "The pane's working folder",
              sample: "~/Developer/octet", symbol: "folder", color: "E68AE6", enabledByDefault: false),
        .init(id: "builtin.branch", name: "Git branch", summary: "The branch, or the commit when detached",
              sample: "feat/status-bar", symbol: "arrow.triangle.branch", enabledByDefault: true),
        .init(id: "builtin.worktree", name: "Git worktree", summary: "Shown in a linked worktree",
              sample: "status-bar-wt", symbol: "square.stack.3d.up", color: "B48EAD", enabledByDefault: true),
        .init(id: "builtin.gitState", name: "Merge & rebase", summary: "A merge, rebase or cherry-pick in progress, and conflicts",
              sample: "REBASING 3/7 · 2 conflicts", symbol: "exclamationmark.triangle", enabledByDefault: true),
        .init(id: "builtin.changes", name: "Changes", summary: "Changed files and lines in the working tree",
              sample: "3 • +10 -2", symbol: "doc", enabledByDefault: true),
        .init(id: "builtin.pullRequest", name: "Pull request", summary: "The branch's pull request and its checks, from the GitHub CLI",
              sample: "PR #123 ✓", enabledByDefault: true),
    ]

    /// The ids to show, in order. Until someone arranges the bar, it's every
    /// chip that's on by default. After that it's their order, plus any chip
    /// that arrived since (a plugin turned on) and starts on.
    static func resolve(saved: [String], customized: Bool, seen: [String],
                        available: [StatusItemDescriptor]) -> [String] {
        let defaults = available.filter(\.enabledByDefault).map(\.id)
        guard customized else { return defaults }
        let known = Set(available.map(\.id))
        let seenSet = Set(seen)
        let kept = saved.filter(known.contains)
        let arrived = defaults.filter { !seenSet.contains($0) && !kept.contains($0) }
        return kept + arrived
    }

    /// Whether any of `files` sits between `directory` and `root`, the way a
    /// project's marker files do; with no root, only `directory` is checked.
    static func hasMarker(_ files: [String], from directory: String, root: String?,
                          exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        guard !files.isEmpty else { return true }
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let top = root.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path } ?? url.path
        while url.path.hasPrefix(top) {
            if files.contains(where: { exists(url.appendingPathComponent($0).path) }) { return true }
            if url.path == top || url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        return false
    }
}

/// An operation git has stopped in the middle of, read from its marker
/// files, and how many files are left in conflict.
struct GitOperation: Equatable {
    enum Kind: String {
        case merging = "MERGING", rebasing = "REBASING", cherryPicking = "CHERRY-PICKING"
        case reverting = "REVERTING", bisecting = "BISECTING"
    }

    var kind: Kind?
    /// The step a rebase is on, and how many there are.
    var step: (current: Int, total: Int)?
    var conflicts = 0

    var isEmpty: Bool { kind == nil && conflicts == 0 }

    var label: String {
        var parts: [String] = []
        if let kind {
            parts.append(step.map { "\(kind.rawValue) \($0.current)/\($0.total)" } ?? kind.rawValue)
        }
        if conflicts > 0 { parts.append(conflicts == 1 ? "1 conflict" : "\(conflicts) conflicts") }
        return parts.joined(separator: " · ")
    }

    static func == (lhs: GitOperation, rhs: GitOperation) -> Bool {
        lhs.kind == rhs.kind && lhs.conflicts == rhs.conflicts
            && lhs.step?.current == rhs.step?.current && lhs.step?.total == rhs.step?.total
    }

    /// Reads `gitDir`'s marker files. `read` returns a file's contents.
    static func read(gitDir: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:),
                     read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> GitOperation {
        var operation = GitOperation()
        func number(_ path: String) -> Int? {
            read(gitDir + "/" + path).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if exists(gitDir + "/rebase-merge") {
            operation.kind = .rebasing
            if let current = number("rebase-merge/msgnum"), let total = number("rebase-merge/end") {
                operation.step = (current, total)
            }
        } else if exists(gitDir + "/rebase-apply") {
            operation.kind = .rebasing
            if let current = number("rebase-apply/next"), let total = number("rebase-apply/last") {
                operation.step = (current, total)
            }
        } else if exists(gitDir + "/MERGE_HEAD") {
            operation.kind = .merging
        } else if exists(gitDir + "/CHERRY_PICK_HEAD") {
            operation.kind = .cherryPicking
        } else if exists(gitDir + "/REVERT_HEAD") {
            operation.kind = .reverting
        } else if exists(gitDir + "/BISECT_LOG") {
            operation.kind = .bisecting
        }
        return operation
    }
}
