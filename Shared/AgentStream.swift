import Foundation

/// One model Pi reports as configured for the current account. Pi identifies
/// a choice by provider and model id; keeping those separate avoids guessing
/// when a model id itself contains a slash (as OpenRouter ids often do).
struct PiModel: Identifiable, Equatable {
    let modelId: String
    let name: String
    let provider: String
    let reasoning: Bool
    let input: [String]
    let contextWindow: Int
    let maxTokens: Int

    var id: String { "\(provider)/\(modelId)" }

    var detail: String {
        var parts: [String] = []
        if reasoning { parts.append("Reasoning") }
        if input.contains("image") { parts.append("Images") }
        if contextWindow > 0 { parts.append("\(Self.short(contextWindow)) context") }
        if maxTokens > 0 { parts.append("\(Self.short(maxTokens)) max output") }
        return parts.joined(separator: " · ")
    }

    init?(_ json: [String: Any]) {
        guard let modelId = json["id"] as? String, !modelId.isEmpty,
              let provider = json["provider"] as? String, !provider.isEmpty else { return nil }
        self.modelId = modelId
        name = json["name"] as? String ?? modelId
        self.provider = provider
        reasoning = json["reasoning"] as? Bool ?? false
        input = json["input"] as? [String] ?? []
        contextWindow = json["contextWindow"] as? Int ?? 0
        maxTokens = json["maxTokens"] as? Int ?? 0
    }

    static func selection(_ value: String) -> (provider: String, modelId: String)? {
        guard let slash = value.firstIndex(of: "/"), slash != value.startIndex else { return nil }
        let modelStart = value.index(after: slash)
        guard modelStart < value.endIndex else { return nil }
        return (String(value[..<slash]), String(value[modelStart...]))
    }

    private static func short(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        return value >= 1_000 ? "\(value / 1_000)K" : "\(value)"
    }
}

/// A live conversation with an agent Octet drives headless, built from the
/// agent's stream-json events (`claude -p --output-format stream-json
/// --include-partial-messages`). Pure data: the driver feeds events in, the
/// native view draws `items`.
struct AgentConversation: Equatable {
    var sessionId: String?
    var model: String?
    var permissionMode: String?
    var cwd: String?
    var slashCommands: [String] = []
    var items: [AgentItem] = []
    /// A turn is in flight: from sending a message until its `result`.
    var isRunning = false
    /// Cumulative, at list price, as the agent reports it.
    var costUSD: Double?
    /// Tokens the model saw on its latest call, and its window size.
    var contextUsed: Int?
    var contextWindow: Int?
    var lastError: String?
    /// Plan allowance, when the account is a subscription.
    var usageWindows: [UsageWindow] = []

    /// The uuid of every user message Octet wrote to Claude Code, lowercased.
    /// Claude Code echoes each message it starts on (`--replay-user-messages`);
    /// these are Octet's own, already drawn, and any other is from elsewhere.
    var sentUserIds: Set<String> = []
    /// A plan the agent sent as an event rather than a tool call (Codex's
    /// `turn/plan/updated`), for the todo panel.
    var plan: [AgentTodo]?

    /// Messages that arrived as deltas; their final `assistant` copies only
    /// add tool calls, so text isn't drawn twice.
    private var streamedMessages: Set<String> = []
    /// Content block index to item id, for the message streaming now.
    private var openBlocks: [Int: String] = [:]
    private var currentMessageId: String?
    private var currentParent: String?

    mutating func appendUser(_ text: String, images: [Data] = [], queued: Bool = false) {
        items.append(AgentItem(id: UUID().uuidString, kind: .user(text), images: images, queued: queued))
        isRunning = true
        lastError = nil
    }

    /// Promotes the oldest follow-up from queued to active when the turn in
    /// front of it settles. Returns whether another turn is ready to run.
    @discardableResult
    mutating func activateNextQueuedMessage() -> Bool {
        guard let index = items.firstIndex(where: { $0.queued }) else { return false }
        items[index].queued = false
        return true
    }

