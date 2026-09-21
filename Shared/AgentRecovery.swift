import Foundation

/// A durable record of an agent session Herd has seen running, so it can be
/// resumed after the session server restarts (a Mac shutdown kills every pane).
struct AgentSessionRecord: Codable, Equatable, Identifiable {
    var agent: String
    var sessionId: String?
    /// Where the agent was launched: `--resume` reopens it here.
    var cwd: String
    /// Where it had moved to, when that differs.
    var currentCwd: String?
    var workspaceLabel: String
    var tabLabel: String
    var terminalId: String
    var firstSeen: Date
    var lastSeen: Date
    /// Set once the user resumed or dismissed it, so it isn't offered again.
    var handled = false

    var id: String { terminalId }

    /// Shell command that reopens this conversation, or nil when unknown.
    var resumeCommand: String? {
        guard let sessionId else { return nil }
        return AgentRecovery.resumeCommand(agent: agent, sessionId: sessionId)
    }
}

enum AgentRecovery {
    /// Resume commands from the session server's native session restore table.
    static func resumeCommand(agent: String, sessionId: String) -> String? {
        let id = shellQuoted(sessionId)
        switch AgentBrand.forAgent(agent)?.id ?? agent {
        case "claude": return "claude --resume \(id)"
        case "codex": return "codex resume \(id)"
        case "opencode": return "opencode --session \(id)"
        case "cursor": return "cursor-agent --resume \(id)"
        case "grok": return "grok --resume \(id)"
        case "copilot": return "copilot --resume=\(id)"
        case "devin": return "devin --resume \(id)"
        case "kimi": return "kimi --session \(id)"
        case "qwen": return "qwen --resume \(id)"
        case "hermes": return "hermes --resume \(id)"
        case "pi": return "pi --session \(id)"
        case "agy": return "agy --conversation \(id)"
        default: return nil
        }
    }

    /// Agents whose sessions Herd can find without a session server integration.
    static let inferable: Set<String> = ["claude", "codex"]

    private static func shellQuoted(_ value: String) -> String {
        value.range(of: "^[A-Za-z0-9_.:=-]+$", options: .regularExpression) != nil
            ? value
            : "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Updates the journal from a snapshot. `sessionIdFor` resolves a session
    /// id for an agent (integration report or file inference).
    static func record(
        _ snapshot: EngineSnapshot,
        into journal: [AgentSessionRecord],
        now: Date = Date(),
        sessionIdFor: (EngineAgent, AgentSessionRecord?) -> String?
    ) -> [AgentSessionRecord] {
        var byTerminal = Dictionary(journal.map { ($0.terminalId, $0) }, uniquingKeysWith: { _, last in last })
        let workspaceLabels = Dictionary(snapshot.workspaces.map { ($0.workspaceId, $0.label) }, uniquingKeysWith: { first, _ in first })
        let tabLabels = Dictionary(snapshot.tabs.map { ($0.tabId, $0.label) }, uniquingKeysWith: { first, _ in first })
        for agent in snapshot.agents {
            guard let kind = agent.agent, let terminalId = agent.terminalId,
                  let cwd = agent.cwd ?? snapshot.panes.first(where: { $0.paneId == agent.paneId })?.cwd else { continue }
            // Resuming happens in the folder the agent started in; where it
            // wandered to is remembered separately.
            let current = agent.effectiveCwd
            var record = byTerminal[terminalId] ?? AgentSessionRecord(
                agent: kind, sessionId: nil, cwd: cwd,
                workspaceLabel: "", tabLabel: "", terminalId: terminalId,
                firstSeen: now, lastSeen: now
            )
            record.agent = kind
            record.cwd = cwd
            record.currentCwd = current == cwd ? nil : current
            record.workspaceLabel = agent.workspaceId.flatMap { workspaceLabels[$0] } ?? record.workspaceLabel
            record.tabLabel = agent.tabId.flatMap { tabLabels[$0] } ?? record.tabLabel
            record.lastSeen = now
            if let id = sessionIdFor(agent, record) { record.sessionId = id }
            byTerminal[terminalId] = record
        }
        // Keep a week of history.
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return byTerminal.values.filter { $0.lastSeen >= cutoff }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Sessions that were still running when Herd last observed the session server
    /// (`lastObserved`) and aren't running now: killed by a shutdown, crash,
    /// or session server restart rather than exited by the user while Herd watched.
    static func lostSessions(
        journal: [AgentSessionRecord],
        lastObserved: Date,
        current snapshot: EngineSnapshot,
        liveSessionIds: Set<String> = []
    ) -> [AgentSessionRecord] {
        let liveTerminals = Set(snapshot.agents.compactMap(\.terminalId))
        let live = liveSessionIds.union(snapshot.agents.compactMap(\.sessionReference))
        return journal.filter { record in
            !record.handled
                && record.lastSeen >= lastObserved.addingTimeInterval(-2)
                && !liveTerminals.contains(record.terminalId)
                && record.resumeCommand != nil
                && !(record.sessionId.map(live.contains) ?? false)
        }
    }

    /// `layout.apply` request that reopens a session in its workspace: the
    /// resume command runs in a login shell, which stays open afterwards so
    /// the conversation's output is still there to read.
    static func resumeRequest(
        _ record: AgentSessionRecord,
        shell: String,
        workspaceId: String?,
        tabId: String?
    ) -> [String: Any] {
        let label = record.tabLabel.isEmpty ? (AgentBrand.forAgent(record.agent)?.displayName ?? record.agent) : record.tabLabel
        let command = record.resumeCommand ?? ""
        var params: [String: Any] = [
            "focus": false,
            "root": [
                "type": "pane",
                "label": label,
                "cwd": record.cwd,
                "command": [shell, "-lic", "\(command); exec \(shell) -l"],
            ] as [String: Any],
        ]
        if let tabId { params["tab_id"] = tabId } else { params["tab_label"] = label }
        if let workspaceId { params["workspace_id"] = workspaceId }
        return params
    }

    /// Past sessions that aren't running now, for recovering by hand.
    static func history(journal: [AgentSessionRecord], current snapshot: EngineSnapshot) -> [AgentSessionRecord] {
        let liveTerminals = Set(snapshot.agents.compactMap(\.terminalId))
        var seen = Set<String>()
        return journal.filter { record in
            guard let id = record.sessionId, record.resumeCommand != nil,
                  !liveTerminals.contains(record.terminalId), seen.insert(id).inserted else { return false }
            return true
        }
    }
}

/// On-disk journal: `~/Library/Application Support/Herd/agent-sessions.json`.
struct AgentSessionJournal: Codable, Equatable {
    var lastObserved: Date = .distantPast
    var records: [AgentSessionRecord] = []

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herd/agent-sessions.json")
    }

    static func load(from url: URL = defaultURL) -> AgentSessionJournal {
        guard let data = try? Data(contentsOf: url) else { return AgentSessionJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AgentSessionJournal.self, from: data)) ?? AgentSessionJournal()
    }

