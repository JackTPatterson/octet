import Foundation

/// What the transcript draws, row by row: most items stand alone, and a run
/// of tool calls one after another folds into one summary row ("Read 3
/// files, ran 2 commands"), after T3 Code's work log.
enum TranscriptRow: Identifiable, Equatable {
    case item(String)
    /// Two or more tool calls in a row, by item id, in order.
    case toolRun([String])

    var id: String {
        switch self {
        case .item(let id): id
        case .toolRun(let ids): "run:" + (ids.first ?? "")
        }
    }

    var itemIds: [String] {
        switch self {
        case .item(let id): [id]
        case .toolRun(let ids): ids
        }
    }
}

enum TranscriptTimeline {
    /// The rows for `items` (already filtered to what's shown). Calls fold
    /// only with neighbours of the same parent, so a subagent's work stays
    /// under the call that started it.
    static func rows(_ items: [AgentItem]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [AgentItem] = []
        func flush() {
            if run.count >= 2 {
                rows.append(.toolRun(run.map(\.id)))
            } else {
                rows += run.map { .item($0.id) }
            }
            run = []
        }
        for item in items {
            if case .tool(let call) = item.kind, folds(call) {
                if let first = run.first, first.parent != item.parent { flush() }
                run.append(item)
            } else {
                flush()
                rows.append(.item(item.id))
            }
        }
        flush()
        return rows
    }

    /// Calls worth seeing on their own stay out of runs: the task list, a
    /// published artifact, a subagent (its work is drawn under it), plans
    /// and questions, and anything that returned an image.
    static func folds(_ call: AgentToolCall) -> Bool {
        if !call.resultImages.isEmpty { return false }
        switch call.name {
        case "TodoWrite", "Task", "Agent", "ExitPlanMode", "AskUserQuestion",
             "Artifact", "ArtifactComments", "ArtifactData":
            return false
        default:
            return true
        }
    }
}

/// The words of a folded run of tool calls.
enum ToolRunSummary {
    enum Category: CaseIterable {
        case read, edit, create, command, search, webSearch, fetch, list, plan, integration, tool
    }

    static func category(_ call: AgentToolCall) -> Category {
        if call.isMCP { return .integration }
        switch call.name {
        case "Read", "NotebookRead": return .read
        case "Edit", "MultiEdit", "NotebookEdit": return .edit
        case "Write": return .create
        case "Bash", "BashOutput", "KillShell", "KillBash", "Monitor": return .command
        case "Grep", "Glob", "ToolSearch": return .search
        case "LS": return .list
        case "WebSearch": return .webSearch
        case "WebFetch": return .fetch
        case "TodoWrite", "TaskCreate", "TaskUpdate": return .plan
        default: return .tool
        }
    }

    /// "Read 3 files, ran 2 commands, and edited 1 file"; while it runs,
    /// "Reading 3 files and running 2 commands…". Files are counted once
    /// however often they were touched.
    static func text(_ calls: [AgentToolCall], live: Bool) -> String {
        var counts: [Category: Int] = [:]
        var files: [Category: Set<String>] = [:]
        for call in calls {
            let category = category(call)
            if [.read, .edit, .create].contains(category), let path = call.filePath {
                files[category, default: []].insert(path)
            } else {
                counts[category, default: 0] += 1
            }
        }
        for (category, paths) in files { counts[category, default: 0] += paths.count }
        let phrases = Category.allCases.compactMap { category in
            counts[category].map { phrase(category, count: $0, live: live) }
        }
        let joined = list(phrases)
        guard let first = joined.first else { return live ? "Working…" : "" }
        let sentence = first.uppercased() + joined.dropFirst()
        return live ? sentence + "…" : sentence
    }

    /// One category's words, in lower case.
    static func phrase(_ category: Category, count: Int, live: Bool) -> String {
        func noun(_ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        func times() -> String { count == 1 ? "" : " \(count) times" }
        switch category {
        case .read: return (live ? "reading " : "read ") + noun("file", "files")
        case .edit: return (live ? "editing " : "edited ") + noun("file", "files")
        case .create: return (live ? "creating " : "created ") + noun("file", "files")
        case .command: return (live ? "running " : "ran ") + noun("command", "commands")
        case .search: return (live ? "searching " : "searched ") + noun("time", "times")
        case .webSearch: return (live ? "searching the web" : "searched the web") + times()
        case .fetch: return (live ? "fetching " : "fetched ") + noun("page", "pages")
        case .list: return (live ? "listing " : "listed ") + noun("directory", "directories")
        case .plan: return (live ? "updating the plan" : "updated the plan") + times()
        case .integration: return (live ? "using " : "used ") + noun("integration", "integrations")
        case .tool: return (live ? "using " : "used ") + noun("tool", "tools")
        }
    }

    /// "a", "a and b", "a, b, and c".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}

/// Durations the way the transcript says them: "12s", "1m 05s", "1h 02m".
enum AgentElapsed {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m " + String(format: "%02ds", total % 60) }
        return "\(total / 3_600)h " + String(format: "%02dm", total % 3_600 / 60)
    }

    /// How long a thinking block took: from when it began to when the next
    /// item did. Nil while it's still the last thing (it's still going) or
    /// when the times can't be trusted (a replayed log without them).
    static func thinking(_ item: AgentItem, next: AgentItem?) -> TimeInterval? {
        guard let next else { return nil }
        let seconds = next.createdAt.timeIntervalSince(item.createdAt)
        return seconds >= 0 && seconds < 86_400 ? seconds : nil
    }
}

/// A shell code block in a reply that can be run as it stands: a shell
/// language, something in it, and no control characters a terminal would
/// act on. A `console` block's `$ ` prompts are taken off.
enum ShellCodeBlock {
    static let languages: Set<String> = ["sh", "bash", "zsh", "shell", "console", "shell-session", "fish"]

    static func runnable(language: String?, text: String) -> String? {
        guard let language = language?.lowercased(), languages.contains(language) else { return nil }
        let hasControl = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\n" && scalar != "\t") || scalar.value == 0x7F
        }
        guard !hasControl else { return nil }
        var lines = text.components(separatedBy: "\n")
        if language == "console" || language == "shell-session" {
            // Only the prompted lines are commands; the rest is output.
            lines = lines.compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("$ ") ? String(trimmed.dropFirst(2)) : nil
            }
        }
        let command = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

/// Parsed Markdown by its text, so a transcript that redraws (the stream
/// moving on, the window resizing) doesn't parse every reply again.
final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()
    private let cache = NSCache<NSString, Box>()

    private final class Box {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    init() { cache.countLimit = 600 }

    func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlock.parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}