    /// Applies one Claude Code or Qwen Code stream-json line (already decoded).
    mutating func apply(_ event: [String: Any]) {
        let parent = event["parent_tool_use_id"] as? String
        switch event["type"] as? String {
        case "system":
            applySystem(event)
        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            applyStreamEvent(inner, parent: parent)
        case "assistant":
            guard let message = event["message"] as? [String: Any] else { return }
            applyAssistant(message, parent: parent)
        case "user":
            guard let message = event["message"] as? [String: Any] else { return }
            if event["isReplay"] as? Bool == true {
                applyReplayedUser(event, message: message)
            } else {
                applyToolResults(message)
            }
        case "result":
            applyResult(event)
        case "rate_limit_event":
            if let info = event["rate_limit_info"] as? [String: Any] {
                let windows = AgentAccounts.claudeWindows(rateLimitInfo: info)
                if !windows.isEmpty { usageWindows = windows }
            }
        default:
            break
        }
    }

    // MARK: - Event kinds

    private mutating func applySystem(_ event: [String: Any]) {
        guard ["init", "session_start"].contains(event["subtype"] as? String ?? "") else { return }
        sessionId = event["session_id"] as? String ?? sessionId
        model = event["model"] as? String ?? model
        permissionMode = event["permissionMode"] as? String ?? permissionMode
        cwd = event["cwd"] as? String ?? cwd
        if let commands = event["slash_commands"] as? [String] { slashCommands = commands }
    }

