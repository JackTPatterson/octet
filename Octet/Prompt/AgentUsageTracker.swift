import AppKit
import Foundation

/// How full each running agent's context is, read from the session files the
/// agents already write. Rate limits and context exhaustion are two of the
/// things people complain about most, and both are invisible until they
/// bite — this makes them visible while there is still room to act.
@MainActor
final class AgentUsageTracker: ObservableObject {
    /// Usage per terminal id, so it follows the pane rather than the tab.
    @Published private(set) var usage: [String: TwinUsage] = [:]
    /// The last thing each agent said or did, for the board.
    @Published private(set) var lastActivity: [String: String] = [:]
    /// The tool behind a terminal's last activity line, when that line is a tool call.
    @Published private(set) var lastTool: [String: String] = [:]

    private unowned let store: SessionStore
    private var paths: [String: String] = [:]
    /// Agents whose session wasn't found, and when: not looked for again
    /// for a while, as each look can list folders.
    private var misses: [String: Date] = [:]
    private static let retryMissAfter: TimeInterval = 60
    private var lastRead = Date.distantPast
    private static let interval: TimeInterval = 5

    init(store: SessionStore) {
        self.store = store
    }

    func usage(forTerminal terminalId: String?) -> TwinUsage? {
        terminalId.flatMap { usage[$0] }
    }

    /// Called from the snapshot loop; reads at most every few seconds and
    /// only while Octet is the active app.
    func refreshIfDue() {
        guard NSApp?.isActive == true, Date().timeIntervalSince(lastRead) >= Self.interval else { return }
        let now = Date()
        lastRead = now
        // Asked at most once, not once per agent.
        var resumable: [AgentSessionRecord]?
        var known: [(terminal: String, path: String)] = []
        var lookups: [(terminal: String, lookup: PathLookup)] = []
        for agent in store.snapshot.agents {
            guard let terminal = agent.terminalId else { continue }
            if let path = paths[terminal] {
                known.append((terminal, path))
                continue
            }
            if let missed = misses[terminal], now.timeIntervalSince(missed) < Self.retryMissAfter { continue }
            let records = resumable ?? store.recovery.resumableSessions()
            resumable = records
            guard let lookup = transcriptLookup(for: agent, terminal: terminal, resumable: records) else {
                misses[terminal] = now
                continue
            }
            lookups.append((terminal, lookup))
        }
        guard !known.isEmpty || !lookups.isEmpty else { return }
        let kinds = Dictionary(store.snapshot.agents.compactMap { agent in
            agent.terminalId.map { ($0, agent.agent ?? "") }
        }, uniquingKeysWith: { first, _ in first })

        DispatchQueue.global(qos: .utility).async {
            // Finding a Codex session lists its folders: done here, not on main.
            var resolved: [String: String?] = [:]
            for (terminal, lookup) in lookups {
                switch lookup {
                case .path(let path): resolved[terminal] = path
                case .codex(let sessionId): resolved[terminal] = AgentSessionFiles.codexPath(forSession: sessionId)
                }
            }
            let agents = known + resolved.compactMap { terminal, path in path.map { (terminal, $0) } }
            var found: [String: TwinUsage] = [:]
            var activity: [String: String] = [:]
            var tools: [String: String] = [:]
            for agent in agents {
                guard let text = Self.tail(agent.path) else { continue }
                let conversation = TwinTranscript.parse(agent: kinds[agent.terminal],
                                                        lines: text.components(separatedBy: "\n"))
                if let usage = conversation.usage, usage.currentContextTokens > 0 {
                    found[agent.terminal] = usage
                }
                if let line = Self.lastLine(of: conversation) {
                    activity[agent.terminal] = line
                    tools[agent.terminal] = Self.lastToolName(of: conversation) ?? ""
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (terminal, path) in resolved {
                    if let path { self.paths[terminal] = path; self.misses[terminal] = nil } else { self.misses[terminal] = now }
                }
                for (terminal, usage) in found where self.usage[terminal] != usage {
                    self.usage[terminal] = usage
                }
                for (terminal, line) in activity where self.lastActivity[terminal] != line {
                    self.lastActivity[terminal] = line
                }
                for (terminal, tool) in tools where self.lastTool[terminal] != tool {
                    self.lastTool[terminal] = tool
                }
            }
        }
    }

    /// How to find an agent's session file: a path already, or a Codex
    /// session to look for.
    private enum PathLookup {
        case path(String)
        case codex(sessionId: String)
    }

    /// Where this agent writes its session, from what recovery already knows.
    private func transcriptLookup(for agent: EngineAgent, terminal: String,
                                  resumable: [AgentSessionRecord]) -> PathLookup? {
        guard let record = resumable.first(where: { $0.terminalId == terminal })
                ?? store.recovery.record(forTerminal: terminal),
              let sessionId = record.sessionId else { return nil }
        switch AgentBrand.forAgent(agent.agent)?.id {
        case "codex":
            return .codex(sessionId: sessionId)
        default:
            let directory = ClaudeTranscriptActivity.projectDirectory(forCwd: record.cwd)
            return .path("\(directory)/\(sessionId).jsonl")
        }
    }

    /// The newest thing worth reading: what it said, or what it is doing.
    nonisolated static func lastLine(of conversation: TwinConversation) -> String? {
        for message in conversation.messages.reversed() {
            for block in message.blocks.reversed() {
                switch block {
                case .text(let text):
                    let line = TwinTranscript.condense(text)
                    if !line.isEmpty { return line }
                case .toolCall(_, let name, let summary):
                    let shown = AgentToolCall.displayName(forTool: name)
                    return summary.isEmpty ? shown : "\(shown): \(summary)"
                case .thinking, .toolResult:
                    continue
                }
            }
        }
        return nil
    }

    /// The tool of the newest block `lastLine` reads, if that block is a tool call.
    nonisolated static func lastToolName(of conversation: TwinConversation) -> String? {
        for message in conversation.messages.reversed() {
            for block in message.blocks.reversed() {
                switch block {
                case .text(let text):
                    if !TwinTranscript.condense(text).isEmpty { return nil }
                case .toolCall(_, let name, _):
                    return name
                case .thinking, .toolResult:
                    continue
                }
            }
        }
        return nil
    }

    /// Only the tail matters: the newest turn carries the context in play.
    private nonisolated static func tail(_ path: String, bytes: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let length = min(size, UInt64(bytes))
        try? handle.seek(toOffset: size - length)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
