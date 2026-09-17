import Foundation

/// What a tool call is actually doing, past its name. An agent's own UI draws
/// a command as a command, an edit as a diff and a plan as a checklist, and
/// the twin can only do the same if it keeps what the call carried.
enum TwinToolDetail: Equatable {
    case command(String)
    case diff(TwinDiff)
    case todos([TwinTodo])
    case file(path: String)
    case search(query: String)
    case link(url: String)
}

struct TwinTodo: Equatable, Identifiable {
    enum Status: String, Equatable { case pending, inProgress, completed }

    let text: String
    let status: Status
    var id: String { text }

    static func status(_ raw: String?) -> Status {
        switch raw?.lowercased().replacingOccurrences(of: "_", with: "") {
        case "inprogress", "active", "running": .inProgress
        case "completed", "done", "complete": .completed
        default: .pending
        }
    }
}

/// A change to one file, as lines to draw.
struct TwinDiff: Equatable {
    enum Line: Equatable {
        case context(String)
        case added(String)
        case removed(String)
    }

    let path: String
    var lines: [Line]

    var added: Int { lines.filter { if case .added = $0 { return true } else { return false } }.count }
    var removed: Int { lines.filter { if case .removed = $0 { return true } else { return false } }.count }

    /// `+12 −3`, the way every agent summarises an edit.
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        return parts.joined(separator: " ")
    }
}

enum TwinTools {
    /// Reads a tool call's input into what the twin should draw.
    static func detail(name: String, input: Any?) -> TwinToolDetail? {
        let object = dictionary(input)
        let tool = name.lowercased()

        if let todos = todos(in: object) { return .todos(todos) }
        if let diff = diff(name: tool, object: object) { return .diff(diff) }
        if let command = command(name: tool, input: input, object: object) { return .command(command) }
        if let object {
            if let url = object["url"] as? String { return .link(url: url) }
            for key in ["pattern", "query", "prompt"] {
                if let value = object[key] as? String, !value.isEmpty { return .search(query: value) }
            }
            for key in ["file_path", "path", "notebook_path", "filePath"] {
                if let value = object[key] as? String, !value.isEmpty { return .file(path: value) }
            }
        }
        return nil
    }

    // MARK: - Todos

