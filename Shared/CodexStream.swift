import Foundation

/// Codex's app server speaks JSON-RPC: Octet starts a thread and a turn, and
/// the server sends notifications back as the turn runs. They carry the same
/// things Claude's stream does in a different shape, so they build the same
/// `AgentConversation` and the same view draws both.
///
/// Tool items are given the names Claude's tools use, because that is what
/// `AgentToolCall.iconName` and the cards key off; a Codex shell call and a
/// Claude Bash call are the same thing to a reader.
extension AgentConversation {
    /// Applies one JSON-RPC message from `codex app-server`.
    mutating func applyCodex(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any] else { return }
            sessionId = thread["id"] as? String ?? sessionId
            model = thread["model"] as? String ?? model
            cwd = thread["cwd"] as? String ?? cwd
        case "turn/started":
            isRunning = true
            lastError = nil
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            applyCodexItem(item)
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            appendCodexText(id: id, delta: delta)
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any] else { return }
            if let total = usage["total"] as? [String: Any], let used = total["totalTokens"] as? Int { contextUsed = used }
            if let window = params["contextWindow"] as? Int ?? usage["contextWindow"] as? Int { contextWindow = window }
        case "account/rateLimits/updated":
            guard let limits = params["rateLimits"] as? [String: Any] else { return }
            let windows = AgentAccounts.codexWindows(rateLimits: limits)
            if !windows.isEmpty { usageWindows = windows }
        case "guardianWarning":
            // Codex's own reviewer approving something the sandbox wouldn't
            // allow, e.g. a write under read-only. Said once, in its words,
            // because the person chose that sandbox and should see it bent.
            guard let text = params["message"] as? String, !text.isEmpty else { return }
            items.append(AgentItem(id: UUID().uuidString, kind: .notice(text)))
        case "turn/completed":
            isRunning = activateNextQueuedMessage()
        case "turn/failed", "turn/aborted":
            isRunning = activateNextQueuedMessage()
            let message = ((params["error"] as? [String: Any])?["message"] as? String)
                ?? (method == "turn/aborted" ? "Stopped" : "The turn failed.")
            if method != "turn/aborted" { lastError = message }
            items.append(AgentItem(id: UUID().uuidString, kind: .notice(message)))
        default:
            break
        }
    }

    private mutating func applyCodexItem(_ item: [String: Any]) {
        guard let id = item["id"] as? String else { return }
        switch item["type"] as? String {
        case "userMessage":
            // Already in the transcript: Octet appends it when you send.
            break
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            if let position = items.firstIndex(where: { $0.id == id }) {
                items[position].kind = .text(text)
            } else {
                items.append(AgentItem(id: id, kind: .text(text)))
            }
        case "reasoning":
            let text = item["text"] as? String
                ?? (item["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                ?? ""
            guard !text.isEmpty else { return }
            if let position = items.firstIndex(where: { $0.id == id }) {
                items[position].kind = .thinking(text)
            } else {
                items.append(AgentItem(id: id, kind: .thinking(text)))
            }
        default:
            applyCodexTool(id: id, item: item)
        }
    }

    /// Every other item is something the agent did: a command, an edit, a
    /// search, an MCP call.
    private mutating func applyCodexTool(id: String, item: [String: Any]) {
        let kind = item["type"] as? String ?? "tool"
        var call = AgentToolCall(name: Self.codexToolName(kind: kind, item: item),
                                 summary: Self.codexSummary(kind: kind, item: item),
                                 input: Self.prettyJSON(item) ?? "")
        call.inputData = try? JSONSerialization.data(withJSONObject: item)
        if let output = Self.codexOutput(kind: kind, item: item) { call.result = output }
        if let exit = item["exitCode"] as? Int { call.isError = exit != 0 }
        switch item["status"] as? String {
        case "failed":
            call.isError = true
        case "declined":
            // Refused at the approval prompt, so it never ran.
            call.isError = true
            call.result = call.result ?? "Declined"
        default:
            break
        }

        if let position = items.firstIndex(where: { $0.id == id }), case .tool(let existing) = items[position].kind {
            // A completed item repeats everything the started one had, plus
            // its result; keep what the newer copy knows.
            call.result = call.result ?? existing.result
            items[position].kind = .tool(call)
        } else {
            items.append(AgentItem(id: id, kind: .tool(call)))
        }
    }

    private mutating func appendCodexText(id: String, delta: String) {
        if let position = items.firstIndex(where: { $0.id == id }), case .text(let text) = items[position].kind {
            items[position].kind = .text(text + delta)
        } else {
            items.append(AgentItem(id: id, kind: .text(delta)))
        }
    }

    /// Codex's item kinds under the tool names Octet already draws icons for.
    static func codexToolName(kind: String, item: [String: Any]) -> String {
        switch kind {
        case "commandExecution": return "Bash"
        case "fileChange": return "Edit"
        case "webSearch": return "WebSearch"
        case "imageView": return "Read"
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "call"
            return "mcp__\(server)__\(tool)"
        default:
            // "enteredReviewMode" reads as "Entered review mode".
            let spaced = kind.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    static func codexSummary(kind: String, item: [String: Any]) -> String {
        switch kind {
        case "commandExecution":
            return (item["commandActions"] as? [[String: Any]])?.compactMap { $0["command"] as? String }.first
                ?? item["command"] as? String ?? ""
        case "fileChange":
            let files = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            return files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case "webSearch":
            return item["query"] as? String ?? ""
        default:
            return item["title"] as? String ?? item["name"] as? String ?? ""
        }
    }

    private static func codexOutput(kind: String, item: [String: Any]) -> String? {
        if let output = item["aggregatedOutput"] as? String, !output.isEmpty { return output }
        if let content = item["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return item["output"] as? String
    }
}

/// The questions Codex's app server asks and waits on, translated for Octet's
/// permission card and back.
///
/// Codex sends these as JSON-RPC requests of its own, with its own ids, under
/// an approval policy that asks (`untrusted`, or a sandbox it would break). A
/// request Octet doesn't answer leaves the turn waiting forever, so every one
/// gets an answer: the person's, or a plain refusal Octet explains.
enum CodexApproval {
    /// Requests the permission card can put to the person.
    static let approvals: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
    ]

    /// The request as Claude Code's permission tool would have sent it, which
    /// is what `AgentPermissionRequest` reads. Commands read as Bash and file
    /// changes as edits, so "Allow for Session" means the same thing for both
    /// agents: that exact command, or all edits.
    static func prompt(method: String, params: [String: Any]) -> [String: Any] {
        let id = params["itemId"] as? String ?? UUID().uuidString
        switch method {
        case "item/commandExecution/requestApproval":
            // The command as the agent wrote it, not the shell line wrapping it.
            let command = (params["commandActions"] as? [[String: Any]])?.compactMap { $0["command"] as? String }.first
                ?? params["command"] as? String ?? ""
            var input: [String: Any] = ["command": command]
            if let cwd = params["cwd"] as? String { input["cwd"] = cwd }
            if let reason = params["reason"] as? String { input["description"] = reason }
            return ["tool_name": "Bash", "tool_use_id": id, "input": input]
        case "item/fileChange/requestApproval":
            let changes = params["changes"] as? [[String: Any]] ?? []
            var input: [String: Any] = ["changes": changes]
            if let path = changes.compactMap({ $0["path"] as? String }).first ?? params["path"] as? String {
                input["file_path"] = path
            }
            if let reason = params["reason"] as? String { input["description"] = reason }
            return ["tool_name": "Edit", "tool_use_id": id, "input": input]
        default:
            var input = params
            input.removeValue(forKey: "threadId")
            input.removeValue(forKey: "turnId")
            return ["tool_name": "Permissions", "tool_use_id": id, "input": input]
        }
    }

    /// The answer to send, picked from what Codex offered: `accept` to allow;
    /// to refuse, `decline` where it's offered (just this action), else
    /// `cancel`. Falling back to those names when Codex lists nothing.
    static func decision(allow: Bool, offered: [Any]) -> String {
        let names = offered.compactMap { $0 as? String }
        if allow { return names.first { $0 == "accept" } ?? names.first { $0.hasPrefix("accept") } ?? "accept" }
        return names.first { $0 == "decline" } ?? names.first { $0 == "cancel" } ?? "cancel"
    }

    /// A request Octet can't put to the person yet, in words for the transcript.
    static func unsupported(_ method: String) -> String {
        switch method {
        case "item/tool/requestUserInput": "Codex asked you a question Octet can't show yet, so it was told no answer is coming. Open in Terminal to answer it in Codex."
        case "mcpServer/elicitation/request": "An MCP server asked you for input Octet can't show yet, so it was told no answer is coming. Open in Terminal to answer it in Codex."
        default: "Codex asked for something Octet doesn't handle yet (\(method)), so it was told no. Open in Terminal to continue in Codex."
        }
    }
}

/// Codex app-server's experimental `request_user_input` request translated
/// into the common question shape drawn by Octet.
enum CodexUserInput {
    static func question(_ params: [String: Any]) -> OpenCodeQuestion? {
        let questions = params["questions"] as? [[String: Any]] ?? []
        return OpenCodeQuestion([
            "id": params["itemId"] as? String ?? UUID().uuidString,
            "sessionID": params["threadId"] as? String ?? "",
            "questions": questions.map { item in
                [
                    "header": item["header"] as? String ?? "",
                    "question": item["question"] as? String ?? "",
                    "options": item["options"] as? [[String: Any]] ?? [],
                    "multiple": false,
                    "custom": (item["isOther"] as? Bool ?? false) || item["options"] == nil,
                    "secret": item["isSecret"] as? Bool ?? false,
                ] as [String: Any]
            },
        ])
    }

    static func questionIds(_ params: [String: Any]) -> [String] {
        (params["questions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    static func response(questionIds: [String], answers: [[String]]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        for (index, id) in questionIds.enumerated() {
            mapped[id] = ["answers": answers.indices.contains(index) ? answers[index] : []]
        }
        return ["answers": mapped]
    }
}