    func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Finds agent session ids from the agents' own files when no session server
/// integration reports them.
enum AgentSessionFiles {
    /// Claude: newest `~/.claude/projects/<cwd>/<session>.jsonl` modified
    /// since the agent started.
    static func claudeSession(cwd: String, since: Date, excluding claimed: Set<String> = [], home: String = NSHomeDirectory()) -> String? {
        let directory = ClaudeTranscriptActivity.projectDirectory(forCwd: cwd, home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (String, Date)? in
                let id = String(name.dropLast(6))
                guard !claimed.contains(id) else { return nil }
                let modified = modificationDate(directory + "/" + name)
                return modified >= since.addingTimeInterval(-60) ? (id, modified) : nil
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Codex: newest rollout under `~/.codex/sessions/YYYY/MM/DD` (last three
    /// days) whose `session_meta` cwd matches, modified since the agent started.
    static func codexSession(cwd: String, since: Date, now: Date = Date(), excluding claimed: Set<String> = [], home: String = NSHomeDirectory()) -> String? {
        let calendar = Calendar(identifier: .gregorian)
        var best: (id: String, modified: Date)?
        for dayOffset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            // Local-date folders, like Codex writes them.
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = directory + "/" + name
                let modified = modificationDate(path)
                guard modified >= since.addingTimeInterval(-60), modified > (best?.modified ?? .distantPast),
                      let meta = codexSessionMeta(path), meta.cwd == cwd, !claimed.contains(meta.id) else { continue }
                best = (meta.id, modified)
            }
        }
        return best?.id
    }

    /// Session ids for every Claude/Codex agent without an integration
    /// report, newest-started agent first so each claims a distinct session.
    static func infer(
        agents: [EngineAgent],
        firstSeen: [String: Date],
        now: Date = Date()
    ) -> [String: String] {
        var claimed = Set<String>()
        var result: [String: String] = [:]
        let candidates = agents
            .filter { $0.sessionReference == nil && $0.terminalId != nil && !$0.searchCwds.isEmpty }
            .sorted { (firstSeen[$0.terminalId!] ?? now) > (firstSeen[$1.terminalId!] ?? now) }
        // First pass: files written since the agent appeared. Second pass:
        // agents that have been quiet since Herd first saw them take the
        // newest unclaimed session in their folder.
        for strict in [true, false] {
            for agent in candidates where result[agent.terminalId!] == nil {
                let terminal = agent.terminalId!
                let since = strict ? firstSeen[terminal] ?? now : .distantPast
                // An agent can `cd` while it runs, so try both folders it
                // has been in: the launch one and the current one.
                for cwd in agent.searchCwds {
                    let id: String? = switch AgentBrand.forAgent(agent.agent)?.id {
                    case "claude": claudeSession(cwd: cwd, since: since, excluding: claimed)
                    case "codex": codexSession(cwd: cwd, since: since, now: now, excluding: claimed)
                    default: nil
                    }
                    if let id {
                        claimed.insert(id)
                        result[terminal] = id
                        break
                    }
                }
            }
        }
        return result
    }

    static func codexSessionMeta(_ path: String) -> (id: String, cwd: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return parseCodexSessionMeta(firstLine: String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "")
    }

    static func parseCodexSessionMeta(firstLine: String) -> (id: String, cwd: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    private static func modificationDate(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }
}