    /// Applies one event from Pi's RPC mode. Pi uses a different envelope,
    /// but its content blocks and tool lifecycle fit the native transcript.
    mutating func applyPi(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "agent_start":
            isRunning = true
            lastError = nil
        case "agent_settled":
            isRunning = false
            openBlocks = [:]
        case "message_start":
            let message = event["message"] as? [String: Any]
            currentMessageId = message?["id"] as? String ?? UUID().uuidString
            openBlocks = [:]
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any] else { return }
            applyPiUpdate(update)
            if let usage = event["usage"] as? [String: Any] { notePiUsage(usage) }
        case "message_end":
            if let message = event["message"] as? [String: Any] {
                applyPiMessage(message)
                if message["stopReason"] as? String == "error",
                   let error = message["errorMessage"] as? String, !error.isEmpty {
                    lastError = error
                    items.append(AgentItem(id: UUID().uuidString, kind: .notice(error)))
                }
            }
            openBlocks = [:]
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            applyPiTool(event)
        case "response":
            guard event["success"] as? Bool == false else { return }
            let message = event["error"] as? String ?? "Pi rejected the request."
            lastError = message
            isRunning = false
            items.append(AgentItem(id: UUID().uuidString, kind: .notice(message)))
        default:
            break
        }
    }

    /// Rebuilds a persisted Pi conversation from `get_messages`. The live
    /// stream and restored history then share the same transcript rows.
    mutating func restorePi(_ messages: [[String: Any]]) {
        items = []
        openBlocks = [:]
        currentMessageId = nil
        for message in messages {
            switch message["role"] as? String {
            case "user":
                let text = Self.piText(message["content"])
                let attachments = message["attachments"] as? [[String: Any]] ?? []
                let images = attachments.compactMap { attachment -> Data? in
                    guard attachment["type"] as? String == "image",
                          let encoded = attachment["content"] as? String else { return nil }
                    return Data(base64Encoded: encoded)
                }
                items.append(AgentItem(id: UUID().uuidString, kind: .user(text), images: images))
            case "assistant":
                applyPiMessage(message)
                if let usage = message["usage"] as? [String: Any] { notePiUsage(usage) }
            case "toolResult":
                guard let id = message["toolCallId"] as? String else { continue }
                upsertTool(id: id, name: Self.piToolName(message["toolName"] as? String ?? "tool"), input: nil, parent: nil)
                guard let position = items.firstIndex(where: { $0.id == id }), case .tool(var call) = items[position].kind else { continue }
                call.result = Self.resultText(message["content"])
                call.isError = message["isError"] as? Bool ?? false
                items[position].kind = .tool(call)
            case "bashExecution":
                let command = message["command"] as? String ?? "bash"
                let output = message["output"] as? String ?? ""
                let call = AgentToolCall(name: "Bash", summary: command, input: command, inputData: nil, result: output,
                                         isError: (message["exitCode"] as? Int ?? 0) != 0)
                items.append(AgentItem(id: UUID().uuidString, kind: .tool(call)))
            default:
                continue
            }
        }
        isRunning = false
        lastError = nil
    }

    private mutating func applyPiUpdate(_ update: [String: Any]) {
        let index = update["contentIndex"] as? Int ?? 0
        let messageId = currentMessageId ?? "pi-message"
        switch update["type"] as? String {
        case "text_start", "thinking_start":
            let id = "\(messageId):\(index)"
            let kind: AgentItem.Kind = update["type"] as? String == "thinking_start" ? .thinking("") : .text("")
            if !items.contains(where: { $0.id == id }) { items.append(AgentItem(id: id, kind: kind)) }
            openBlocks[index] = id
        case "text_delta", "thinking_delta":
            let id = openBlocks[index] ?? "\(messageId):\(index)"
            if !items.contains(where: { $0.id == id }) {
                let kind: AgentItem.Kind = update["type"] as? String == "thinking_delta" ? .thinking("") : .text("")
                items.append(AgentItem(id: id, kind: kind))
                openBlocks[index] = id
            }
            guard let position = items.firstIndex(where: { $0.id == id }) else { return }
            let delta = update["delta"] as? String ?? ""
            switch items[position].kind {
            case .text(let text): items[position].kind = .text(text + delta)
            case .thinking(let text): items[position].kind = .thinking(text + delta)
            default: break
            }
        case "toolcall_start":
            let id = update["id"] as? String ?? "\(messageId):\(index)"
            upsertTool(id: id, name: Self.piToolName(update["toolName"] as? String ?? "tool"), input: nil, parent: nil)
            openBlocks[index] = id
        case "toolcall_end":
            guard let call = update["toolCall"] as? [String: Any] else { return }
            let id = call["id"] as? String ?? openBlocks[index] ?? "\(messageId):\(index)"
            let input = call["arguments"] as? [String: Any] ?? call["args"] as? [String: Any]
            upsertTool(id: id,
                       name: Self.piToolName(call["name"] as? String ?? call["toolName"] as? String ?? "tool"),
                       input: input, parent: nil)
        default:
            break
        }
    }

    private mutating func applyPiMessage(_ message: [String: Any]) {
        guard message["role"] as? String == "assistant",
              let blocks = message["content"] as? [[String: Any]] else { return }
        let messageId = message["id"] as? String ?? currentMessageId ?? UUID().uuidString
        for (index, block) in blocks.enumerated() {
            let id = "\(messageId):\(index)"
            switch block["type"] as? String {
            case "text" where !items.contains(where: { $0.id == id }):
                items.append(AgentItem(id: id, kind: .text(block["text"] as? String ?? "")))
            case "thinking" where !items.contains(where: { $0.id == id }):
                items.append(AgentItem(id: id, kind: .thinking(block["thinking"] as? String ?? block["text"] as? String ?? "")))
            case "toolCall", "tool_call":
                let callId = block["id"] as? String ?? id
                let input = block["arguments"] as? [String: Any] ?? block["args"] as? [String: Any]
                upsertTool(id: callId,
                           name: Self.piToolName(block["name"] as? String ?? block["toolName"] as? String ?? "tool"),
                           input: input, parent: nil)
            default: break
            }
        }
    }

    private mutating func applyPiTool(_ event: [String: Any]) {
        guard let id = event["toolCallId"] as? String else { return }
        upsertTool(id: id, name: Self.piToolName(event["toolName"] as? String ?? "tool"),
                   input: event["args"] as? [String: Any], parent: nil)
        guard let position = items.firstIndex(where: { $0.id == id }), case .tool(var call) = items[position].kind else { return }
        let payload = event["result"] ?? event["partialResult"]
        if let result = payload as? [String: Any] { call.result = Self.resultText(result["content"]) }
        if event["type"] as? String == "tool_execution_end" { call.isError = event["isError"] as? Bool ?? false }
        items[position].kind = .tool(call)
    }

    private mutating func notePiUsage(_ usage: [String: Any]) {
        if let total = usage["totalTokens"] as? Int { contextUsed = total }
        if let cost = usage["cost"] as? [String: Any], let total = cost["total"] as? Double { costUSD = total }
    }

    private static func piToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "Bash"
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        case "grep", "search": return "Grep"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    private static func piText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private mutating func applyStreamEvent(_ event: [String: Any], parent: String?) {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            currentMessageId = message?["id"] as? String ?? UUID().uuidString
            currentParent = parent
            openBlocks = [:]
            if let id = currentMessageId { streamedMessages.insert(id) }
            if let usage = message?["usage"] as? [String: Any] { noteContext(usage) }
        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any] else { return }
            let messageId = currentMessageId ?? "message"
            switch block["type"] as? String {
            case "text":
                let id = "\(messageId):\(index)"
                items.append(AgentItem(id: id, kind: .text(block["text"] as? String ?? ""), parent: currentParent))
                openBlocks[index] = id
            case "thinking":
                let id = "\(messageId):\(index)"
                items.append(AgentItem(id: id, kind: .thinking(block["thinking"] as? String ?? ""), parent: currentParent))
                openBlocks[index] = id
            case "tool_use":
                let toolId = block["id"] as? String ?? "\(messageId):\(index)"
                upsertTool(id: toolId, name: block["name"] as? String ?? "Tool", input: nil, parent: currentParent)
                openBlocks[index] = toolId
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int, let id = openBlocks[index],
                  let delta = event["delta"] as? [String: Any],
                  let position = items.firstIndex(where: { $0.id == id }) else { return }
            switch (delta["type"] as? String, items[position].kind) {
            case ("text_delta", .text(let text)):
                items[position].kind = .text(text + (delta["text"] as? String ?? ""))
            case ("thinking_delta", .thinking(let text)):
                items[position].kind = .thinking(text + (delta["thinking"] as? String ?? ""))
            default:
                break
            }
        case "message_stop":
            openBlocks = [:]
        default:
            break
        }
    }

    private mutating func applyAssistant(_ message: [String: Any], parent: String?) {
        let messageId = message["id"] as? String ?? UUID().uuidString
        if let usage = message["usage"] as? [String: Any] { noteContext(usage) }
        let streamed = streamedMessages.contains(messageId)
        let blocks = message["content"] as? [[String: Any]] ?? []
        for (index, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "tool_use":
                upsertTool(id: block["id"] as? String ?? "\(messageId):t\(index)",
                           name: block["name"] as? String ?? "Tool",
                           input: block["input"] as? [String: Any], parent: parent)
            case "text" where !streamed:
                items.append(AgentItem(id: "\(messageId):a\(index)", kind: .text(block["text"] as? String ?? ""), parent: parent))
            case "thinking" where !streamed:
                items.append(AgentItem(id: "\(messageId):a\(index)", kind: .thinking(block["thinking"] as? String ?? ""), parent: parent))
            default:
                break
            }
        }
    }

    /// A user message Claude Code is starting on. Octet's own come back
    /// under the uuid it sent them with; one Octet didn't send was typed
    /// somewhere else, in claude.ai or the Claude app over Remote Control,
    /// and is drawn here as it would have been had it been typed here.
    private mutating func applyReplayedUser(_ event: [String: Any], message: [String: Any]) {
        let uuid = (event["uuid"] as? String)?.lowercased()
        if let uuid, sentUserIds.contains(uuid) || items.contains(where: { $0.id.lowercased() == uuid }) { return }
        guard event["isSynthetic"] as? Bool != true, let text = Self.userText(message["content"]) else { return }
        let images = Self.images(in: message["content"])
        items.append(AgentItem(id: uuid ?? UUID().uuidString,
                               kind: .user(images.isEmpty ? text : Self.strippingImageMarkers(text)),
                               images: images, remote: true))
        isRunning = true
        lastError = nil
    }

    private mutating func applyToolResults(_ message: [String: Any]) {
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let toolId = block["tool_use_id"] as? String,
                  let position = items.firstIndex(where: { $0.id == toolId }),
                  case .tool(var call) = items[position].kind else { continue }
            call.result = Self.resultText(block["content"])
            call.resultImages = Self.images(in: block["content"])
            call.isError = block["is_error"] as? Bool ?? false
            items[position].kind = .tool(call)
        }
    }

    private mutating func applyResult(_ event: [String: Any]) {
        isRunning = activateNextQueuedMessage()
        openBlocks = [:]
        costUSD = event["total_cost_usd"] as? Double ?? costUSD
        if let usage = event["modelUsage"] as? [String: [String: Any]],
           let window = usage.values.compactMap({ $0["contextWindow"] as? Int }).max() {
            contextWindow = window
        }
        let subtype = event["subtype"] as? String ?? "success"
        switch subtype {
        case "success":
            break
        case "error_during_execution":
            items.append(AgentItem(id: UUID().uuidString, kind: .notice("Stopped")))
        default:
            let errors = (event["errors"] as? [String])?.joined(separator: "\n")
            lastError = errors ?? subtype.replacingOccurrences(of: "_", with: " ")
            items.append(AgentItem(id: UUID().uuidString, kind: .notice(lastError ?? "Error")))
        }
    }

    // MARK: - Helpers

    private mutating func upsertTool(id: String, name: String, input: [String: Any]?, parent: String?) {
        let summary = input.map { Self.toolSummary(name: name, input: $0) } ?? ""
        let detail = input.flatMap(Self.prettyJSON) ?? ""
        if let position = items.firstIndex(where: { $0.id == id }), case .tool(var call) = items[position].kind {
            if let input {
                call.summary = summary
                call.input = detail
                call.inputData = try? JSONSerialization.data(withJSONObject: input)
            }
            items[position].kind = .tool(call)
        } else {
            let data = input.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            items.append(AgentItem(id: id, kind: .tool(AgentToolCall(name: name, summary: summary, input: detail, inputData: data)), parent: parent))
        }
    }

    /// Context in use: everything the model read on its latest call.
    private mutating func noteContext(_ usage: [String: Any]) {
        let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { usage[$0] as? Int }.reduce(0, +)
        if total > 0 { contextUsed = total }
    }

    /// One line saying what a tool call does.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        // A skill's name is the row's title; what it was asked is the line.
        if SkillCall.isSkill(name) {
            let args = (input["args"] as? String ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return args.count > 160 ? String(args.prefix(160)) + "…" : args
        }
        // A search's pattern says more than the folder it searched.
        for key in ["command", "file_path", "pattern", "query", "url", "path", "description", "jql", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                let line = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
                return line.count > 160 ? String(line.prefix(160)) + "…" : line
            }
        }
        return ""
    }

    /// Base64 image blocks in message or tool-result content, decoded.
    static func images(in content: Any?) -> [Data] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "image",
                  let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
                  let encoded = source["data"] as? String else { return nil }
            return Data(base64Encoded: encoded)
        }
    }

    /// Claude Code writes "[Image #1]" where an image was pasted; with the
    /// image itself drawn, the marker is noise.
    static func strippingImageMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func prettyJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func == (lhs: AgentConversation, rhs: AgentConversation) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.model == rhs.model && lhs.permissionMode == rhs.permissionMode
            && lhs.items == rhs.items && lhs.isRunning == rhs.isRunning && lhs.costUSD == rhs.costUSD
            && lhs.contextUsed == rhs.contextUsed && lhs.contextWindow == rhs.contextWindow && lhs.lastError == rhs.lastError
    }
}

