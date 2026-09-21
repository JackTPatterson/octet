import AppKit
import Foundation

/// Driving OpenCode: a session on its server, prompts sent as requests, and
/// the server's events building the transcript. Everything a message needs
/// (model, reasoning variant, agent) goes with that message, so a change in
/// the pickers applies from the next one; permissions are the session's.
extension AgentSession: OpenCodeServer.Listener {
    var openCodeCatalog: OpenCodeCatalog { OpenCodeCatalogStore.shared.catalog(for: cwd) }

    /// The model picked, when the catalog has it.
    var openCodeModel: OpenCodeCatalog.Model? { openCodeCatalog.model(model) }

    // MARK: - Starting

    func startOpenCode() {
        OpenCodeServer.shared.listen(self)
        startupError = nil
        OpenCodeCatalogStore.shared.load(cwd: cwd) { [weak self] in self?.adoptOpenCodeDefaults() }
        if let id = threadId {
            openCode.sessionId = id
            flushOpenCodeQueue()
            return
        }
        guard !openCodeCreating else { return }
        openCodeCreating = true
        var body: [String: Any] = [:]
        let rules = OpenCodePermission.ruleset(permissionProfile)
        if !rules.isEmpty { body["permission"] = rules }
        OpenCodeServer.shared.request("POST", "session", directory: cwd, body: body) { [weak self] result in
            guard let self else { return }
            self.openCodeCreating = false
            switch result {
            case .success(let json):
                guard let id = (json as? [String: Any])?["id"] as? String else {
                    return self.openCodeFailed("OpenCode didn't open a session.")
                }
                self.threadId = id
                self.openCode.sessionId = id
                AgentCenter.shared.save()
                self.flushOpenCodeQueue()
            case .failure(let failure):
                self.openCodeFailed("Couldn't start OpenCode: \(failure)")
            }
        }
    }

    /// Settles the pickers once the catalog is in: a model the folder has,
    /// and a variant that model takes.
    private func adoptOpenCodeDefaults() {
        let catalog = openCodeCatalog
        guard !catalog.models.isEmpty else {
            if let error = OpenCodeCatalogStore.shared.errors[cwd] { startupError = error }
            else { startupError = "OpenCode isn't signed in to any provider. Run `opencode auth login` in a terminal." }
            return
        }
        if catalog.model(model) == nil,
           let fallback = catalog.defaultModel(configured: OpenCodeCatalogStore.shared.configuredModels[cwd]) {
            model = fallback.id
        }
        if let effort, openCodeModel?.variants.contains(effort) != true { self.effort = nil }
        if let agentName, !catalog.agents.contains(where: { $0.name == agentName }) { self.agentName = nil }
        conversation.contextWindow = openCodeModel?.context
    }

    private func openCodeFailed(_ message: String) {
        startupError = message
        if !openCodeQueue.isEmpty {
            openCodeQueue = []
            conversation.isRunning = false
            conversation.lastError = message
            notice(message)
        }
    }

    // MARK: - Sending

    func sendOpenCode(_ text: String, attachments: [Attachment]) {
        if !attachments.isEmpty, let model = openCodeModel, !model.images {
            notice("\(model.name) doesn't take images, so only the text was sent.")
        }
        let images = (openCodeModel?.images ?? true) ? attachments : []
        let body: [String: Any]
        let path: String
        if let command = openCodeCommand(text) {
            // A command the server runs (its own, a project's, or a skill),
            // with the rest of the line as its arguments.
            path = "command"
            var request: [String: Any] = ["command": command.name, "arguments": command.arguments]
            if let agentName { request["agent"] = agentName }
            if openCodeModel != nil { request["model"] = model }
            if let effort { request["variant"] = effort }
            body = request
        } else {
            path = "prompt_async"
            var parts: [[String: Any]] = images.map {
                ["type": "file", "mime": $0.mediaType, "filename": "image." + ($0.mediaType == "image/png" ? "png" : "jpg"),
                 "url": "data:\($0.mediaType);base64,\($0.data.base64EncodedString())"]
            }
            if !text.isEmpty { parts.insert(["type": "text", "text": text], at: 0) }
            var request: [String: Any] = ["parts": parts]
            if let model = openCodeModel { request["model"] = ["providerID": model.providerID, "modelID": model.modelID] }
            if let agentName { request["agent"] = agentName }
            if let effort, openCodeModel?.variants.contains(effort) == true { request["variant"] = effort }
            body = request
        }
        guard threadId != nil, openCode.sessionId != nil else {
            openCodeQueue.append(["path": path, "body": body])
            startOpenCode()
            return
        }
        post(path: path, body: body)
    }

