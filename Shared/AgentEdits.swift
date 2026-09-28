import Foundation

/// Which files each agent edited, from the agents' own records: Claude
/// Code's transcripts (its session's, and each subagent's beside it) and
/// Codex's session log. Only edits made through an edit tool are seen; a
/// file changed from a shell command, or by hand, belongs to no one.
enum AgentEdits {
    /// Claude Code's file-editing tools and where each keeps its path.
    static let claudeTools: [String: String] = [
        "Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path",
    ]

    /// The paths one Claude transcript line edited, as the agent wrote them
    /// (absolute).
    static func claudePaths(line: String) -> [String] {
        guard line.contains("\"tool_use\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use", let name = item["name"] as? String,
                  let key = claudeTools[name], let input = item["input"] as? [String: Any] else { return nil }
            return input[key] as? String
        }
    }

    /// The paths an `apply_patch` in one Codex log line touched, resolved
    /// against the folder Codex works in.
    static func codexPaths(line: String, cwd: String?) -> [String] {
        guard line.contains("*** "), line.contains(" File: ") else { return [] }
        // The patch is JSON-escaped inside the line, so its newlines are "\n".
        let text = line.replacingOccurrences(of: "\\n", with: "\n")
        var paths: [String] = []
        for raw in text.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] {
                guard let range = raw.range(of: marker) else { continue }
                var path = String(raw[range.upperBound...])
                // Whatever closes the JSON string ends it too.
                if let quote = path.firstIndex(of: "\"") { path = String(path[..<quote]) }
                path = path.trimmingCharacters(in: .whitespaces)
                // Escaped twice (a patch inside a JSON argument string), a
                // backslash is left where the newline was.
                while path.hasSuffix("\\") { path.removeLast() }
                guard !path.isEmpty else { continue }
                if !path.hasPrefix("/"), let cwd { path = (cwd as NSString).appendingPathComponent(path) }
                paths.append(path)
            }
        }
        return paths
    }

    // MARK: - Finding the records

    /// A Claude session's transcript: under the folder it started in, for
    /// whichever account that folder uses, else anywhere an account keeps one.
    static func claudeTranscript(sessionId: String, cwds: [String], home: String = NSHomeDirectory()) -> String? {
        let files = FileManager.default
        for cwd in cwds {
            let path = ClaudeTranscriptActivity.projectDirectory(forCwd: cwd, home: home) + "/\(sessionId).jsonl"
            if files.fileExists(atPath: path) { return path }
        }
        for claudeHome in AccountProfiles.allClaudeHomes(home: home) {
            let projects = claudeHome + "/projects"
            for project in (try? files.contentsOfDirectory(atPath: projects)) ?? [] {
                let path = "\(projects)/\(project)/\(sessionId).jsonl"
                if files.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    struct SubagentRecord: Equatable {
        let transcript: String
        let toolUseId: String?
        let description: String?
    }

    /// The subagents a Claude session started, each with the tool call that
    /// started it, which its viewer tab reports too.
    static func claudeSubagents(ofTranscript transcript: String) -> [SubagentRecord] {
        let directory = String(transcript.dropLast(".jsonl".count)) + "/subagents"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { name in
            let meta = directory + "/" + name.dropLast(".jsonl".count) + ".meta.json"
            let object = (try? Data(contentsOf: URL(fileURLWithPath: meta)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return SubagentRecord(transcript: directory + "/" + name,
                                  toolUseId: object?["toolUseId"] as? String,
                                  description: object?["description"] as? String)
        }
    }
}

/// Reads transcripts as they grow: each file is parsed from where the last
/// read stopped, so a long session costs only its new lines. Safe to use
/// from any one background queue at a time; a lock guards the cache.
final class AgentEditLog: @unchecked Sendable {
    private struct Tail {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var paths: Set<String> = []
    }

    private var tails: [String: Tail] = [:]
    /// Where each session's record was found, so it's looked for once.
    private var locations: [String: String] = [:]
    private let lock = NSLock()

    /// The file for `key`, found once with `find` and remembered while it
    /// still exists.
    func resolve(_ key: String, find: () -> String?) -> String? {
        lock.lock()
        let known = locations[key]
        lock.unlock()
        if let known, FileManager.default.fileExists(atPath: known) { return known }
        guard let found = find() else { return nil }
        lock.lock()
        locations[key] = found
        lock.unlock()
        return found
    }

    /// Every path `parse` finds in the file's lines, from its start. Only
    /// lines holding one of `needles` are decoded and parsed.
    func paths(in file: String, needles: [String], parse: (String) -> [String]) -> Set<String> {
        lock.lock()
        var tail = tails[file] ?? Tail()
        lock.unlock()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.uint64Value else {
            return tail.paths
        }
        // Rewritten or truncated: start over.
        if size < tail.size { tail = Tail() }
        if size > tail.offset,
           let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe),
           UInt64(data.count) > tail.offset {
            let patterns = needles.map { Data($0.utf8) }
            let fresh = data[(data.startIndex + Int(tail.offset))...]
            // Only whole lines; a line still being written waits.
            if let lastNewline = fresh.lastIndex(of: 0x0A) {
                var start = fresh.startIndex
                while start <= lastNewline {
                    let end = fresh[start...].firstIndex(of: 0x0A) ?? lastNewline
                    let line = fresh[start..<end]
                    if patterns.contains(where: { line.range(of: $0) != nil }) {
                        tail.paths.formUnion(parse(String(decoding: line, as: UTF8.self)))
                    }
                    start = end + 1
                }
                tail.offset += UInt64(lastNewline - fresh.startIndex + 1)
            }
        }
        tail.size = size
        lock.lock()
        tails[file] = tail
        lock.unlock()
        return tail.paths
    }
}