/// Pi's RPC extension UI dialogs translated into the common question surface.
enum PiExtensionUI {
    static func question(_ event: [String: Any], sessionId: String) -> OpenCodeQuestion? {
        guard event["type"] as? String == "extension_ui_request",
              let id = event["id"] as? String,
              let method = event["method"] as? String,
              ["select", "confirm", "input", "editor"].contains(method) else { return nil }
        let title = event["title"] as? String ?? "Pi needs an answer"
        let message = event["message"] as? String
        let prompt = message?.isEmpty == false ? message! : title
        let header = message?.isEmpty == false ? title : ""
        let labels: [String]
        switch method {
        case "select": labels = event["options"] as? [String] ?? []
        case "confirm": labels = ["Yes", "No"]
        default: labels = []
        }
        return OpenCodeQuestion([
            "id": id, "sessionID": sessionId,
            "questions": [[
                "header": header, "question": prompt,
                "options": labels.map { ["label": $0, "description": ""] },
                "multiple": false, "custom": method == "input" || method == "editor",
                "initial": event["prefill"] as? String ?? "",
            ]],
        ])
    }

    static func response(_ event: [String: Any], answers: [[String]]) -> [String: Any] {
        let id = event["id"] as? String ?? ""
        let answer = answers.first?.first ?? ""
        if event["method"] as? String == "confirm" {
            return ["type": "extension_ui_response", "id": id,
                    "confirmed": answer.caseInsensitiveCompare("yes") == .orderedSame]
        }
        return ["type": "extension_ui_response", "id": id, "value": answer]
    }