    private func post(path: String, body: [String: Any]) {
        guard let id = threadId else { return }
        hasTurns = true
        conversation.isRunning = true
        OpenCodeServer.shared.request("POST", "session/\(id)/\(path)", directory: cwd, body: body) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.conversation.isRunning = false
            self.conversation.lastError = failure.description
            self.notice(failure.description)
        }
    }

    private func flushOpenCodeQueue() {
        let queued = openCodeQueue
        openCodeQueue = []
        for message in queued {
            if let path = message["path"] as? String, let body = message["body"] as? [String: Any] { post(path: path, body: body) }
        }
    }

    /// `/name arguments`, when `name` is one of the server's commands.
    private func openCodeCommand(_ text: String) -> (name: String, arguments: String)? {
        guard text.hasPrefix("/") else { return nil }
        let line = text.dropFirst()
        let name = String(line.prefix { !$0.isWhitespace })
        guard openCodeCommands.contains(where: { $0.name == name }) else { return nil }
        return (name, line.dropFirst(name.count).trimmingCharacters(in: .whitespaces))
    }

    /// Compacts the conversation with the model in use (`/compact`).
    func compactOpenCode() {
        guard let id = threadId, let model = openCodeModel else { return }
        conversation.isRunning = true
        OpenCodeServer.shared.request("POST", "session/\(id)/summarize", directory: cwd,
                                      body: ["providerID": model.providerID, "modelID": model.modelID]) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.conversation.isRunning = false
            self.notice("Couldn't compact the conversation: \(failure)")
        }
    }

    func interruptOpenCode() {
        guard let id = threadId else { return }
        OpenCodeServer.shared.request("POST", "session/\(id)/abort", directory: cwd) { _ in }
    }

    func closeOpenCode() {
        OpenCodeServer.shared.stopListening(self)
        if let question = pendingQuestion { rejectQuestion(question) }
        questionQueue = []
    }

    // MARK: - Commands

    /// The server's commands for this folder (custom, MCP prompts and
    /// skills), fetched once.
    var openCodeCommands: [SlashCommand] {
        OpenCodeCommandStore.shared.commands(for: cwd)
    }

    /// Exactly what OpenCode publishes (its server's commands, MCP prompts
    /// and skills, as its ACP server advertises them), by name. Its other
    /// built-ins live only in its terminal interface.
    var openCodeSlashCommands: [SlashCommand] {
        openCodeCommands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Permissions

    func updateOpenCodePermissions() {
        guard let id = threadId else { return }
        // Nil goes back to the config's rules: an empty session ruleset.
        OpenCodeServer.shared.request("PATCH", "session/\(id)", directory: cwd,
                                      body: ["permission": OpenCodePermission.ruleset(permissionProfile)]) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.notice("OpenCode didn't take the new permissions: \(failure)")
        }
    }

    private func receiveOpenCodePermission(_ request: [String: Any]) {
        guard let requestId = request["id"] as? String else { return }
        let callId = (request["tool"] as? [String: Any])?["callID"] as? String
        let input: [String: Any]? = conversation.items.first { $0.id == callId }.flatMap { item in
            guard case .tool(let call) = item.kind else { return nil }
            return call.inputObject
        }
        let prompt = OpenCodePermission.prompt(request, toolInput: input)
        let cardId = prompt["tool_use_id"] as? String ?? requestId
        openCodePermissions[cardId] = requestId
        receivePermission(prompt) { [weak self] decision in
            guard let self else { return }
            self.openCodePermissions.removeValue(forKey: cardId)
            let allow = decision["behavior"] as? String == "allow"
            let key = AgentPermissionRequest(json: prompt).map(Self.allowKey)
            let always = allow && key.map { self.sessionAllows.contains($0) } == true
            var body: [String: Any] = ["reply": OpenCodePermission.reply(allow: allow, forSession: always)]
            // A note typed with a refusal goes back to the agent, which then
            // carries on with it; a plain refusal stops the turn.
            if !allow, let message = decision["message"] as? String, message != "The user declined this in Octet." {
                body["message"] = message
            }
            OpenCodeServer.shared.request("POST", "permission/\(requestId)/reply", directory: self.cwd, body: body) { result in
                if case .failure(let failure) = result { self.notice("Couldn't answer OpenCode: \(failure)") }
            }
        }
    }

    // MARK: - Questions

    func answerQuestion(_ question: OpenCodeQuestion, answers: [[String]]) {
        OpenCodeServer.shared.request("POST", "question/\(question.id)/reply", directory: cwd,
                                      body: ["answers": answers]) { [weak self] result in
            if case .failure(let failure) = result { self?.notice("Couldn't answer OpenCode: \(failure)") }
        }
        advanceQuestion(question.id)
    }

    func rejectQuestion(_ question: OpenCodeQuestion) {
        OpenCodeServer.shared.request("POST", "question/\(question.id)/reject", directory: cwd) { _ in }
        advanceQuestion(question.id)
    }

    private func advanceQuestion(_ id: String) {
        questionQueue.removeAll { $0.id == id }
        guard pendingQuestion?.id == id else { return }
        pendingQuestion = questionQueue.isEmpty ? nil : questionQueue.removeFirst()
    }

    // MARK: - Events

    func openCodeEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        let properties = event["properties"] as? [String: Any] ?? [:]
        let session = properties["sessionID"] as? String
        switch type {
        case "permission.asked" where openCode.owns(session):
            receiveOpenCodePermission(properties)
        case "permission.replied" where openCode.owns(session):
            // Answered in OpenCode's own interface: off the card.
            if let requestId = properties["requestID"] as? String,
               let cardId = openCodePermissions.first(where: { $0.value == requestId })?.key {
                openCodePermissions.removeValue(forKey: cardId)
                dropPermission(id: cardId)
            }
        case "question.asked" where openCode.owns(session):
            guard let question = OpenCodeQuestion(properties) else { return }
            if pendingQuestion == nil { pendingQuestion = question } else { questionQueue.append(question) }
            NSApp.requestUserAttention(.informationalRequest)
        case "question.replied", "question.rejected":
            if let id = properties["requestID"] as? String { advanceQuestion(id) }
        case "session.updated" where session == threadId:
            let info = properties["info"] as? [String: Any] ?? [:]
            adoptOpenCodeTitle(info["title"] as? String)
            // Messages undone in OpenCode's own interface stay hidden here.
            openCodeRevertMessage = (info["revert"] as? [String: Any])?["messageID"] as? String
        default:
            break
        }
        let wasRunning = conversation.isRunning
        guard openCode.owns(session) || type == "session.created" else { return }
        openCode.apply(event, to: &conversation)
        if wasRunning, !conversation.isRunning { turnStartedAt = nil }
    }

    func openCodeStreamResumed() {
        guard hasTurns else { return }
        restoreOpenCodeTranscript(force: true)
    }

    func openCodeServerRestarted() {
        guard conversation.isRunning else { return }
        conversation.isRunning = false
        notice("OpenCode's server stopped, so this turn ended. Send again to carry on.")
    }

    /// OpenCode names a conversation from its first message; that name wins
    /// over Octet's placeholder, not over one you gave it.
    private func adoptOpenCodeTitle(_ generated: String?) {
        guard let generated, !generated.isEmpty, !generated.hasPrefix("New session"),
              title == engine.displayName || title == provisionalTitle else { return }
        title = generated
        provisionalTitle = generated
    }

    // MARK: - Restoring

    /// Brings back a saved conversation's transcript from OpenCode's history.
    func restoreOpenCodeTranscript(force: Bool = false) {
        guard let id = threadId else { return }
        OpenCodeServer.shared.request("GET", "session/\(id)/message", directory: cwd) { [weak self] result in
            guard let self, case .success(let json) = result, let messages = json as? [[String: Any]],
                  force || self.conversation.items.isEmpty else { return }
            let running = self.conversation.isRunning
            // Undone messages stay stored until the next message; they're hidden.
            let cut = self.openCodeRevertMessage.flatMap { point in messages.firstIndex { ($0["info"] as? [String: Any])?["id"] as? String == point } }
            let (stream, conversation) = OpenCodeStream.replay(cut.map { Array(messages[..<$0]) } ?? messages, sessionId: id)
            self.openCode = stream
            self.conversation = conversation
            self.conversation.cwd = self.cwd
            self.conversation.contextWindow = self.openCodeModel?.context
            // A turn still going carries on; the next status says when it ends.
            if force { self.conversation.isRunning = running }
        }
    }
}

