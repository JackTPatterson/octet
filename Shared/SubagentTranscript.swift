import Foundation

/// Finds `agent-<id>.jsonl` for a tool call by its sibling `.meta.json`.
struct SubagentTranscriptLocator {
    let directory: String
    let toolUseId: String?
    let description: String?
    let since: TimeInterval

    func find() -> URL? {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        var descriptionMatch: (url: URL, modified: Date)?
        for name in names where name.hasSuffix(".meta.json") {
            let metaURL = directoryURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let transcript = directoryURL.appendingPathComponent(
                String(name.dropLast(".meta.json".count)) + ".jsonl"
            )
            if let toolUseId, meta["toolUseId"] as? String == toolUseId {
                return transcript
            }
            guard toolUseId == nil || meta["toolUseId"] == nil,
                  let description, meta["description"] as? String == description,
                  let modified = (try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified.timeIntervalSince1970 >= since else { continue }
            if descriptionMatch == nil || modified > descriptionMatch!.modified {
                descriptionMatch = (transcript, modified)
            }
        }
        return descriptionMatch?.url
    }
}

/// Renders a Claude Code subagent transcript JSONL as a compact live log.
final class SubagentTranscriptRenderer {
    /// Called when the transcript reports the subagent finished its turn.
    var onFinished: (() -> Void)?
    /// Called on every pass of the tail loop, for work that waits on time.
    var onTick: (() -> Void)?
    /// Called with the subagent's folder when it first shows and on each change.
    var onDirectory: ((String) -> Void)?
    /// When the subagent last finished; cleared if it is sent more work.
    private(set) var finishedAt: Date?
    /// The folder the tab opened in, where the parent agent was.
    var home = FileManager.default.currentDirectoryPath
    private var cwd: String?
    private var location: AgentLocation?

    private let esc = "\u{1B}["

    func bold(_ s: String) -> String { "\(esc)1m\(s)\(esc)0m" }
    func dim(_ s: String) -> String { "\(esc)2m\(s)\(esc)0m" }
    private func color(_ code: Int, _ s: String) -> String { "\(esc)\(code)m\(s)\(esc)0m" }

    func printHeader(title: String) {
        print("\u{1B}]0;\(title)\u{07}", terminator: "")
        print(bold("▶ \(title)"))
        print(dim("Waiting for the subagent to start…"))
    }

    /// Tails the transcript forever, printing each complete line as it lands.
    func follow(_ url: URL) {
        var offset: UInt64 = 0
        var pending = Data()
        while true {
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.seek(toOffset: offset)) != nil,
                   let chunk = try? handle.readToEnd(), !chunk.isEmpty {
                    offset += UInt64(chunk.count)
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<newline]
                        pending.removeSubrange(pending.startIndex...newline)
                        render(line: Data(line))
                    }
                }
            }
            onTick?()
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    func render(line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = entry["message"] as? [String: Any] else { return }
        if let cwd = entry["cwd"] as? String, !cwd.isEmpty, cwd != self.cwd {
            moved(to: cwd)
        }
        // Anything after a finish means the subagent is working again.
        finishedAt = nil
        switch entry["type"] as? String {
        case "assistant":
            let blocks = message["content"] as? [[String: Any]] ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { print("⏺ " + text) }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let summary = Self.toolSummary(block["input"] as? [String: Any])
                    print(color(36, "⏺ " + bold(name)) + (summary.isEmpty ? "" : dim("(\(summary))")))
                case "thinking":
                    print(dim("✻ Thinking…"))
                default:
                    break
                }
            }
            // Claude splits one turn into several lines (thinking, text) that
            // all carry end_turn; the turn is finished at the one with text.
            let hasText = blocks.contains { $0["type"] as? String == "text" }
            if message["stop_reason"] as? String == "end_turn", hasText {
                print(color(32, bold("✓ Subagent finished")))
                finishedAt = Date()
                onFinished?()
            }
        case "user":
            if let prompt = message["content"] as? String {
                let visiblePrompt = prompt.components(separatedBy: "<system-reminder>").first ?? prompt
                let preview = visiblePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").prefix(3).joined(separator: "\n")
                print(dim(Self.truncate(preview, 300)))
                print("")
                return
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                let text = Self.resultText(block["content"])
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
                let line = "  ⎿ " + Self.truncate(firstLine.isEmpty ? "done" : firstLine, 120)
                print(block["is_error"] as? Bool == true ? color(31, line) : dim(line))
            }
        default:
            break
        }
    }

    /// Says so when the subagent changes folder, but only as often as the
    /// place it is in changes: flipping between two folders of one repo is
    /// news, a second line of the same place is not.
    private func moved(to cwd: String) {
        let first = self.cwd == nil
        self.cwd = cwd
        onDirectory?(cwd)
        let location = AgentLocations.locate(cwd, home: home)
        guard location != self.location else { return }
        self.location = location
        if let line = Self.locationLine(location, home: home) {
            if !first || location != nil { print(line) }
        }
    }

    /// "⤷ In worktree agent-a84… on main" and the path under it, dim.
    static func locationLine(_ location: AgentLocation?, home: String) -> String? {
        let esc = "\u{1B}["
        let arrow = "\(esc)35m⤷\(esc)0m "
        guard let location else {
            return arrow + "\(esc)2mBack in \((home as NSString).lastPathComponent)\(esc)0m"
        }
        let place: String
        switch location.kind {
        case .worktree: place = "In worktree "
        case .repository: place = "In repository "
        case .subfolder, .folder: place = "In "
        }
        let branch = location.branch.map { "\(esc)2m on \(esc)0m\(esc)35m\($0)\(esc)0m" } ?? ""
        return arrow + place + "\(esc)1m\(location.name)\(esc)0m" + branch
            + "\n  \(esc)2m\(abbreviateHome(location.path))\(esc)0m"
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func toolSummary(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        if let skill = input["skill"] as? String, !skill.isEmpty { return truncate(skill, 100) }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value.replacingOccurrences(of: "\n", with: " "), 100)
            }
        }
        return ""
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func truncate(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }
}
