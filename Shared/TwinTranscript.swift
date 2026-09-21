import Foundation

/// A conversation as Octet shows it, whichever agent produced it. Agents
/// already write their turns as structured JSONL, so the visual twin reads
/// that rather than scraping a terminal UI — which is what makes it possible
/// to draw a real interface over any agent.
struct TwinConversation: Equatable {
    var messages: [TwinMessage] = []
    var title: String?
    var model: String?
    var cwd: String?
    var usage: TwinUsage?
    /// How far through the file the parse got, so tailing can resume.
    var consumedLines = 0
}

struct TwinMessage: Identifiable, Equatable {
    enum Role: String, Equatable { case user, assistant, system }

    enum Block: Equatable {
        case text(String)
        /// Reasoning the agent showed; collapsed by default in the UI.
        case thinking(String)
        case toolCall(id: String, name: String, summary: String)
        case toolResult(id: String, summary: String, isError: Bool)
    }

    let id: String
    let role: Role
    var blocks: [Block]
    var at: Date?

    /// True when there is nothing worth drawing.
    var isEmpty: Bool {
        blocks.allSatisfy { block in
            if case .text(let text) = block { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }
}

struct TwinUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    /// What the model's window holds, when the agent records it.
    var contextWindow: Int?

    var total: Int { inputTokens + outputTokens }
}

enum TwinTranscript {
    /// Parses whichever format the agent writes.
    static func parse(agent: String?, lines: [String]) -> TwinConversation {
        switch AgentBrand.forAgent(agent)?.id {
        case "codex": parseCodex(lines: lines)
        default: parseClaude(lines: lines)
        }
    }

    // MARK: - Claude Code

    /// `user` and `assistant` lines carrying Anthropic content blocks.
    static func parseClaude(lines: [String]) -> TwinConversation {
        var conversation = TwinConversation()
        for line in lines {
            conversation.consumedLines += 1
            guard let object = json(line) else { continue }
            switch object["type"] as? String {
            case "ai-title":
                conversation.title = object["aiTitle"] as? String ?? conversation.title
            case "user", "assistant":
                guard let message = object["message"] as? [String: Any] else { continue }
                let role: TwinMessage.Role = (object["type"] as? String) == "user" ? .user : .assistant
                if let model = message["model"] as? String { conversation.model = model }
                if let cwd = object["cwd"] as? String { conversation.cwd = cwd }
                if let usage = message["usage"] as? [String: Any] {
                    conversation.usage = claudeUsage(usage, into: conversation.usage)
                }
                let blocks = claudeBlocks(message["content"])
                guard !blocks.isEmpty else { continue }
                let id = object["uuid"] as? String ?? UUID().uuidString
                conversation.messages.append(TwinMessage(
                    id: id, role: role, blocks: blocks, at: date(object["timestamp"])
                ))
            default:
                continue
            }
        }
        return conversation
    }

    private static func claudeBlocks(_ content: Any?) -> [TwinMessage.Block] {
        // A plain string is the whole message.
        if let text = content as? String {
            return text.isEmpty ? [] : [.text(text)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                return text.isEmpty ? nil : .text(text)
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                return text.isEmpty ? nil : .thinking(text)
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return .toolCall(
                    id: block["id"] as? String ?? UUID().uuidString,
                    name: name,
                    summary: toolSummary(name: name, input: block["input"])
                )
            case "tool_result":
                let isError = block["is_error"] as? Bool ?? false
                return .toolResult(
                    id: block["tool_use_id"] as? String ?? "",
                    summary: resultSummary(block["content"]),
                    isError: isError
                )
            default:
                return nil
            }
        }
    }

    private static func claudeUsage(_ raw: [String: Any], into existing: TwinUsage?) -> TwinUsage {
        var usage = existing ?? TwinUsage()
        usage.inputTokens += raw["input_tokens"] as? Int ?? 0
        usage.outputTokens += raw["output_tokens"] as? Int ?? 0
        usage.cacheReadTokens += raw["cache_read_input_tokens"] as? Int ?? 0
        return usage
    }

    // MARK: - Codex

