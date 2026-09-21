import Foundation

/// OpenCode runs as a local HTTP server (`opencode serve`) and reports a
/// session's progress as server-sent events. They carry what Claude's stream
/// and Codex's notifications carry, in OpenCode's shape (messages made of
/// parts, each part updated whole or by text deltas), so they build the same
/// `AgentConversation` and the same view draws all three.
///
/// Tools take the names and input keys Claude's tools use, because that is
/// what the tool cards, icons and diffs key off: OpenCode's `edit` with
/// `filePath`/`oldString`/`newString` is Claude's Edit with `file_path`/
/// `old_string`/`new_string`.
///
/// A subagent (the `task` tool) runs as a child session; its parts arrive
/// under that session's id, and are nested under the task call that made it.
struct OpenCodeStream: Equatable {
    /// The conversation's own session.
    var sessionId: String?
    /// Child sessions (subagents), to the task call each belongs to.
    private(set) var children: [String: String] = [:]
    /// Message id to role, since a part doesn't say whose message it's in.
    private var roles: [String: String] = [:]
    /// Part id to type, for deltas, which name only the part.
    private var partTypes: [String: String] = [:]
    /// Transcript item id to the message it came from, for removals.
    private var itemMessages: [String: String] = [:]
    /// Each assistant message's cost; the total is their sum.
    private var costs: [String: Double] = [:]
    /// Retry attempts already announced, so each is said once.
    private var announcedRetry: Int?

    init(sessionId: String? = nil) { self.sessionId = sessionId }

    /// Whether an event about `session` belongs to this conversation.
    func owns(_ session: String?) -> Bool {
        guard let session else { return false }
        return session == sessionId || children[session] != nil
    }

    /// A child session the server just announced, if it's one of ours: made
    /// by the task call running now.
    mutating func adopt(childSession id: String, parent: String?, in conversation: AgentConversation) {
        guard let parent, owns(parent), children[id] == nil else { return }
        let runningTask = conversation.items.last { item in
            guard case .tool(let call) = item.kind else { return false }
            return call.name == "Task" && call.result == nil
        }
        children[id] = runningTask?.id ?? ""
    }

    /// Applies one event (the decoded `data:` of an SSE message).
    mutating func apply(_ event: [String: Any], to conversation: inout AgentConversation) {
        guard let type = event["type"] as? String else { return }
        let properties = event["properties"] as? [String: Any] ?? [:]
        let session = properties["sessionID"] as? String
        switch type {
        case "session.created", "session.updated":
            if let info = properties["info"] as? [String: Any], let id = info["id"] as? String {
                adopt(childSession: id, parent: info["parentID"] as? String, in: conversation)
            }
        case "message.updated":
            guard owns(session), let info = properties["info"] as? [String: Any] else { return }
            applyMessage(info, session: session, to: &conversation)
        case "message.part.updated":
            guard owns(session), let part = properties["part"] as? [String: Any] else { return }
            applyPart(part, session: session, to: &conversation)
        case "message.part.delta":
            guard owns(session), let id = properties["partID"] as? String,
                  let delta = properties["delta"] as? String else { return }
            applyDelta(partId: id, field: properties["field"] as? String, delta: delta,
                       messageId: properties["messageID"] as? String, session: session, to: &conversation)
        case "message.part.removed":
            guard owns(session), let id = properties["partID"] as? String else { return }
            conversation.items.removeAll { $0.id == id }
        case "message.removed":
            guard owns(session), let id = properties["messageID"] as? String else { return }
            conversation.items.removeAll { itemMessages[$0.id] == id }
        case "session.status":
            guard session == sessionId, let status = properties["status"] as? [String: Any] else { return }
            applyStatus(status, to: &conversation)
        case "session.idle":
            guard session == sessionId else { return }
            conversation.isRunning = false
            announcedRetry = nil
        case "session.error":
            // Only this conversation's own session ends the turn; a subagent's
            // error comes back to it as the task call's result.
            guard session == nil || session == sessionId else { return }
            applyError(properties["error"] as? [String: Any], to: &conversation)
        case "session.compacted":
            guard session == sessionId else { return }
            conversation.items.append(AgentItem(id: UUID().uuidString, kind: .notice("The conversation was compacted to fit the model's context.")))
        default:
            break
        }
    }

