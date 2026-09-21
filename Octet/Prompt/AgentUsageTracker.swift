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

    private unowned let store: SessionStore
    private var paths: [String: String] = [:]
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
        lastRead = Date()
        let agents = store.snapshot.agents.compactMap { agent -> (terminal: String, path: String)? in
            guard let terminal = agent.terminalId else { return nil }
            if let known = paths[terminal] { return (terminal, known) }
            guard let path = transcriptPath(for: agent) else { return nil }
            paths[terminal] = path
            return (terminal, path)
        }
        guard !agents.isEmpty else { return }
        let kinds = Dictionary(store.snapshot.agents.compactMap { agent in
            agent.terminalId.map { ($0, agent.agent ?? "") }
        }, uniquingKeysWith: { first, _ in first })

        DispatchQueue.global(qos: .utility).async {
            var found: [String: TwinUsage] = [:]
            var activity: [String: String] = [:]
            for agent in agents {
                guard let text = Self.tail(agent.path) else { continue }
                let conversation = TwinTranscript.parse(agent: kinds[agent.terminal],
                                                        lines: text.components(separatedBy: "\n"))
                if let usage = conversation.usage, usage.currentContextTokens > 0 {
                    found[agent.terminal] = usage
                }
                if let line = Self.lastLine(of: conversation) {
                    activity[agent.terminal] = line
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (terminal, usage) in found where self.usage[terminal] != usage {
                    self.usage[terminal] = usage
                }
                for (terminal, line) in activity where self.lastActivity[terminal] != line {
                    self.lastActivity[terminal] = line
                }
            }
        }
    }

    /// Where this agent writes its session, from what recovery already knows.
    private func transcriptPath(for agent: EngineAgent) -> String? {
        guard let terminal = agent.terminalId,
              let record = store.recovery.resumableSessions().first(where: { $0.terminalId == terminal })
                ?? store.recovery.record(forTerminal: terminal),
              let sessionId = record.sessionId else { return nil }
        switch AgentBrand.forAgent(agent.agent)?.id {
        case "codex":
            return AgentSessionFiles.codexPath(forSession: sessionId)
        default:
            let directory = ClaudeTranscriptActivity.projectDirectory(forCwd: record.cwd)
            return "\(directory)/\(sessionId).jsonl"
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
                    return summary.isEmpty ? name : "\(name): \(summary)"
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
