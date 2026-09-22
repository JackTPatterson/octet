import Foundation

/// The file an agent is writing its session into, and which format it is in.
struct TwinSource: Equatable {
    let path: String
    /// Agent id whose format the file is written in; nil means the loose
    /// reader, which is what any agent Octet hasn't met by name gets.
    let format: String?
}

/// Finding that file. Claude and Codex are the two Octet knows by name, so
/// they resolve exactly; every other agent is found the way you would find it
/// yourself — the newest session file under the folder that agent keeps, in
/// the project you are standing in.
enum TwinSources {
    /// Where the agent's session lives, given what recovery already knows.
    /// `since` is when this agent started, when the caller knows it: without
    /// a session id to go on, only a file written since then can be the
    /// conversation you are looking at — the one beside it is last time's.
    static func locate(
        agent: String?,
        sessionId: String?,
        cwds: [String],
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> TwinSource? {
        let id = AgentBrand.forAgent(agent)?.id
        if let sessionId, !sessionId.isEmpty {
            switch id {
            case "claude":
                for cwd in cwds {
                    let path = "\(ClaudeTranscriptActivity.projectDirectory(forCwd: cwd, home: home))/\(sessionId).jsonl"
                    if FileManager.default.fileExists(atPath: path) { return TwinSource(path: path, format: "claude") }
                }
            case "codex":
                if let path = AgentSessionFiles.codexPath(forSession: sessionId, now: now, home: home) {
                    return TwinSource(path: path, format: "codex")
                }
            default:
                // An unknown agent may still name its file after the session.
                if let path = search(agent: id ?? agent, home: home, matching: sessionId) {
                    return TwinSource(path: path, format: id)
                }
            }
        }
        return discover(agent: agent, cwds: cwds, since: since, home: home, now: now)
    }

    /// The newest plausible session file for this agent, when there is no id
    /// to go on. Prefers one that mentions the folder you are working in.
    static func discover(
        agent: String?,
        cwds: [String],
        since: Date? = nil,
        home: String = NSHomeDirectory(),
        now: Date = Date(),
        within: TimeInterval = 7 * 86_400
    ) -> TwinSource? {
        // A minute of slack: an agent writes its first line moments after
        // Octet first sees the process.
        let floor = max(now.addingTimeInterval(-within), since?.addingTimeInterval(-60) ?? .distantPast)
        let id = AgentBrand.forAgent(agent)?.id ?? agent?.lowercased()
        if id == "claude" {
            for cwd in cwds {
                let directory = ClaudeTranscriptActivity.projectDirectory(forCwd: cwd, home: home)
                if let path = newest(in: directory, after: floor) {
                    return TwinSource(path: path, format: "claude")
                }
            }
        }
        // Claude keeps a folder per project, so a file outside this pane's
        // folder is someone else's conversation by construction; there is no
        // second guess worth making.
        guard let id, !id.isEmpty, id != "claude" else { return nil }
        var candidates: [(path: String, modified: Date, looksLikeSession: Bool)] = []
        var seen = Set<String>()
        for directory in directories(for: id, home: home) {
            for path in jsonlFiles(in: directory, newerThan: floor) where seen.insert(path).inserted {
                // The session has to be about the folder this pane is in.
                // Without that, the newest file in the agent's folder is
                // whatever it is doing for some other window.
                guard cwds.contains(where: { mentions(path: path, cwd: $0) }) else { continue }
                candidates.append((path, modificationDate(path), looksLikeSession(path)))
            }
        }
        // A file shaped like a session beats whatever else the agent keeps in
        // there, and then the newest wins.
        let ranked = candidates.sorted { first, second in
            if first.looksLikeSession != second.looksLikeSession { return first.looksLikeSession }
            return first.modified > second.modified
        }
        // An agent's folder holds more than conversations — command history,
        // logs, caches — so the twin takes the best one it can actually read.
        for candidate in ranked.prefix(12) where holdsConversation(candidate.path, format: id) {
            return TwinSource(path: candidate.path, format: id)
        }
        return ranked.first.map { TwinSource(path: $0.path, format: id) }
    }

    /// `rollout-2026-09-17T10-11-12-<uuid>.jsonl`, `<uuid>.jsonl`,
    /// `session-….jsonl` — not `history.jsonl` or `config.jsonl`.
    static func looksLikeSession(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if ["history", "config", "settings", "cache", "log", "logs", "telemetry"].contains(name) { return false }
        // An index of sessions is not one.
        if name.contains("index") || name.hasSuffix("_log") { return false }
        if name.hasPrefix("rollout") || name.hasPrefix("session") || name.hasPrefix("conversation") { return true }
        // A bare id reads as a session.
        return name.count >= 16 && name.contains("-")
    }

    /// Whether the head of this file parses into turns, which is the only
    /// honest test that it is a conversation at all.
    static func holdsConversation(_ path: String, format: String?, bytes: Int = 128 * 1024) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return false }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        // The last line may be cut in half by the read.
        if lines.count > 1 { lines.removeLast() }
        return !TwinTranscript.parse(agent: format, lines: lines).messages.isEmpty
    }

    /// Folders agents keep sessions in, in the order they are worth trying.
    static func directories(for agent: String, home: String = NSHomeDirectory()) -> [String] {
        var paths: [String] = []
        for root in ["\(home)/.\(agent)", "\(home)/.config/\(agent)", "\(home)/Library/Application Support/\(agent)",
                     "\(home)/.local/share/\(agent)"] {
            paths += ["\(root)/sessions", "\(root)/projects", "\(root)/history", "\(root)/conversations", root]
        }
        return paths
    }

    // MARK: - Files

    /// `.jsonl` files under a folder, following the dated subfolders agents
    /// like to nest sessions in, without walking a whole home directory.
    /// Newest folders are visited first, so a session written today is found
    /// even where years of them are kept.
    static func jsonlFiles(
        in directory: String,
        depth: Int = 3,
        limit: Int = 400,
        newerThan: Date? = nil
    ) -> [String] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        var found: [String] = []
        var queue: [(path: String, depth: Int)] = [(directory, 0)]
        while !queue.isEmpty, found.count < limit {
            let next = queue.removeFirst()
            guard let names = try? manager.contentsOfDirectory(atPath: next.path) else { continue }
            var subdirectories: [(path: String, modified: Date)] = []
            for name in names {
                let path = next.path + "/" + name
                var isSub: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isSub) else { continue }
                if isSub.boolValue {
                    if next.depth < depth { subdirectories.append((path, modificationDate(path))) }
                } else if name.hasSuffix(".jsonl") || name.hasSuffix(".ndjson") {
                    if let newerThan, modificationDate(path) < newerThan { continue }
                    found.append(path)
                }
            }
            queue += subdirectories.sorted { $0.modified > $1.modified }.map { ($0.path, next.depth + 1) }
        }
        return found
    }

    private static func newest(in directory: String, after floor: Date) -> String? {
        jsonlFiles(in: directory, depth: 1)
            .map { ($0, modificationDate($0)) }
            .filter { $0.1 >= floor }
            .max { $0.1 < $1.1 }?.0
    }

    private static func search(agent: String?, home: String, matching sessionId: String) -> String? {
        guard let agent, !agent.isEmpty else { return nil }
        for directory in directories(for: agent, home: home) {
            if let match = jsonlFiles(in: directory).first(where: { ($0 as NSString).lastPathComponent.contains(sessionId) }) {
                return match
            }
        }
        return nil
    }

    /// Whether a session file is about this folder, read from its head — the
    /// cwd is recorded in the first line of every format seen so far.
    static func mentions(path: String, cwd: String, bytes: Int = 16 * 1024) -> Bool {
        guard !cwd.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return false }
        return String(decoding: data, as: UTF8.self).contains(cwd)
    }

    private static func modificationDate(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }
}