    static func cancel(_ event: [String: Any]) -> [String: Any] {
        ["type": "extension_ui_response", "id": event["id"] as? String ?? "", "cancelled": true]
    }
}

/// Claude Code sends AskUserQuestion through the same permission callback as
/// commands and edits. Translate it into Octet's common question surface, and
/// put the chosen answers back into the tool input Claude is waiting for.
enum ClaudeUserInput {
    static func question(_ prompt: [String: Any], sessionId: String) -> OpenCodeQuestion? {
        guard prompt["tool_name"] as? String == "AskUserQuestion",
              let input = prompt["input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        return OpenCodeQuestion([
            "id": prompt["tool_use_id"] as? String ?? UUID().uuidString,
            "sessionID": sessionId,
            "questions": questions.map { item in
                [
                    "header": item["header"] as? String ?? "",
                    "question": item["question"] as? String ?? "",
                    "options": item["options"] as? [[String: Any]] ?? [],
                    "multiple": item["multiSelect"] as? Bool ?? false,
                    "custom": true,
                ] as [String: Any]
            },
        ])
    }

    static func decision(_ prompt: [String: Any], question: OpenCodeQuestion,
                         answers: [[String]]) -> [String: Any] {
        var input = prompt["input"] as? [String: Any] ?? [:]
        var mapped: [String: String] = [:]
        for (item, answer) in zip(question.items, answers) {
            mapped[item.question] = answer.joined(separator: ", ")
        }
        input["answers"] = mapped
        return AgentPermissionRequest.decision(allow: true, input: input, message: nil)
    }
}

struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case text(String)
        case thinking(String)
        case tool(AgentToolCall)
        /// Something Octet says about the conversation (stopped, errors).
        case notice(String)
    }

    let id: String
    var kind: Kind
    /// Set on a subagent's items: the tool call that spawned it.
    var parent: String?
    /// Images the person attached to a message, as sent.
    var images: [Data] = []
    /// A follow-up entered while the current turn is still running.
    var queued = false
    /// A message sent from claude.ai or the Claude app over Remote Control.
    var remote = false
    /// When the item began. Runtime uses this with a Monitor call's timeout
    /// to distinguish a live watch from historical tool output.
    var createdAt = Date()
}

struct AgentToolCall: Equatable {
    var name: String
    var summary: String
    /// Pretty-printed input, once the full call has arrived.
    var input: String
    /// The same input as JSON, for views that draw it (diffs for edits).
    var inputData: Data?
    var result: String?
    /// Images a tool returned, e.g. a screenshot Claude read.
    var resultImages: [Data] = []
    var isError = false
}

/// A permission prompt the agent's permission tool relays to Octet.
struct AgentPermissionRequest: Identifiable, Equatable {
    let id: String
    let toolName: String
    let summary: String
    let input: String
    /// The input exactly as sent, echoed back as `updatedInput` on allow.
    let rawInput: Data

