import Foundation

/// A conversation as Herd shows it, whichever agent produced it. Agents
/// already write their turns as structured JSONL, so the visual twin reads
/// that rather than scraping a terminal UI — which is what makes it possible
/// to draw a real interface over any agent.
struct TwinConversation: Equatable {
    var messages: [TwinMessage] = []
    var title: String?
    var model: String?
    var cwd: String?
    var usage: TwinUsage?
    /// What each tool call is doing, by call id: the command, the diff, the
    /// checklist. The blocks carry a line of text; this carries the thing
    /// itself, so the twin can draw it the way the agent does.
    var details: [String: TwinToolDetail] = [:]
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
    /// What the most recent turn sent — the context in play right now,
    /// rather than the running total.
    var currentContextTokens = 0

    var total: Int { inputTokens + outputTokens }

    /// How full the window is, when Herd can tell honestly.
    var contextFraction: Double? {
        guard let contextWindow, contextWindow > 0, currentContextTokens > 0 else { return nil }
        return min(1, Double(currentContextTokens) / Double(contextWindow))
    }

    /// `38%` when the window is known, else `52k used`.
    var label: String {
        if let fraction = contextFraction { return "\(Int((fraction * 100).rounded()))%" }
        guard currentContextTokens > 0 else { return "" }
        return TwinUsage.compact(currentContextTokens)
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<1_000_000: "\(tokens / 1_000)k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }

    /// Windows Herd can infer from a model name when the agent doesn't say.
    static func window(forModel model: String?) -> Int? {
        guard let model = model?.lowercased() else { return nil }
        if model.contains("1m") { return 1_000_000 }
        if model.contains("claude") || model.contains("opus") || model.contains("sonnet") { return 200_000 }
        return nil
    }
}

enum TwinTranscript {
    /// Parses whichever format the agent writes. Claude and Codex are the two
    /// Herd knows by name; anything else goes through the loose reader, which
    /// understands the shapes agents actually write rather than one vendor's.
    static func parse(agent: String?, lines: [String]) -> TwinConversation {
        switch AgentBrand.forAgent(agent)?.id {
        case "claude": parseClaude(lines: lines)
        case "codex": parseCodex(lines: lines)
        default: parseGeneric(lines: lines)
        }
    }

    /// Folds a newly-read batch into the conversation so far. Tailing a file
    /// means parsing only what arrived, so this is how the twin stays live
    /// without re-reading a session that may be tens of megabytes.
    static func merge(_ base: TwinConversation, with next: TwinConversation) -> TwinConversation {
        var merged = base
        var seen = Set(base.messages.map(\.id))
        for message in next.messages where seen.insert(message.id).inserted {
            merged.messages.append(message)
        }
        merged.details.merge(next.details) { _, new in new }
        merged.title = next.title ?? merged.title
        merged.model = next.model ?? merged.model
        merged.cwd = next.cwd ?? merged.cwd
        merged.consumedLines += next.consumedLines
        if let usage = next.usage {
            var current = merged.usage ?? TwinUsage()
            // Totals accumulate; the window and the context in play are
            // whatever the newest turn reported.
            current.inputTokens += usage.inputTokens
            current.outputTokens += usage.outputTokens
            current.cacheReadTokens += usage.cacheReadTokens
            current.contextWindow = usage.contextWindow ?? current.contextWindow
            if usage.currentContextTokens > 0 { current.currentContextTokens = usage.currentContextTokens }
            merged.usage = current
        }
        return merged
    }

    // MARK: - Any agent