    /// A conversation rebuilt from `GET /session/{id}/message`: each message
    /// with its parts, oldest first. What you wrote comes back too, since no
    /// send put it there this time.
    static func replay(_ messages: [[String: Any]], sessionId: String) -> (OpenCodeStream, AgentConversation) {
        var stream = OpenCodeStream(sessionId: sessionId)
        var conversation = AgentConversation()
        for message in messages {
            guard let info = message["info"] as? [String: Any] else { continue }
            let parts = message["parts"] as? [[String: Any]] ?? []
            if info["role"] as? String == "user" {
                let text = parts.filter { $0["type"] as? String == "text" && $0["synthetic"] as? Bool != true }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                let images = parts.filter { ($0["mime"] as? String)?.hasPrefix("image/") == true }
                    .compactMap { ($0["url"] as? String).flatMap(Self.dataURL) }
                if !text.isEmpty || !images.isEmpty {
                    conversation.items.append(AgentItem(id: info["id"] as? String ?? UUID().uuidString, kind: .user(text), images: images))
                }
                stream.roles[info["id"] as? String ?? ""] = "user"
                continue
            }
            stream.apply(["type": "message.updated", "properties": ["sessionID": sessionId, "info": info]], to: &conversation)
            for part in parts {
                stream.apply(["type": "message.part.updated", "properties": ["sessionID": sessionId, "part": part]], to: &conversation)
            }
            if let error = info["error"] as? [String: Any], error["name"] as? String != "MessageAbortedError" {
                conversation.items.append(AgentItem(id: UUID().uuidString, kind: .notice(describe(error))))
            }
        }
        conversation.isRunning = false
        return (stream, conversation)
    }

    /// The bytes of a `data:` URL, as OpenCode keeps attached images.
    static func dataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    // MARK: - Messages

    private mutating func applyMessage(_ info: [String: Any], session: String?, to conversation: inout AgentConversation) {
        guard let id = info["id"] as? String else { return }
        let role = info["role"] as? String ?? "assistant"
        roles[id] = role
        guard role == "assistant", session == sessionId else { return }
        if let model = info["modelID"] as? String, let provider = info["providerID"] as? String {
            conversation.model = "\(provider)/\(model)"
        }
        if let cost = info["cost"] as? Double {
            costs[id] = cost
            let total = costs.values.reduce(0, +)
            conversation.costUSD = total > 0 ? total : conversation.costUSD
        }
        if let tokens = info["tokens"] as? [String: Any] { noteContext(tokens, in: &conversation) }
        if let cwd = (info["path"] as? [String: Any])?["cwd"] as? String { conversation.cwd = cwd }
        // A message's error is the session's error too, and arrives as one;
        // it's reported there, once.
    }

    private func noteContext(_ tokens: [String: Any], in conversation: inout AgentConversation) {
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let read = [tokens["input"], cache["read"], cache["write"]].compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
        if read > 0 { conversation.contextUsed = read }
    }

    // MARK: - Parts