    init?(json: [String: Any]) {
        guard let tool = json["tool_name"] as? String else { return nil }
        let input = json["input"] as? [String: Any] ?? [:]
        id = json["tool_use_id"] as? String ?? UUID().uuidString
        toolName = tool
        summary = AgentConversation.toolSummary(name: tool, input: input)
        self.input = AgentConversation.prettyJSON(input) ?? ""
        rawInput = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
    }

    var inputObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: rawInput)) as? [String: Any] ?? [:]
    }

    /// The permission tool's answer, in the shape the agent expects.
    static func decision(allow: Bool, input: [String: Any], message: String?) -> [String: Any] {
        allow ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": message?.isEmpty == false ? message! : "The user declined this in Octet."]
    }
}

extension AgentToolCall {
    var inputObject: [String: Any]? {
        inputData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    var filePath: String? { inputObject?["file_path"] as? String }

    /// Where the change sits in its file now (the call has run), read off
    /// the main thread.
    func fileStartLine() async -> Int? {
        guard let input = inputObject else { return nil }
        let tool = name
        return await Task.detached(priority: .utility) {
            AgentToolCall.startLine(tool: tool, input: input, applied: true)
        }.value
    }

    /// The file line a diff's first shown line corresponds to. `applied`
    /// says whether to look for the new text (after the edit) or the old.
    static func startLine(tool: String, input: [String: Any], applied: Bool) -> Int? {
        guard tool == "Edit", let path = input["file_path"] as? String,
              let old = input["old_string"] as? String, let new = input["new_string"] as? String,
              let file = try? String(contentsOfFile: path, encoding: .utf8),
              let start = LineDiff.startLine(of: applied ? new : old, in: file) else { return tool == "Write" ? 1 : nil }
        // The diff's first line is its leading context, not the snippet's first line.
        let lines = LineDiff.lines(old: old, new: new)
        let firstShown = lines.first.flatMap { applied ? $0.newNumber : $0.oldNumber } ?? 1
        return start + firstShown - 1
    }

    /// The change an Edit, MultiEdit or Write call makes, as diff lines.
    var diff: [LineDiff.Line]? {
        guard let inputData, let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else { return nil }
        return AgentToolCall.diff(tool: name, input: input)
    }

    static func diff(tool: String, input: [String: Any]) -> [LineDiff.Line]? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return LineDiff.lines(old: old, new: new)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            return edits.flatMap { edit in
                LineDiff.lines(old: edit["old_string"] as? String ?? "", new: edit["new_string"] as? String ?? "")
            }
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            return LineDiff.added(content)
        default:
            return nil
        }
    }
}