    static func todos(in object: [String: Any]?) -> [TwinTodo]? {
        guard let raw = object?["todos"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let todos = raw.compactMap { item -> TwinTodo? in
            let text = (item["content"] ?? item["text"] ?? item["task"] ?? item["activeForm"]) as? String
            guard let text, !text.isEmpty else { return nil }
            return TwinTodo(text: text, status: TwinTodo.status(item["status"] as? String))
        }
        return todos.isEmpty ? nil : todos
    }

    // MARK: - Commands

    /// The command a call is running, in whichever shape the agent wrote it.
    static func command(name: String, input: Any?, object: [String: Any]?) -> String? {
        if let object {
            if let command = object["command"] as? String, !command.isEmpty { return command }
            if let parts = object["command"] as? [String], !parts.isEmpty {
                // `["bash", "-lc", "…"]` is the shell wrapper, not the command.
                if parts.count >= 3, parts[1].hasPrefix("-"), let last = parts.last { return last }
                return parts.joined(separator: " ")
            }
            if let cmd = object["cmd"] as? String, !cmd.isEmpty { return cmd }
        }
        // Newer Codex writes the call as the script it runs.
        if let text = input as? String, let extracted = extractCommand(fromScript: text) { return extracted }
        guard name.contains("bash") || name.contains("shell") || name.contains("exec") || name.contains("terminal") else {
            return nil
        }
        if let text = input as? String, !text.isEmpty { return text }
        return nil
    }

    /// `tools.exec_command({cmd:"pwd && ls"})` → `pwd && ls`.
    static func extractCommand(fromScript text: String) -> String? {
        for key in ["cmd:", "command:", "\"cmd\":", "\"command\":"] {
            guard let range = text.range(of: key) else { continue }
            let rest = text[range.upperBound...].drop { $0 == " " }
            guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
            var value = ""
            var escaped = false
            for character in rest.dropFirst() {
                if escaped {
                    // The script escapes what the shell would have to.
                    value.append(character == "n" ? "\n" : character)
                    escaped = false
                    continue
                }
                if character == "\\" { escaped = true; continue }
                if character == quote { return value.isEmpty ? nil : value }
                value.append(character)
            }
        }
        return nil
    }

    // MARK: - Diffs

    static func diff(name: String, object: [String: Any]?) -> TwinDiff? {
        guard let object else { return nil }
        let path = (object["file_path"] ?? object["path"] ?? object["filePath"]) as? String ?? ""

        // A patch in the body, whoever wrote it.
        for key in ["patch", "diff", "input", "content"] {
            if let text = object[key] as? String, looksLikePatch(text) {
                return unified(text, path: path)
            }
        }
        if let old = object["old_string"] as? String, let new = object["new_string"] as? String {
            return TwinDiff(path: path, lines: lines(replacing: old, with: new))
        }
        // MultiEdit: several replacements in one file.
        if let edits = object["edits"] as? [[String: Any]], !edits.isEmpty {
            var all: [TwinDiff.Line] = []
            for edit in edits {
                let old = edit["old_string"] as? String ?? ""
                let new = edit["new_string"] as? String ?? ""
                all += lines(replacing: old, with: new)
            }
            return all.isEmpty ? nil : TwinDiff(path: path, lines: all)
        }
        // A whole file written at once is all additions.
        if name.contains("write"), let content = object["content"] as? String, !path.isEmpty {
            return TwinDiff(path: path, lines: content.components(separatedBy: "\n").map { .added($0) })
        }
        return nil
    }

    static func looksLikePatch(_ text: String) -> Bool {
        text.contains("*** Begin Patch") || text.hasPrefix("--- ") || text.contains("\n@@") || text.hasPrefix("@@")
    }

    /// A unified diff, or Codex's `*** Begin Patch` form, as lines to draw.
    static func unified(_ text: String, path: String) -> TwinDiff {
        var file = path
        var lines: [TwinDiff.Line] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("*** ") {
                // `*** Update File: src/main.rs`
                if let colon = raw.range(of: ": "), file.isEmpty || !raw.contains("End Patch") {
                    let named = String(raw[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !named.isEmpty { file = named }
                }
                continue
            }
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("index ") || raw.hasPrefix("diff --git") {
                continue
            }
            if raw.hasPrefix("@@") { continue }
            if raw.hasPrefix("+") { lines.append(.added(String(raw.dropFirst()))) }
            else if raw.hasPrefix("-") { lines.append(.removed(String(raw.dropFirst()))) }
            else if raw.hasPrefix(" ") { lines.append(.context(String(raw.dropFirst()))) }
        }
        return TwinDiff(path: file, lines: lines)
    }

    /// Two versions of a string as removed and added lines, with the parts
    /// that didn't change kept around them for context.
    static func lines(replacing old: String, with new: String) -> [TwinDiff.Line] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }

        var lines: [TwinDiff.Line] = []
        // Two lines of unchanged context is what fits and what reads.
        for line in oldLines.prefix(prefix).suffix(2) { lines.append(.context(line)) }
        for line in oldLines[prefix..<(oldLines.count - suffix)] { lines.append(.removed(line)) }
        for line in newLines[prefix..<(newLines.count - suffix)] { lines.append(.added(line)) }
        for line in oldLines.suffix(suffix).prefix(2) { lines.append(.context(line)) }
        return lines
    }

    // MARK: - Shared

    /// Tool input arrives as an object, or as the JSON text of one.
    static func dictionary(_ input: Any?) -> [String: Any]? {
        if let object = input as? [String: Any] { return object }
        if let text = input as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return parsed
        }
        return nil
    }
}