    /// `response_item` lines carry the turns; usage and context window come
    /// from the records beside them.
    static func parseCodex(lines: [String]) -> TwinConversation {
        var conversation = TwinConversation()
        var pendingCalls: [String: String] = [:]
        for line in lines {
            conversation.consumedLines += 1
            guard let object = json(line), let payload = object["payload"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "session_meta":
                conversation.cwd = payload["cwd"] as? String ?? conversation.cwd
            case "turn_context":
                conversation.cwd = payload["cwd"] as? String ?? conversation.cwd
            case "event_msg":
                if let window = payload["model_context_window"] as? Int {
                    var usage = conversation.usage ?? TwinUsage()
                    usage.contextWindow = window
                    conversation.usage = usage
                }
            case "token_usage_record":
                if let usage = payload["usage"] as? [String: Any] {
                    var current = conversation.usage ?? TwinUsage()
                    current.inputTokens += usage["input_tokens"] as? Int ?? 0
                    current.outputTokens += usage["output_tokens"] as? Int ?? 0
                    current.cacheReadTokens += usage["cached_input_tokens"] as? Int ?? 0
                    conversation.usage = current
                }
            case "response_item":
                let id = payload["id"] as? String ?? UUID().uuidString
                switch payload["type"] as? String {
                case "message":
                    let role: TwinMessage.Role = (payload["role"] as? String) == "user" ? .user : .assistant
                    let blocks = codexBlocks(payload["content"])
                    guard !blocks.isEmpty else { continue }
                    conversation.messages.append(TwinMessage(
                        id: id, role: role, blocks: blocks, at: date(object["timestamp"])
                    ))
                case "reasoning":
                    let text = codexText(payload["summary"] ?? payload["content"])
                    guard !text.isEmpty else { continue }
                    conversation.messages.append(TwinMessage(
                        id: id, role: .assistant, blocks: [.thinking(text)], at: date(object["timestamp"])
                    ))
                case "function_call", "local_shell_call", "custom_tool_call":
                    let name = payload["name"] as? String ?? "tool"
                    let callId = payload["call_id"] as? String ?? id
                    pendingCalls[callId] = name
                    conversation.messages.append(TwinMessage(
                        id: id,
                        role: .assistant,
                        blocks: [.toolCall(id: callId, name: name,
                                           summary: toolSummary(name: name, input: payload["arguments"]))],
                        at: date(object["timestamp"])
                    ))
                case "function_call_output", "local_shell_call_output", "custom_tool_call_output":
                    let callId = payload["call_id"] as? String ?? id
                    conversation.messages.append(TwinMessage(
                        id: id,
                        role: .user,
                        blocks: [.toolResult(id: callId, summary: resultSummary(payload["output"]), isError: false)],
                        at: date(object["timestamp"])
                    ))
                default:
                    continue
                }
            default:
                continue
            }
        }
        return conversation
    }

    private static func codexBlocks(_ content: Any?) -> [TwinMessage.Block] {
        let text = codexText(content)
        return text.isEmpty ? [] : [.text(text)]
    }

    private static func codexText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            part["text"] as? String ?? part["content"] as? String
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Summaries

    /// One line describing a tool call, from whichever field carries meaning.
    static func toolSummary(name: String, input: Any?) -> String {
        var object = input as? [String: Any]
        // Codex passes arguments as a JSON string.
        if object == nil, let text = input as? String {
            object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            if object == nil { return condense(text) }
        }
        guard let object else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
            if let value = object[key] as? String, !value.isEmpty { return condense(value) }
        }
        if let command = object["command"] as? [String] { return condense(command.joined(separator: " ")) }
        return condense(object.keys.sorted().joined(separator: ", "))
    }

    static func resultSummary(_ content: Any?) -> String {
        if let text = content as? String { return condense(text) }
        if let blocks = content as? [[String: Any]] {
            return condense(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        }
        if let object = content as? [String: Any] {
            return condense(object["output"] as? String ?? object["content"] as? String ?? "")
        }
        return ""
    }

    /// First meaningful line, trimmed to something a row can hold.
    static func condense(_ text: String, limit: Int = 120) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    // MARK: - Files

    private static func json(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