extension AgentConversation {
    /// Rebuilds a conversation from the agent's own session log (Claude
    /// Code's `~/.claude/projects/<folder>/<session>.jsonl`), whose `user`
    /// and `assistant` records share the stream's shape. Bookkeeping lines,
    /// meta messages and slash-command echoes are skipped.
    static func replay(lines: [String]) -> AgentConversation {
        var conversation = AgentConversation()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true else { continue }
            let firstNewItem = conversation.items.count
            switch record["type"] as? String {
            case "assistant":
                conversation.apply(record)
            case "user":
                guard let message = record["message"] as? [String: Any] else { continue }
                if let text = Self.userText(message["content"]) {
                    let images = Self.images(in: message["content"])
                    let shown = images.isEmpty ? text : Self.strippingImageMarkers(text)
                    conversation.items.append(AgentItem(id: record["uuid"] as? String ?? UUID().uuidString,
                                                        kind: .user(shown), images: images))
                } else {
                    conversation.apply(record)
                }
            default:
                break
            }
            if let timestamp = record["timestamp"] as? String,
               let date = eventDate(timestamp) {
                for index in firstNewItem..<conversation.items.count {
                    conversation.items[index].createdAt = date
                }
            }
            if conversation.sessionId == nil { conversation.sessionId = record["sessionId"] as? String }
            if conversation.cwd == nil { conversation.cwd = record["cwd"] as? String }
        }
        conversation.isRunning = false
        return conversation
    }

    private static func eventDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// A person's message, or nil for tool results and command echoes.
    private static func userText(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<command-"), !trimmed.hasPrefix("<local-command") else { return nil }
        guard !trimmed.isEmpty || !images(in: content).isEmpty else { return nil }
        return trimmed
    }

    /// Where Claude Code keeps a session's log: its project folder name is
    /// the working directory with every non-alphanumeric character as "-".
    static func claudeLogPath(sessionId: String, cwd: String, home: String = NSHomeDirectory()) -> String {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return home + "/.claude/projects/" + folder + "/" + sessionId + ".jsonl"
    }
}

extension AgentToolCall {
    /// "Read", for MCP tools "server: tool" instead of mcp__server__tool,
    /// and for a skill the skill's own name.
    var displayName: String {
        if SkillCall.isSkill(name) {
            let input = inputData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return input.flatMap(SkillCall.name(in:)) ?? name
        }
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        return "\(parts[0]): \(parts[1...].joined(separator: "__"))"
    }

    var isMCP: Bool { name.hasPrefix("mcp__") }

    /// Which icon names the tool's kind.
    var iconName: String {
        if isMCP { return "tool.mcp" }
        switch name {
        case "Read": return "tool.read"
        case "Edit", "MultiEdit": return "tool.edit"
        case "Write": return "tool.write"
        case "Grep", "Glob", "LS", "ToolSearch": return "tool.search"
        case "WebSearch": return "tool.web"
        case "WebFetch": return "tool.fetch"
        case "Bash", "BashOutput", "KillShell", "KillBash": return "tool.run"
        case "Monitor": return "eye"
        case "Task", "Agent": return "tool.agent"
        case "Skill", "skill": return "sparkles"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "tool.todo"
        case "NotebookEdit", "NotebookRead": return "tool.notebook"
        default: return "tool.other"
        }
    }

    struct Todo: Equatable {
        enum State: String { case pending, inProgress = "in_progress", completed }
        let text: String
        let state: State
    }

    /// TodoWrite's list, drawn as a checklist.
    var todos: [Todo]? {
        guard name == "TodoWrite", let items = inputObject?["todos"] as? [[String: Any]] else { return nil }
        return items.map {
            let state = Todo.State(rawValue: $0["status"] as? String ?? "") ?? .pending
            let text = state == .inProgress ? ($0["activeForm"] as? String ?? $0["content"] as? String ?? "")
                : ($0["content"] as? String ?? "")
            return Todo(text: text, state: state)
        }
    }
}

/// A call to a skill: Claude's `Skill` tool (`{"skill": "frontend-design",
/// "args": …}`) and OpenCode's `skill` (`{"name": …}`). Without this a
/// skill shows only as "Skill".
enum SkillCall {
    static func isSkill(_ tool: String) -> Bool { tool.caseInsensitiveCompare("skill") == .orderedSame }

    /// The skill's name, without the `/` a slash command carries.
    static func name(in input: [String: Any]) -> String? {
        for key in ["skill", "name", "command"] {
            if let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value.hasPrefix("/") ? String(value.dropFirst()) : value
            }
        }
        return nil
    }
}