    private mutating func applyPart(_ part: [String: Any], session: String?, to conversation: inout AgentConversation) {
        guard let id = part["id"] as? String, let type = part["type"] as? String else { return }
        partTypes[id] = type
        let messageId = part["messageID"] as? String ?? ""
        itemMessages[type == "tool" ? (part["callID"] as? String ?? id) : id] = messageId
        // What you sent is already in the transcript: Octet adds it on send.
        if roles[messageId] == "user" { return }
        let parent = session == sessionId ? nil : children[session ?? ""].flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "text":
            // Text OpenCode inserts for itself, not the model's words.
            guard part["synthetic"] as? Bool != true, part["ignored"] as? Bool != true else { return }
            upsert(id: id, kind: .text(part["text"] as? String ?? ""), parent: parent, in: &conversation)
        case "reasoning":
            let text = part["text"] as? String ?? ""
            guard !text.isEmpty || conversation.items.contains(where: { $0.id == id }) else { return }
            upsert(id: id, kind: .thinking(text), parent: parent, in: &conversation)
        case "tool":
            applyTool(part, parent: parent, to: &conversation)
        case "step-finish":
            if session == sessionId, let tokens = part["tokens"] as? [String: Any] { noteContext(tokens, in: &conversation) }
        case "retry":
            let message = ((part["error"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String
            let attempt = (part["attempt"] as? NSNumber)?.intValue ?? 1
            upsert(id: id, kind: .notice("Retrying (attempt \(attempt))" + (message.map { ": \($0)" } ?? "")),
                   parent: parent, in: &conversation)
        case "compaction":
            upsert(id: id, kind: .notice("Compacting the conversation to fit the model's context…"), parent: parent, in: &conversation)
        case "subtask":
            let agent = part["agent"] as? String ?? "subagent"
            let description = part["description"] as? String ?? ""
            upsert(id: id, kind: .notice("Handed to the \(agent) agent: \(description)"), parent: parent, in: &conversation)
        default:
            // step-start, snapshot, patch, file and agent parts are
            // bookkeeping the transcript doesn't draw.
            break
        }
    }

    private mutating func applyDelta(partId: String, field: String?, delta: String, messageId: String?,
                                     session: String?, to conversation: inout AgentConversation) {
        guard field == nil || field == "text" else { return }
        if let messageId, roles[messageId] == "user" { return }
        if let position = conversation.items.firstIndex(where: { $0.id == partId }) {
            switch conversation.items[position].kind {
            case .text(let text): conversation.items[position].kind = .text(text + delta)
            case .thinking(let text): conversation.items[position].kind = .thinking(text + delta)
            default: break
            }
            return
        }
        // A delta ahead of its part: the part's type says what it is.
        let parent = session == sessionId ? nil : children[session ?? ""].flatMap { $0.isEmpty ? nil : $0 }
        switch partTypes[partId] {
        case "reasoning": conversation.items.append(AgentItem(id: partId, kind: .thinking(delta), parent: parent))
        case "text", nil: conversation.items.append(AgentItem(id: partId, kind: .text(delta), parent: parent))
        default: break
        }
    }

    private func upsert(id: String, kind: AgentItem.Kind, parent: String?, in conversation: inout AgentConversation) {
        if let position = conversation.items.firstIndex(where: { $0.id == id }) {
            conversation.items[position].kind = kind
        } else {
            conversation.items.append(AgentItem(id: id, kind: kind, parent: parent))
        }
    }

    private func applyTool(_ part: [String: Any], parent: String?, to conversation: inout AgentConversation) {
        let id = part["callID"] as? String ?? part["id"] as? String ?? UUID().uuidString
        let tool = part["tool"] as? String ?? "tool"
        let state = part["state"] as? [String: Any] ?? [:]
        let input = Self.claudeInput(tool: tool, input: state["input"] as? [String: Any] ?? [:])
        let name = Self.claudeToolName(tool)
        var call = AgentToolCall(name: name,
                                 summary: (state["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                    ?? AgentConversation.toolSummary(name: name, input: input),
                                 input: AgentConversation.prettyJSON(input) ?? "",
                                 inputData: try? JSONSerialization.data(withJSONObject: input))
        switch state["status"] as? String {
        case "completed":
            call.result = state["output"] as? String ?? ""
        case "error":
            call.result = state["error"] as? String ?? "Failed"
            call.isError = true
        default:
            break
        }
        if let position = conversation.items.firstIndex(where: { $0.id == id }) {
            conversation.items[position].kind = .tool(call)
        } else {
            conversation.items.append(AgentItem(id: id, kind: .tool(call), parent: parent))
        }
    }

    // MARK: - Status and errors

    private mutating func applyStatus(_ status: [String: Any], to conversation: inout AgentConversation) {
        switch status["type"] as? String {
        case "busy":
            conversation.isRunning = true
        case "idle":
            conversation.isRunning = false
            announcedRetry = nil
        case "retry":
            conversation.isRunning = true
            let attempt = (status["attempt"] as? NSNumber)?.intValue ?? 1
            guard announcedRetry != attempt else { return }
            announcedRetry = attempt
            let message = status["message"] as? String ?? "The provider didn't answer"
            conversation.items.append(AgentItem(id: UUID().uuidString, kind: .notice("\(message). Retrying (attempt \(attempt))…")))
        default:
            break
        }
    }

    private func applyError(_ error: [String: Any]?, to conversation: inout AgentConversation) {
        conversation.isRunning = false
        guard let error else { return }
        let text = Self.describe(error)
        if error["name"] as? String != "MessageAbortedError" { conversation.lastError = text }
        conversation.items.append(AgentItem(id: UUID().uuidString, kind: .notice(text)))
    }

    /// An OpenCode error in words, with what to do about it where that's known.
    static func describe(_ error: [String: Any]) -> String {
        let data = error["data"] as? [String: Any] ?? [:]
        let message = data["message"] as? String
        switch error["name"] as? String {
        case "MessageAbortedError":
            return "Stopped"
        case "ProviderAuthError":
            let provider = data["providerID"] as? String ?? "the provider"
            return "OpenCode isn't signed in to \(provider). Run `opencode auth login` in a terminal, then try again."
                + (message.map { " (\($0))" } ?? "")
        case "MessageOutputLengthError":
            return "The reply hit the model's output limit and was cut off."
        case "ContextOverflowError":
            return "The conversation no longer fits the model's context. Compact it (/compact) or start a new one."
        case "ContentFilterError":
            return "The provider's content filter stopped the reply" + (message.map { ": \($0)" } ?? ".")
        case "StructuredOutputError":
            return message ?? "The model didn't return the structured answer asked for."
        case "APIError":
            let status = (data["statusCode"] as? NSNumber)?.intValue
            // A provider's message, ended as a sentence so advice can follow.
            let message = message.map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : $0 + "." }
            if status == 426 || (message ?? "").localizedCaseInsensitiveContains("or newer is required") {
                return (message ?? "This model needs a newer OpenCode.") + " Run `opencode upgrade` in a terminal to update."
            }
            if status == 401 || status == 403 {
                return (message ?? "The provider refused the request.") + " Check its key with `opencode auth login`."
            }
            if status == 429 { return (message ?? "Rate limited by the provider.") + " Try again shortly, or pick another model." }
            return message ?? "The provider returned an error\(status.map { " (\($0))" } ?? "")."
        default:
            return message ?? "OpenCode reported an error."
        }
    }

    // MARK: - Tools, in Claude's terms

    /// OpenCode's tool ids under the names Octet draws cards for.
    static func claudeToolName(_ tool: String) -> String {
        switch tool {
        case "bash": return "Bash"
        case "edit", "multiedit": return "Edit"
        case "write": return "Write"
        case "read": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "list", "ls": return "LS"
        case "patch", "apply_patch": return "ApplyPatch"
        case "webfetch": return "WebFetch"
        case "websearch", "codesearch": return "WebSearch"
        case "task": return "Task"
        case "todowrite": return "TodoWrite"
        case "todoread": return "TodoRead"
        case "question": return "AskUserQuestion"
        case "skill": return "Skill"
        case "lsp": return "LSP"
        default:
            // MCP tools arrive as `server_tool`; anything else is shown as named.
            return tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }

    /// OpenCode's camelCase inputs under Claude's snake_case keys, which the
    /// diff and summary code reads.
    static func claudeInput(tool: String, input: [String: Any]) -> [String: Any] {
        let renames = ["filePath": "file_path", "oldString": "old_string", "newString": "new_string",
                       "replaceAll": "replace_all", "subagent_type": "subagent_type"]
        var out: [String: Any] = [:]
        for (key, value) in input { out[renames[key] ?? key] = value }
        if tool == "task", out["description"] == nil, let prompt = out["prompt"] { out["description"] = prompt }
        return out
    }
}

/// A permission OpenCode is waiting on (`permission.asked`), in the shape of
/// Claude's permission tool request that Octet's card reads, and the reply
/// OpenCode wants back.
enum OpenCodePermission {
    /// Permission kinds to the tool the card should present them as.
    static func toolName(_ permission: String) -> String {
        switch permission {
        case "bash": return "Bash"
        case "edit", "write", "patch": return "Edit"
        case "read": return "Read"
        case "webfetch", "websearch": return "WebFetch"
        case "external_directory": return "ExternalDirectory"
        case "doom_loop": return "DoomLoop"
        case "task": return "Task"
        default: return claudeCase(permission)
        }
    }

    private static func claudeCase(_ name: String) -> String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// The request as Claude Code's permission tool would have sent it.
    static func prompt(_ request: [String: Any], toolInput: [String: Any]?) -> [String: Any] {
        let permission = request["permission"] as? String ?? "permission"
        let patterns = request["patterns"] as? [String] ?? []
        let metadata = request["metadata"] as? [String: Any] ?? [:]
        var input = toolInput.map { OpenCodeStream.claudeInput(tool: permission, input: $0) } ?? [:]
        switch permission {
        case "bash":
            if input["command"] == nil { input["command"] = metadata["command"] as? String ?? patterns.joined(separator: " ") }
        case "edit", "write", "patch":
            if input["file_path"] == nil { input["file_path"] = metadata["filepath"] as? String ?? metadata["filePath"] as? String ?? patterns.first }
            if let diff = metadata["diff"] as? String, input["diff"] == nil { input["diff"] = diff }
        case "external_directory":
            input["path"] = input["path"] ?? patterns.first
            input["description"] = "Work outside the conversation's folder: \(patterns.joined(separator: ", "))"
        case "doom_loop":
            input["description"] = "The agent is repeating the same call. Let it continue?"
        default:
            if input.isEmpty { input = metadata }
            if !patterns.isEmpty, input["pattern"] == nil { input["pattern"] = patterns.joined(separator: ", ") }
        }
        let callId = (request["tool"] as? [String: Any])?["callID"] as? String
        return ["tool_name": toolName(permission), "tool_use_id": callId ?? request["id"] as? String ?? UUID().uuidString,
                "input": input]
    }

    /// `once`, `always` (this pattern, for the rest of the session) or
    /// `reject`, as `POST /permission/{id}/reply` takes it.
    static func reply(allow: Bool, forSession: Bool) -> String {
        allow ? (forSession ? "always" : "once") : "reject"
    }
}

/// Questions an OpenCode agent asks with its `question` tool
/// (`question.asked`): each with options to pick, one or several, and
/// usually room for an answer of your own. Answered in order, each answer a
/// list of the chosen labels (or the typed text).
struct OpenCodeQuestion: Identifiable, Equatable {
    struct Item: Equatable {
        struct Option: Equatable {
            let label: String
            let description: String
        }

        let header: String
        let question: String
        let options: [Option]
        let multiple: Bool
        /// Whether a typed answer is accepted; OpenCode's default is yes.
        let custom: Bool
    }

    let id: String
    let sessionId: String
    let items: [Item]

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let session = json["sessionID"] as? String else { return nil }
        self.id = id
        sessionId = session
        items = (json["questions"] as? [[String: Any]] ?? []).map { question in
            Item(header: question["header"] as? String ?? "",
                 question: question["question"] as? String ?? "",
                 options: (question["options"] as? [[String: Any]] ?? []).map {
                     Item.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                 },
                 multiple: question["multiple"] as? Bool ?? false,
                 custom: question["custom"] as? Bool ?? true)
        }
        guard !items.isEmpty else { return nil }
    }
}

extension OpenCodePermission {
    /// Permission presets a conversation can run under, beside the person's
    /// own config: `ask` puts every edit, command and fetch to them first;
    /// `allow` runs everything not explicitly denied, like `opencode --auto`.
    static let presets = ["ask", "allow"]

    /// The session ruleset for a preset; nil (their config) sends none.
    static func ruleset(_ preset: String?) -> [[String: Any]] {
        switch preset {
        case "ask":
            return ["edit", "bash", "webfetch", "websearch", "external_directory", "task"].map {
                ["permission": $0, "pattern": "*", "action": "ask"]
            }
        case "allow":
            return [["permission": "*", "pattern": "*", "action": "allow"]]
        default:
            return []
        }
    }
}
