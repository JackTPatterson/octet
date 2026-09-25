import Foundation

/// A Claude Code session the agent view lists (`claude agents --json
/// --all`): background sessions the supervisor runs, and interactive ones
/// open in terminals.
struct BackgroundAgent: Identifiable, Equatable {
    enum Kind: String { case background, interactive }
    enum State: String { case needsInput, working, done, idle }

    /// The short id `claude attach`, `stop`, `rm` and `logs` take.
    let id: String
    let sessionId: String
    let name: String
    let cwd: String
    let kind: Kind
    let state: State
    let startedAt: Date?
    let pid: Int?

    /// Parses the JSON array. The shape isn't documented, so every field is
    /// optional and unknown states read as idle.
    static func parse(_ data: Data) -> [BackgroundAgent] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let sessionId = item["sessionId"] as? String else { return nil }
            let kind = Kind(rawValue: item["kind"] as? String ?? "") ?? .background
            let raw = (item["state"] as? String ?? item["status"] as? String ?? "").lowercased()
            let started = (item["startedAt"] as? String).flatMap(Double.init) ?? item["startedAt"] as? Double
            return BackgroundAgent(
                id: item["id"] as? String ?? String(sessionId.prefix(8)),
                sessionId: sessionId,
                name: (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session",
                cwd: item["cwd"] as? String ?? NSHomeDirectory(),
                kind: kind,
                state: state(raw),
                startedAt: started.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0) },
                pid: (item["pid"] as? String).flatMap(Int.init) ?? item["pid"] as? Int
            )
        }
    }

    static func state(_ raw: String) -> State {
        switch raw {
        case "blocked", "waiting", "needs_input", "needs-input", "awaiting_input", "input": .needsInput
        case "working", "running", "busy", "active", "thinking": .working
        case "done", "completed", "complete", "finished", "exited", "stopped": .done
        default: .idle
        }
    }
}

/// What Claude Code's supervisor records about a background job in
/// `~/.claude/jobs/<id>/state.json`: a one-line status, what it needs from
/// you, and the session whose log holds the conversation.
struct BackgroundJob: Equatable {
    var detail: String?
    var needs: String?
    var logSessionId: String?

    static func load(id: String, home: String = NSHomeDirectory()) -> BackgroundJob? {
        let path = home + "/.claude/jobs/" + id + "/state.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            (json[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return BackgroundJob(detail: text("detail"), needs: text("needs"), logSessionId: text("resumeSessionId"))
    }
}

extension AgentConversation {
    /// The log for the first of `sessionIds` that has one: where the folder
    /// name says, else anywhere under the projects folder (background jobs
    /// may run in a worktree).
    static func findLog(sessionIds: [String], cwd: String, home: String = NSHomeDirectory()) -> String? {
        let manager = FileManager.default
        for id in sessionIds {
            let expected = claudeLogPath(sessionId: id, cwd: cwd, home: home)
            if manager.fileExists(atPath: expected) { return expected }
        }
        // Every account's projects, the one this folder uses first.
        let homes = [AccountProfiles.claudeHome(forCwd: cwd, home: home)] + AccountProfiles.allClaudeHomes(home: home)
        var seen = Set<String>()
        for projects in homes.map({ $0 + "/projects" }) where seen.insert(projects).inserted {
            let folders = (try? manager.contentsOfDirectory(atPath: projects)) ?? []
            for id in sessionIds {
                for folder in folders {
                    let path = projects + "/" + folder + "/" + id + ".jsonl"
                    if manager.fileExists(atPath: path) { return path }
                }
            }
        }
        return nil
    }
}

/// Inline Markdown marks stripped for one-line previews.
func plainPreview(_ text: String) -> String {
    text.replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
        .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
}