    /// Agents that aren't Claude or Codex still write a turn per line, and in
    /// practice the line is one of a few shapes: a chat message, a message
    /// nested under `message`, or an event wrapping one. This reads all of
    /// them, and produces nothing rather than nonsense when it can't.
    static func parseGeneric(lines: [String]) -> TwinConversation {
        // The two known formats are common enough to be worth trying first:
        // an agent may well write one of them.
        let claude = parseClaude(lines: lines)
        if !claude.messages.isEmpty { return claude }
        let codex = parseCodex(lines: lines)
        if !codex.messages.isEmpty { return codex }

        var conversation = TwinConversation()
        for line in lines {
            conversation.consumedLines += 1
            guard let object = json(line) else { continue }
            let body = (object["message"] as? [String: Any]) ?? (object["payload"] as? [String: Any]) ?? object
            if let cwd = (body["cwd"] ?? object["cwd"]) as? String { conversation.cwd = cwd }
            if let model = (body["model"] ?? object["model"]) as? String { conversation.model = model }
            guard let role = role(of: body) ?? role(of: object) else { continue }
            var blocks = claudeBlocks(body["content"], details: &conversation.details)
            if blocks.isEmpty, let text = (body["text"] ?? body["content"]) as? String, !text.isEmpty {
                blocks = [.text(text)]
            }
            // OpenAI-shaped tool calls travel beside the content.
            if let calls = body["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let function = call["function"] as? [String: Any]
                    let name = (function?["name"] ?? call["name"]) as? String ?? "tool"
                    let id = call["id"] as? String ?? UUID().uuidString
                    let input = function?["arguments"] ?? call["arguments"]
                    if let detail = TwinTools.detail(name: name, input: input) { conversation.details[id] = detail }
                    blocks.append(.toolCall(id: id, name: name, summary: toolSummary(name: name, input: input)))
                }
            }
            guard !blocks.isEmpty else { continue }
            conversation.messages.append(TwinMessage(
                id: (object["uuid"] ?? object["id"] ?? body["id"]) as? String ?? UUID().uuidString,
                role: role,
                blocks: blocks,
                at: date(object["timestamp"] ?? object["created_at"] ?? body["timestamp"])
            ))
        }
        return conversation
    }

    /// Who spoke, from whichever field the agent uses to say so.
    private static func role(of object: [String: Any]) -> TwinMessage.Role? {
        for key in ["role", "type", "kind", "speaker"] {
            guard let raw = (object[key] as? String)?.lowercased() else { continue }
            if raw.contains("user") || raw.contains("human") || raw.contains("prompt") { return .user }
            if raw.contains("assistant") || raw.contains("agent") || raw.contains("model") { return .assistant }
            if raw.contains("system") { return .system }
        }
        return nil
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
                if conversation.usage?.contextWindow == nil, let model = message["model"] as? String {
                    var current = conversation.usage ?? TwinUsage()
                    current.contextWindow = TwinUsage.window(forModel: model)
                    conversation.usage = current
                }
                let blocks = claudeBlocks(message["content"], details: &conversation.details)
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

    private static func claudeBlocks(
        _ content: Any?,
        details: inout [String: TwinToolDetail]
    ) -> [TwinMessage.Block] {
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
                let id = block["id"] as? String ?? UUID().uuidString
                if let detail = TwinTools.detail(name: name, input: block["input"]) {
                    details[id] = detail
                }
                return .toolCall(
                    id: id,
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
        // The newest turn's input is the context actually in play.
        let input = raw["input_tokens"] as? Int ?? 0
        let cached = raw["cache_read_input_tokens"] as? Int ?? 0
        let creation = raw["cache_creation_input_tokens"] as? Int ?? 0
        usage.currentContextTokens = input + cached + creation
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
                conversation.model = payload["model"] as? String ?? conversation.model
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
                // Codex records the running totals for the whole thread.
                if let thread = payload["thread_token_usage"] as? [String: Any] {
                    var current = conversation.usage ?? TwinUsage()
                    let input = thread["input_tokens"] as? Int ?? 0
                    let cached = thread["cached_input_tokens"] as? Int ?? 0
                    current.currentContextTokens = max(current.currentContextTokens, input + cached)
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
                    let arguments = payload["arguments"] ?? payload["action"] ?? payload["input"]
                    if let detail = TwinTools.detail(name: name, input: arguments) {
                        conversation.details[callId] = detail
                    }
                    conversation.messages.append(TwinMessage(
                        id: id,
                        role: .assistant,
                        blocks: [.toolCall(id: callId, name: name,
                                           summary: toolSummary(name: name, input: arguments))],
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

    /// What came back, kept as the lines it came back as — an agent's own UI
    /// shows the head of a command's output, not a one-line paraphrase — and
    /// bounded so a runaway result can't become the conversation.
    static func resultSummary(_ content: Any?, lines limit: Int = 40, characters: Int = 4_000) -> String {
        var text = ""
        if let string = content as? String { text = string }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String ?? $0["content"] as? String }.joined(separator: "\n")
        } else if let object = content as? [String: Any] {
            text = object["output"] as? String ?? object["content"] as? String ?? ""
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = text.components(separatedBy: "\n").prefix(limit).joined(separator: "\n")
        if kept.count > characters { kept = String(kept.prefix(characters - 1)) + "…" }
        return kept
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