extension AgentSession {
    /// Signs OpenCode in to a provider: its own prompt, in a new tab.
    func openCodeSignIn(window: WindowContext) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        window.applyLayout([
            "tab_label": "OpenCode sign-in",
            "root": ["type": "pane", "label": "OpenCode sign-in", "cwd": cwd,
                     "command": [shell, "-lic", "opencode auth login; exec \(shell) -l"]] as [String: Any],
        ], failure: "Couldn't open OpenCode's sign-in")
    }
}

/// OpenCode's commands (its own, the project's, and skills), per folder,
/// for the `/` menu.
@MainActor
final class OpenCodeCommandStore {
    static let shared = OpenCodeCommandStore()
    private var commands: [String: [SlashCommand]] = [:]
    private var loading: Set<String> = []

    func commands(for cwd: String) -> [SlashCommand] {
        if commands[cwd] == nil, loading.insert(cwd).inserted {
            OpenCodeServer.shared.request("GET", "command", directory: cwd) { [weak self] result in
                guard let self else { return }
                self.loading.remove(cwd)
                guard case .success(let json) = result, let list = json as? [[String: Any]] else { return }
                self.commands[cwd] = list.compactMap { command in
                    guard let name = command["name"] as? String else { return nil }
                    let origin: SlashCommand.Origin = switch command["source"] as? String {
                    case "skill": .plugin("skill")
                    case "mcp": .plugin("mcp")
                    default: .builtIn
                    }
                    return SlashCommand(name: name, summary: command["description"] as? String ?? "", origin: origin)
                }
                AgentCenter.shared.objectWillChange.send()
            }
        }
        return commands[cwd] ?? []
    }
}
