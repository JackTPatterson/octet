import Foundation

/// What agents ran in a project, from their own transcripts, with the
/// commands worth a second look flagged: the timeline to check after
/// letting an agent run on its own.
enum AgentAudit {
    struct Entry: Equatable {
        let date: Date
        let agent: String
        let command: String
        let risks: [String]
    }

    /// Commands that delete, overwrite history, escalate or run code from
    /// the network, by what they'd do.
    static let rules: [(String, NSRegularExpression)] = [
        ("deletes recursively", #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|-r\s+-f|-f\s+-r|--recursive)\b"#),
        ("force-pushes", #"\bgit\s+push\b.*(\s-f\b|--force)"#),
        ("discards changes", #"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f|checkout\s+--\s+\.|restore\s+\.)"#),
        ("runs as root", #"(^|[;&|\n]\s*)sudo\b"#),
        ("runs a downloaded script", #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#),
        ("opens permissions wide", #"\bchmod\s+(-R\s+)?777\b"#),
        ("writes a raw disk", #"\b(dd\s+.*of=/dev/|mkfs)"#),
        ("drops data", #"(?i)\bdrop\s+(table|database)\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func risks(_ command: String) -> [String] {
        // A heredoc's body is text being written, not run.
        let command = withoutHeredocs(command)
        let range = NSRange(command.startIndex..., in: command)
        return rules.filter { $0.1.firstMatch(in: command, range: range) != nil }.map(\.0)
    }

    /// `cat > f <<'EOF' … EOF`: drops everything from the line after `<<X`
    /// through the line that is just `X`.
    static func withoutHeredocs(_ command: String) -> String {
        var lines = command.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let match = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) {
                let marker = String(line[match]).replacingOccurrences(of: #"^<<-?\s*['"]?|['"]?$"#, with: "", options: .regularExpression)
                var end = index + 1
                while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces) != marker { end += 1 }
                lines.removeSubrange((index + 1)..<min(end, lines.count))
            }
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Claude Code: an assistant message's Bash tool uses.
    static func claude(line: String) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
              let when = date(object["timestamp"]) else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                  let command = (block["input"] as? [String: Any])?["command"] as? String else { return nil }
            return Entry(date: when, agent: "claude", command: command, risks: risks(command))
        }
    }

    private static let cmdPattern = try! NSRegularExpression(pattern: #""cmd"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// Codex: `exec` tool calls (`exec_command({"cmd": …})`), and the older
    /// `shell` / `exec_command` function calls.
    static func codex(line: String) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String, type == "custom_tool_call" || type == "function_call",
              let when = date(object["timestamp"]) else { return [] }
        let body = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
        var commands: [String] = []
        let range = NSRange(body.startIndex..., in: body)
        for match in cmdPattern.matches(in: body, range: range) {
            guard let raw = Range(match.range(at: 1), in: body),
                  let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(body[raw])\"".utf8), options: .fragmentsAllowed) as? String
            else { continue }
            commands.append(decoded)
        }
        if commands.isEmpty, payload["name"] as? String == "shell",
           let args = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let parts = args["command"] as? [String] {
            commands.append(parts.last ?? parts.joined(separator: " "))
        }
        return commands.map { Entry(date: when, agent: "codex", command: $0, risks: risks($0)) }
    }

    /// Everything run in `cwd` since `since`, newest first: Claude's
    /// transcripts for the folder, and Codex sessions that started there.
    static func load(cwd: String, since: Date, home: String = NSHomeDirectory()) -> [Entry] {
        var entries: [Entry] = []
        let files = FileManager.default
        // Transcripts run to hundreds of megabytes: only the lines holding
        // one of the needles are turned into strings to be parsed.
        func lines(_ path: String, containing needles: [String]) -> [String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return [] }
            let patterns = needles.map { Data($0.utf8) }
            var found: [String] = []
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                let line = data[start..<end]
                if patterns.contains(where: { line.range(of: $0) != nil }) {
                    found.append(String(decoding: line, as: UTF8.self))
                }
                start = data.index(after: end)
            }
            return found
        }
        func modified(_ path: String) -> Date {
            (try? files.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        }
        let claude = ClaudeTranscriptActivity.projectDirectory(forCwd: cwd, home: home)
        for name in (try? files.contentsOfDirectory(atPath: claude)) ?? [] where name.hasSuffix(".jsonl") {
            let path = claude + "/" + name
            guard modified(path) >= since else { continue }
            entries += lines(path, containing: ["\"Bash\""]).flatMap(Self.claude(line:))
        }
        let calendar = Calendar(identifier: .gregorian)
        let days = max(1, calendar.dateComponents([.day], from: since, to: Date()).day ?? 1) + 1
        for codexHome in AccountProfiles.allCodexHomes(home: home) {
            for offset in 0..<min(days, 14) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let folder = String(format: "%@/sessions/%04d/%02d/%02d", codexHome, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
                for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                    let path = folder + "/" + name
                    guard modified(path) >= since, AgentSessionFiles.codexSessionMeta(path)?.cwd == cwd else { continue }
                    entries += lines(path, containing: ["cmd", "\"command\""]).flatMap(Self.codex(line:))
                }
            }
        }
        return entries.filter { $0.date >= since }.sorted { $0.date > $1.date }
    }
}
