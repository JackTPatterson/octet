import AppKit
import Foundation

/// One native conversation with Claude Code, driven headless over its
/// stream-json interface (see docs/NATIVE-AGENT-UI.md). One long-lived
/// process per conversation; model, effort and permission mode changes take
/// effect by resuming the session on the next message, which is cheap while
/// the agent's prompt cache is warm.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    enum PermissionMode: String, CaseIterable, Identifiable {
        case `default`, acceptEdits, plan, auto, bypassPermissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .default: "Ask"
            case .acceptEdits: "Accept edits"
            case .plan: "Plan"
            case .auto: "Auto"
            case .bypassPermissions: "Bypass"
            }
        }
    }

    /// A model Claude Code can run, pinned by its full id so the version is
    /// explicit. There's no way to list what a subscription allows without
    /// an API key, so this is curated; a model the plan can't use comes back
    /// as an error in the conversation.
    struct Model: Identifiable {
        let id: String
        let family: String
        let version: String
        let detail: String
        var title: String { "\(family) \(version)" }
    }

    static let models: [Model] = [
        Model(id: "claude-fable-5-1", family: "Fable", version: "5.1", detail: "Most capable · 1M context · $10/$50"),
        Model(id: "claude-fable-5", family: "Fable", version: "5", detail: "1M context · $10/$50"),
        Model(id: "claude-opus-5", family: "Opus", version: "5", detail: "1M context · $5/$25"),
        Model(id: "claude-opus-4-8", family: "Opus", version: "4.8", detail: "1M context · $5/$25"),
        Model(id: "claude-opus-4-7", family: "Opus", version: "4.7", detail: "1M context · $5/$25"),
        Model(id: "claude-opus-4-6", family: "Opus", version: "4.6", detail: "1M context · $5/$25"),
        Model(id: "claude-sonnet-5", family: "Sonnet", version: "5", detail: "1M context · $2/$10"),
        Model(id: "claude-sonnet-4-6", family: "Sonnet", version: "4.6", detail: "1M context · $3/$15"),
        Model(id: "claude-haiku-4-5", family: "Haiku", version: "4.5", detail: "Fastest · 200K context · $1/$5"),
    ]

    static func model(_ id: String) -> Model? { models.first { $0.id == id } }

    /// The effort Claude Code uses when none is set: xhigh where the model
    /// has it, high on the 4.6 models, and none on Haiku 4.5, which has no
    /// effort setting at all.
    static func defaultEffort(model: String) -> String? {
        if model.contains("haiku") { return nil }
        if model.hasSuffix("4-6") { return "high" }
        return "xhigh"
    }

    static func supportsEffort(model: String) -> Bool { defaultEffort(model: model) != nil }
    /// Claude Code's effort levels; ultracode is xhigh plus workflows.
    nonisolated static let efforts = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    /// Which CLI is behind the conversation. Claude Code is driven over its
    /// stream-json stdio; Codex over its app server's JSON-RPC; Pi over RPC;
    /// and Qwen over stream-json. Everything
    /// downstream, the transcript and the view, is the same for both.
    enum Engine: String, Codable {
        case claude, codex, opencode, pi, qwen

        var displayName: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            case .pi: "Pi"
            case .qwen: "Qwen"
            }
        }
        /// The vendor mark, and what `SlashCommands` files are read for.
        var agent: String { rawValue }
    }

    let id = UUID().uuidString
    let engine: Engine
    let workspaceId: String
    let cwd: String
    @Published var conversation = AgentConversation() {
        didSet {
            if conversation.isRunning != oldValue.isRunning {
                AgentCenter.shared.objectWillChange.send()
            }
        }
    }
    @Published var title: String {
        // The title bar and tab strip watch the center, not each session.
        didSet {
            guard title != oldValue else { return }
            AgentCenter.shared.objectWillChange.send()
            AgentCenter.shared.save()
        }
    }
    // Claude Code takes these as flags, so changing one restarts it against
    // the same session. Codex's app server takes them live.
    @Published var model: String { didSet { if model != oldValue { settingsChanged() } } }
    @Published var effort: String? { didSet { if effort != oldValue { settingsChanged() } } }
    @Published var permissionMode: PermissionMode {
        didSet { if permissionMode != oldValue { settingsChanged() } }
    }
    /// Codex: the sandbox a thread runs under, e.g. `:workspace`. OpenCode:
    /// a permission preset (`OpenCodePermission.presets`). Nil leaves
    /// whatever the person's own config says.
    @Published var permissionProfile: String? { didSet { if permissionProfile != oldValue { settingsChanged() } } }
    /// OpenCode only: the agent messages go to (Build, Plan, or one of the
    /// person's own). Nil is OpenCode's default.
    @Published var agentName: String? { didSet { if agentName != oldValue { AgentCenter.shared.save() } } }

    private func settingsChanged() {
        switch engine {
        case .claude:
            needsRestart = true
        case .codex:
            if let threadId, process?.isRunning == true { updateCodexSettings(threadId: threadId) }
        case .opencode:
            // Model, variant and agent go with each message; permissions are
            // the session's, and change at once.
            updateOpenCodePermissions()
        case .pi:
            updatePiSettings()
        case .qwen:
            needsRestart = true
        }
        AgentCenter.shared.save()
    }
    @Published private(set) var pendingPermission: AgentPermissionRequest? {
        didSet {
            if pendingPermission?.id != oldValue?.id { AgentCenter.shared.objectWillChange.send() }
        }
    }
    @Published var startupError: String?

    /// Assigned up front so the session can be resumed or opened in a pane.
    let sessionId: String
    var hasTurns = false {
        didSet { if hasTurns != oldValue { AgentCenter.shared.save() } }
    }
    private var needsRestart = false
    private var process: Process?
    /// The live CLI process behind this conversation. Runtime inspection uses
    /// it as the root so unrelated shells and agents never leak into the panel.
    var runtimePID: Int? {
        guard let process, process.isRunning else { return nil }
        return Int(process.processIdentifier)
    }
    private var stdin: FileHandle?
    private var lineBuffer = Data()
    private var stderrTail = ""
    private var permissionServer: PermissionSocketServer?
    private var permissionReply: (([String: Any]) -> Void)?
    private var permissionQueue: [(AgentPermissionRequest, ([String: Any]) -> Void)] = []

    // MARK: - OpenCode

    /// Reads the server's events for this conversation's session.
    var openCode = OpenCodeStream()
    /// A question OpenCode's agent is waiting on you to answer.
    @Published var pendingQuestion: OpenCodeQuestion? {
        didSet {
            if pendingQuestion?.id != oldValue?.id { AgentCenter.shared.objectWillChange.send() }
        }
    }
    var questionQueue: [OpenCodeQuestion] = []
    /// Non-OpenCode transports reuse the same question card and keep their
    /// protocol-specific answer writers here, keyed by the visible request.
    var questionAnswers: [String: ([[String]]) -> Void] = [:]
    var questionRejects: [String: () -> Void] = [:]
    /// Messages written before the session existed, sent once it does.
    var openCodeQueue: [[String: Any]] = []
    var openCodeCreating = false
    /// Permission requests on the card, by the tool call they're for.
    var openCodePermissions: [String: String] = [:]
    /// The title Octet gave from the first message, which OpenCode's own
    /// generated title may replace.
    var provisionalTitle: String?
    /// The first message undone in OpenCode's own interface, from which
    /// the transcript is hidden, as OpenCode hides it.
    var openCodeRevertMessage: String?

    // MARK: - Pi

    /// Models and reasoning levels reported by the running Pi RPC session.
    /// They reflect configured credentials, so an unauthenticated install
    /// intentionally produces an empty model list.
    @Published private(set) var piModels: [PiModel] = []
    @Published private(set) var piThinkingLevels: [String] = ["off"]
    @Published private(set) var piStatusText: String?
    @Published private(set) var piWidgets: [PiWidget] = []
    @Published private(set) var piEditorRequest: PiEditorRequest?
    private var piStatuses: [String: String] = [:]
    private var piApplyingState = false
    private var piAppliedModel: String?
    private var piAppliedThinking: String?

    struct PiWidget: Identifiable, Equatable {
        let id: String
        let lines: [String]
        let placement: String
    }

    struct PiEditorRequest: Identifiable, Equatable {
        let id: String
        let text: String
    }

    // MARK: - Codex

    /// The thread the app server opened for this conversation. Codex names
    /// its own threads, unlike Claude Code, which takes the id Octet gives it.
    /// Codex's thread, or OpenCode's session: the agent's own id for it.
    var threadId: String?
    /// What each call Octet has made to the app server was for, by id, so an
    /// answer (or an error) lands where it belongs.
    private enum CodexCall { case handshake, thread, turn, settings, interrupt, command(String) }
    private var codexCalls: [Int: CodexCall] = [:]
    private var nextRequestId = 0
    /// Messages sent before the thread was open, in order.
    private var queuedTurns: [String] = []

    /// The model a conversation starts on until one is picked.
    static let defaultModel = "claude-sonnet-5"

    init(workspaceId: String, cwd: String, engine: Engine = .claude, model: String = AgentSession.defaultModel,
         permissionMode: PermissionMode = .auto, sessionId: String = UUID().uuidString, threadId: String? = nil) {
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.engine = engine
        self.model = model
        self.permissionMode = permissionMode
        self.sessionId = sessionId
        self.threadId = threadId
        title = engine.displayName
        conversation.cwd = cwd
    }

    // MARK: - Saving

    /// What Octet remembers about an open conversation across launches; the
    /// transcript itself comes back from the agent's own session log.
    struct Saved: Codable {
        var sessionId: String
        var cwd: String
        var title: String
        var model: String
        var effort: String?
        var permissionMode: String
        var hasTurns: Bool
        /// Absent in conversations saved before Codex ones existed.
        var engine: Engine?
        /// Codex: the thread to resume, and the sandbox it runs under.
        /// OpenCode: its session, and a permission preset.
        var threadId: String?
        var permissionProfile: String?
        /// OpenCode only: the agent messages go to.
        var agent: String?
    }

    var saved: Saved {
        Saved(sessionId: sessionId, cwd: cwd, title: title, model: model, effort: effort,
              permissionMode: permissionMode.rawValue, hasTurns: hasTurns, engine: engine, threadId: threadId,
              permissionProfile: permissionProfile, agent: agentName)
    }

    static func restore(_ saved: Saved, workspaceId: String) -> AgentSession {
        let engine = saved.engine ?? .claude
        let session = AgentSession(workspaceId: workspaceId, cwd: saved.cwd, engine: engine, model: saved.model,
                                   permissionMode: PermissionMode(rawValue: saved.permissionMode) ?? .default,
                                   sessionId: saved.sessionId, threadId: saved.threadId)
        session.effort = saved.effort
        session.permissionProfile = saved.permissionProfile
        session.agentName = saved.agent
        session.title = saved.title
        session.hasTurns = saved.hasTurns
        session.needsRestart = false
        switch engine {
        case .claude:
            session.conversation = restoredTranscript(saved, engine: engine) ?? session.conversation
        case .codex:
            // Finding a Codex thread's log means asking its database, which
            // runs a process; done here, launch would wait on one per thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let transcript = restoredTranscript(saved, engine: .codex)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Unless the conversation has moved on since.
                        guard let transcript, session.conversation.items.isEmpty else { return }
                        session.conversation = transcript
                    }
                }
            }
        case .opencode:
            // OpenCode keeps the history; its server hands it back.
            session.openCode.sessionId = saved.threadId
            if saved.hasTurns {
                session.startOpenCode()
                session.restoreOpenCodeTranscript()
            }
        case .pi, .qwen:
            session.prewarm()
        }
        return session
    }

    /// The transcript as the agent's own log has it: Claude Code's session
    /// JSONL, or the rollout log Codex keeps per thread.
    private nonisolated static func restoredTranscript(_ saved: Saved, engine: Engine) -> AgentConversation? {
        var conversation: AgentConversation?
        switch engine {
        case .claude:
            if let path = AgentConversation.findLog(sessionIds: [saved.sessionId], cwd: saved.cwd),
               let log = try? String(contentsOfFile: path, encoding: .utf8) {
                conversation = AgentConversation.replay(lines: log.components(separatedBy: "\n"))
            }
        case .codex:
            if let threadId = saved.threadId, let path = CodexThreads.rolloutPath(threadId: threadId),
               let log = try? String(contentsOfFile: path, encoding: .utf8) {
                let twin = TwinTranscript.parse(agent: "codex", lines: log.components(separatedBy: "\n"))
                conversation = AgentConversation(twin: twin)
            }
        case .opencode:
            break
        case .pi, .qwen:
            break
        }
        conversation?.cwd = saved.cwd
        return conversation
    }

    // MARK: - Slash commands

    private var diskCommands: [SlashCommand]?

    /// What `/` offers: the user's, the project's and plugins' commands from
    /// disk (ready before the first message), the headless-safe built-ins,
    /// and whatever else the agent reports once it's running, like skills.
    /// The commands the agent itself reports it can run (Claude Code's, from
    /// its `initialize` answer), as it describes them.
    @Published var agentCommands: [SlashCommand] = []
    static let commandsRequest = "octet-commands"

    /// What `/` offers, from the agent wherever it publishes a list, plus the
    /// actions Octet carries out itself. Nothing here is a guess at what an
    /// agent's own interface shows.
    var slashCommands: [SlashCommand] {
        let commands: [SlashCommand]
        switch engine {
        case .opencode:
            commands = openCodeSlashCommands
        case .claude:
            commands = agentCommands
        case .codex:
            // Codex publishes no command list; its menu's own entries are its
            // prompt files, which its app server doesn't expand, so Octet does.
            if diskCommands == nil {
                diskCommands = SlashCommands.all(agent: "codex", cwd: cwd)
            }
            commands = SlashCommands.codexOctetCommands + (diskCommands ?? []).map { prompt in
                var prompt = prompt
                prompt.handling = .octet
                return prompt
            }
        case .pi:
            commands = agentCommands + SlashCommands.piOctetCommands
        case .qwen:
            commands = agentCommands
        }
        return commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Turns

    /// An image attached to the next message, already scaled and encoded.
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let mediaType: String

        /// Scales to the model's useful size (1568px on the long edge) and
        /// encodes as JPEG, or PNG when the image has transparency.
        init?(image: NSImage) {
            guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff) else { return nil }
            let longest = CGFloat(max(source.pixelsWide, source.pixelsHigh))
            let scale = min(1, 1568 / max(longest, 1))
            let width = Int(CGFloat(source.pixelsWide) * scale), height = Int(CGFloat(source.pixelsHigh) * scale)
            guard width > 0, height > 0,
                  let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
            source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            if source.hasAlpha, let png = target.representation(using: .png, properties: [:]) {
                data = png
                mediaType = "image/png"
            } else if let jpeg = target.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                data = jpeg
                mediaType = "image/jpeg"
            } else {
                return nil
            }
        }
    }

    /// When the turn in flight started, for the status line.
    @Published var turnStartedAt: Date?

    /// What the agent is doing right now, in a few words.
    var activity: String {
        guard conversation.isRunning else { return "" }
        if engine == .pi, let piStatusText, !piStatusText.isEmpty { return piStatusText }
        for item in conversation.items.reversed() {
            switch item.kind {
            case .tool(let call) where call.result == nil:
                return call.summary.isEmpty ? "Running \(call.name)" : "\(call.name) \(call.summary)"
            case .tool: return "Working"
            case .thinking: return "Thinking"
            case .text: return "Writing"
            case .user: return "Starting"
            case .notice: continue
            }
        }
        return "Working"
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // `/rename` renames the session in Claude Code and the tab here.
        if trimmed.hasPrefix("/rename ") {
            let name = trimmed.dropFirst("/rename ".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { title = name }
        }
        if engine == .opencode {
            if !conversation.isRunning { turnStartedAt = Date() }
            conversation.appendUser(trimmed, images: attachments.map(\.data))
            if title == engine.displayName, !trimmed.hasPrefix("/") {
                title = String(trimmed.prefix(40))
                provisionalTitle = title
            }
            if trimmed == "/compact" { compactOpenCode() } else { sendOpenCode(trimmed, attachments: attachments) }
            return
        }
        if needsRestart || process?.isRunning != true { restart() }
        guard stdin != nil else { return }
        if !conversation.isRunning { turnStartedAt = Date() }
        conversation.appendUser(trimmed, images: attachments.map(\.data))
        if title == engine.displayName, !trimmed.hasPrefix("/") { title = String(trimmed.prefix(40)) }
        switch engine {
        case .claude, .qwen:
            let message: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": Self.content(trimmed, attachments)],
                "parent_tool_use_id": NSNull(),
            ]
            if write(message) { hasTurns = true }
        case .codex:
            if !attachments.isEmpty {
                conversation.items.append(AgentItem(id: UUID().uuidString,
                                                    kind: .notice("Codex conversations don't take images yet; the text was sent.")))
            }
            // The thread may still be opening, and a turn needs its id.
            guard let threadId else { queuedTurns.append(trimmed); return }
            startTurn(trimmed, threadId: threadId)
        case .opencode:
            break
        case .pi:
            var message: [String: Any] = ["type": "prompt", "message": trimmed]
            if !attachments.isEmpty {
                message["images"] = attachments.map {
                    ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mediaType]
                }
            }
            if conversation.isRunning { message["streamingBehavior"] = "followUp" }
            if write(message) { hasTurns = true }
        }
    }

    /// Writes one message to the agent's stdin: a stream-json line for Claude
    /// Code, a JSON-RPC one for Codex. Both are newline-delimited JSON.
    /// Returns whether it went. Only a turn counts as having used the
    /// conversation, and Codex's handshake goes through here too.
    @discardableResult
    private func write(_ message: [String: Any]) -> Bool {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do {
            try stdin.write(contentsOf: data)
            return true
        } catch {
            let failure = "Couldn't reach \(engine.displayName): \(error.localizedDescription)"
            switch engine {
            case .claude, .qwen: conversation.apply(["type": "result", "subtype": "error", "errors": [failure]])
            case .codex: conversation.applyCodex(["method": "turn/failed", "params": ["error": ["message": failure]]])
            case .opencode: break
            case .pi: conversation.applyPi(["type": "response", "success": false, "error": failure])
            }
            return false
        }
    }

    private func startTurn(_ text: String, threadId: String) {
        let sent = call("turn/start", ["threadId": threadId, "input": [["type": "text", "text": text]]], as: .turn)
        if sent { hasTurns = true }
    }

    /// Makes a call to the app server and remembers what it was for.
    @discardableResult
    private func call(_ method: String, _ params: [String: Any], as kind: CodexCall) -> Bool {
        let id = nextId()
        codexCalls[id] = kind
        return write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func nextId() -> Int {
        nextRequestId += 1
        return nextRequestId
    }

    /// Plain text, or image blocks followed by the text.
    private static func content(_ text: String, _ attachments: [Attachment]) -> Any {
        guard !attachments.isEmpty else { return text }
        var blocks: [[String: Any]] = attachments.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        return blocks
    }

    /// Ends the current turn; the process stays up for the next message.
    /// Claude Code takes a signal, Codex an interrupt for the thread.
    func interrupt() {
        if engine == .opencode {
            if conversation.isRunning { interruptOpenCode() }
            return
        }
        guard let process, process.isRunning, conversation.isRunning else { return }
        switch engine {
        case .claude, .qwen:
            process.interrupt()
        case .codex:
            guard let threadId else { return }
            call("turn/interrupt", ["threadId": threadId], as: .interrupt)
        case .opencode:
            break
        case .pi:
            write(["type": "abort"])
        }
    }

    /// Starts the process ahead of the first message, so its startup
    /// overlaps with typing.
    func prewarm() {
        if engine == .opencode { return startOpenCode() }
        if process == nil { restart() }
    }

    func close() {
        denyAllPending(message: "The conversation was closed.")
        if engine == .opencode { closeOpenCode() }
        stopProcess()
        permissionServer?.stop()
        permissionServer = nil
    }

    // MARK: - Permissions

    /// Answers allowed for the rest of this conversation: an exact Bash
    /// command, all file edits, or any other tool by name.
    private(set) var sessionAllows: Set<String> = []

    static func allowKey(_ request: AgentPermissionRequest) -> String {
        switch request.toolName {
        case "Bash": "Bash|" + (request.inputObject["command"] as? String ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "edits"
        default: request.toolName
        }
    }

    /// How "Allow for Session" reads for this request.
    static func sessionAllowTitle(_ request: AgentPermissionRequest) -> String {
        switch allowKey(request) {
        case "edits": "Allow Edits for Session"
        case let key where key.hasPrefix("Bash|"): "Allow Command for Session"
        default: "Allow \(request.toolName) for Session"
        }
    }

    /// A request answered somewhere else (OpenCode's own interface) leaves
    /// the card, unanswered from here.
    func dropPermission(id: String) {
        if pendingPermission?.id == id {
            pendingPermission = nil
            permissionReply = nil
            if !permissionQueue.isEmpty {
                let (next, nextReply) = permissionQueue.removeFirst()
                pendingPermission = next
                permissionReply = nextReply
            }
        } else {
            permissionQueue.removeAll { $0.0.id == id }
        }
    }

    func answerPermission(allow: Bool, note: String? = nil, forSession: Bool = false) {
        guard let request = pendingPermission, let reply = permissionReply else { return }
        if allow && forSession { sessionAllows.insert(Self.allowKey(request)) }
        reply(AgentPermissionRequest.decision(allow: allow, input: request.inputObject, message: note))
        pendingPermission = nil
        permissionReply = nil
        if !permissionQueue.isEmpty {
            let (next, nextReply) = permissionQueue.removeFirst()
            pendingPermission = next
            permissionReply = nextReply
        }
    }

    #if DEBUG
    /// Verification hook: a made-up transcript covering every block kind,
    /// for checking the rendering without calling the agent.
    func debugLoadSample() {
        title = "Fix the retry bug"
        conversation.appendUser("The upload retry loop never gives up. Can you fix it and explain?")
        let reply = """
        ## What's wrong

        `retryUpload` resets **attempt** on every failure, so the loop never ends. Two fixes:

        1. Count attempts outside the closure
        2. Cap retries at `maxAttempts`
           - with exponential backoff

        > The server already rate limits, so backoff matters.

        ```swift
        for attempt in 1...maxAttempts {
            if try await upload() { return }
            try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
        }
        ```

        The web client does the same:

        ```typescript
        export async function retry<T>(run: () => Promise<T>, attempts = 3): Promise<T> {
          for (let i = 0; i < attempts; i++) { try { return await run() } catch {} }
          throw new Error("gave up")
        }
        ```

        ```python
        def retry(run, attempts=3):
            for attempt in range(attempts):
                if run(): return True  # done
            return False
        ```
        """
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["id": "s1", "content": [
                ["type": "thinking", "thinking": "The loop variable is rebuilt per call; look at Uploader.swift."],
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/Users/me/app/Uploader.swift"]],
                ["type": "tool_use", "id": "t0", "name": "Read", "input": ["file_path": "/Users/me/app/web/retry.ts"]],
                ["type": "tool_use", "id": "t9", "name": "Read", "input": ["file_path": "/Users/me/app/package.json"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "func retryUpload() { var attempt = 0 ... }"]]]],
            ["type": "assistant", "message": ["id": "s2", "content": [
                ["type": "tool_use", "id": "t2", "name": "Edit", "input": [
                    "file_path": "/Users/me/app/Uploader.swift",
                    "old_string": "func retryUpload() {\n    var attempt = 0\n    while true {\n        attempt = 0\n        try? upload()\n    }\n}",
                    "new_string": "func retryUpload() {\n    var attempt = 0\n    while attempt < maxAttempts {\n        attempt += 1\n        if (try? upload()) == true { return }\n    }\n}",
                ]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t2", "content": "Updated"]]]],
            ["type": "assistant", "message": ["id": "s3", "content": [
                ["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "swift test --filter UploaderTests"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t3", "content": "Test Suite 'UploaderTests' passed\n  Executed 4 tests, with 0 failures"]]]],
            ["type": "assistant", "message": ["id": "s4", "content": [["type": "text", "text": reply]]]],
            ["type": "result", "subtype": "success", "total_cost_usd": 0.042,
             "modelUsage": ["claude-sonnet-5": ["contextWindow": 1_000_000]]],
        ]
        for event in events { conversation.apply(event) }
        conversation.apply(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "s5", "usage": ["input_tokens": 18_400]]]])
    }

    /// Verification hook: one of every transcript element, ending mid-turn
    /// so the status line shows. Nothing reaches the agent.
    func debugLoadEverything() {
        title = "Redesign the settings screen"
        func picture(_ label: String, _ top: NSColor, _ bottom: NSColor) -> Data {
            let image = NSImage(size: NSSize(width: 640, height: 380), flipped: false) { rect in
                NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 60, dy: 70), xRadius: 14, yRadius: 14).fill()
                let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                                                            .foregroundColor: NSColor.darkGray]
                (label as NSString).draw(at: NSPoint(x: 90, y: 170), withAttributes: style)
                return true
            }
            return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        }
        conversation.appendUser("Here's the current settings screen. Make it match the new design system and track the work.",
                                images: [picture("Settings (current)", .systemIndigo, .systemTeal)])
        let b64 = picture("Settings (redesign)", .systemPink, .systemOrange).base64EncodedString()
        let reply = """
        ## Done

        The settings screen now uses the **design system** tokens. Summary:

        | Area | Before | After |
        |---|---|---|
        | Spacing | 10, 14, 18 | 4pt grid |
        | Colors | hard-coded hex | `Theme` tokens |
        | Header | custom `Header` | `SectionHeader` |

        - Spacing moved to the 4pt grid
        - Colors come from `Theme`

        ```json
        { "spacing": 4, "radius": 6 }
        ```

        ```bash
        swift test --filter SettingsTests
        ```
        """
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["id": "e1", "content": [
                ["type": "thinking", "thinking": "Start by reading the view and the theme tokens, then search for hard-coded colors."],
                ["type": "tool_use", "id": "a1", "name": "TodoWrite", "input": ["todos": [
                    ["content": "Read the current settings view", "status": "completed", "activeForm": "Reading the view"],
                    ["content": "Replace hard-coded colors", "status": "completed", "activeForm": "Replacing colors"],
                    ["content": "Move spacing to the 4pt grid", "status": "in_progress", "activeForm": "Moving spacing to the 4pt grid"],
                    ["content": "Run the settings tests", "status": "pending", "activeForm": "Running tests"],
                ]]],
                ["type": "tool_use", "id": "a2", "name": "Read", "input": ["file_path": "/Users/me/app/Sources/SettingsView.swift"]],
                ["type": "tool_use", "id": "a3", "name": "Grep", "input": ["pattern": "Color\\(hex:", "path": "Sources"]],
                ["type": "tool_use", "id": "a4", "name": "Glob", "input": ["pattern": "**/*Theme*.swift"]],
            ]]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "a1", "content": "Todos updated"],
                ["type": "tool_result", "tool_use_id": "a2", "content": "struct SettingsView: View { ... }"],
                ["type": "tool_result", "tool_use_id": "a3", "content": "Sources/SettingsView.swift:42: .background(Color(hex: \"#1B1B1B\"))\nSources/Header.swift:9: .foregroundStyle(Color(hex: \"#999\"))"],
                ["type": "tool_result", "tool_use_id": "a4", "content": "Sources/Theme/Theme.swift\nSources/Theme/ThemePalette.swift"],
            ]]],
            ["type": "assistant", "message": ["id": "e2", "content": [
                ["type": "tool_use", "id": "b1", "name": "WebSearch", "input": ["query": "macOS settings window layout guidelines 2026"]],
                ["type": "tool_use", "id": "b2", "name": "WebFetch", "input": ["url": "https://developer.apple.com/design/human-interface-guidelines/settings", "prompt": "Summarize layout rules"]],
                ["type": "tool_use", "id": "b3", "name": "mcp__atlassian__searchJiraIssuesUsingJql", "input": ["jql": "project = NXS AND text ~ \"settings redesign\""]],
                ["type": "tool_use", "id": "b4", "name": "mcp__figma__get_screenshot", "input": ["nodeId": "12:340"]],
            ]]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "b1", "content": "1. Settings windows (HIG)\n2. Designing preferences on macOS"],
                ["type": "tool_result", "tool_use_id": "b2", "content": "Group related settings; keep labels leading and controls trailing."],
                ["type": "tool_result", "tool_use_id": "b3", "content": "NXS-412 Settings redesign (In Progress)"],
                ["type": "tool_result", "tool_use_id": "b4", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]]]],
            ]]],
            ["type": "assistant", "message": ["id": "e3", "content": [
                ["type": "tool_use", "id": "c1", "name": "Task", "input": ["description": "Audit spacing", "prompt": "Find spacing values off the 4pt grid", "subagent_type": "Explore"]],
            ]]],
            ["type": "assistant", "parent_tool_use_id": "c1", "message": ["id": "e3a", "content": [
                ["type": "text", "text": "Checking every `.padding` and `spacing:` in Sources."],
                ["type": "tool_use", "id": "c2", "name": "Grep", "input": ["pattern": "padding\\(|spacing:"]],
            ]]],
            ["type": "user", "parent_tool_use_id": "c1", "message": ["content": [["type": "tool_result", "tool_use_id": "c2", "content": "14 matches"]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "c1", "content": "3 values off the grid: 10, 14, 18"]]]],
            ["type": "assistant", "message": ["id": "e4", "content": [
                ["type": "tool_use", "id": "d1", "name": "Edit", "input": [
                    "file_path": "/Users/me/app/Sources/SettingsView.swift",
                    "old_string": "VStack(spacing: 10) {\n    Header(title: \"Settings\")\n        .padding(14)",
                    "new_string": "VStack(spacing: 8) {\n    SectionHeader(\"Settings\")\n        .padding(16)",
                ]],
                ["type": "tool_use", "id": "d2", "name": "Write", "input": [
                    "file_path": "/Users/me/app/Sources/Theme/Spacing.ts",
                    "content": "export const spacing = {\n  xs: 4,\n  sm: 8,\n  md: 16,\n} as const",
                ]],
                ["type": "tool_use", "id": "d3", "name": "MultiEdit", "input": [
                    "file_path": "/Users/me/app/scripts/lint.py",
                    "edits": [["old_string": "GRID = 2", "new_string": "GRID = 4"], ["old_string": "print(bad)", "new_string": "print(f\"off grid: {bad}\")"]],
                ]],
                ["type": "tool_use", "id": "d4", "name": "Bash", "input": ["command": "swift build 2>&1 | tail -3"]],
                ["type": "tool_use", "id": "d5", "name": "Bash", "input": ["command": "swiftlint --strict"]],
            ]]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "d1", "content": "Updated"],
                ["type": "tool_result", "tool_use_id": "d2", "content": "Created"],
                ["type": "tool_result", "tool_use_id": "d3", "content": "Applied 2 edits"],
                ["type": "tool_result", "tool_use_id": "d4", "content": "Compiling Settings\nBuild complete! (4.2s)"],
                ["type": "tool_result", "tool_use_id": "d5", "content": "SettingsView.swift:88: error: Line Length Violation", "is_error": true],
            ]]],
            ["type": "assistant", "message": ["id": "e5", "content": [["type": "text", "text": reply]]]],
            ["type": "result", "subtype": "success", "total_cost_usd": 0.31, "modelUsage": ["claude-opus-5": ["contextWindow": 1_000_000]]],
        ]
        for event in events { conversation.apply(event) }
        conversation.apply(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "unifiedWindows": [
            "five_hour": ["utilization": 0.34, "resetsAt": Date().addingTimeInterval(9_000).timeIntervalSince1970],
            "seven_day": ["utilization": 0.72, "resetsAt": Date().addingTimeInterval(200_000).timeIntervalSince1970],
        ]]])
        conversation.appendUser("Now also run the full test suite.")
        conversation.apply(["type": "result", "subtype": "error_during_execution"])
        conversation.appendUser("Actually, just the settings tests, then open a PR.")
        turnStartedAt = Date().addingTimeInterval(-37)
        conversation.apply(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "e6", "usage": ["input_tokens": 84_000]]]])
        conversation.apply(["type": "assistant", "message": ["id": "e6", "content": [
            ["type": "tool_use", "id": "f1", "name": "Bash", "input": ["command": "swift test --filter SettingsTests"]],
        ]]])
    }

    /// Verification hook: shows the permission card for a made-up request
    /// (no process involved; answering it goes nowhere).
    func debugShowPermission() {
        receivePermission(["tool_name": "Bash", "tool_use_id": "debug",
                           "input": ["command": "rm -rf build/DerivedData", "description": "Clear the build folder"]]) { _ in }
    }

    /// Verification hook for the corner panel's choices and typed answer.
    func debugShowQuestion() {
        pendingQuestion = OpenCodeQuestion([
            "id": "debug-question", "sessionID": sessionId,
            "questions": [
                ["header": "Database", "question": "Which database should the new service use?",
                 "options": [
                    ["label": "Postgres", "description": "Matches the other services"],
                    ["label": "SQLite", "description": "Simplest to run locally"],
                 ]],
                ["header": "Notes", "question": "Anything else the agent should know?",
                 "options": [], "custom": true],
            ],
        ])
    }
    #endif

    func receivePermission(_ prompt: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let request = AgentPermissionRequest(json: prompt) else {
            reply(AgentPermissionRequest.decision(allow: false, input: [:], message: "Octet couldn't read this request."))
            return
        }
        if sessionAllows.contains(Self.allowKey(request)) {
            reply(AgentPermissionRequest.decision(allow: true, input: request.inputObject, message: nil))
            return
        }
        if pendingPermission == nil {
            pendingPermission = request
            permissionReply = reply
        } else {
            permissionQueue.append((request, reply))
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func denyAllPending(message: String) {
        permissionReply?(AgentPermissionRequest.decision(allow: false, input: [:], message: message))
        permissionQueue.forEach { $0.1(AgentPermissionRequest.decision(allow: false, input: [:], message: message)) }
        permissionQueue = []
        pendingPermission = nil
        permissionReply = nil
    }

    // MARK: - Process

    private func restart() {
        stopProcess()
        needsRestart = false
        startupError = nil
        if engine == .codex { startCodex(); return }
        if engine == .opencode { startOpenCode(); return }
        if engine == .pi { startPi(); return }
        if engine == .qwen { startQwen(); return }
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else {
            startupError = "octet-cli is missing from the app bundle."
            return
        }
        if permissionServer == nil {
            let server = PermissionSocketServer(path: NSTemporaryDirectory() + "octet-perm-\(id.prefix(8)).sock")
            do {
                try server.start { [weak self] prompt, reply in
                    MainActor.assumeIsolated { self?.receivePermission(prompt, reply: reply) }
                }
                permissionServer = server
            } catch {
                startupError = "Couldn't open the permission channel: \(error)"
                return
            }
        }
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--forward-subagent-text",
            "--model", model, "--permission-mode", permissionMode.rawValue,
            "--mcp-config", PermissionMCP.mcpConfig(cliPath: cli, socketPath: permissionServer!.path),
            "--permission-prompt-tool", PermissionMCP.qualifiedToolName,
        ]
        if let effort, Self.supportsEffort(model: model) { args += ["--effort", effort] }
        args += hasTurns ? ["--resume", sessionId] : ["--session-id", sessionId]

        // Through the login shell, so the agent sees the same PATH and
        // environment it gets in a terminal. GUI login shells do not always
        // source the file that adds ~/.local/bin, so use discovery's absolute
        // executable when it found one instead of relying on PATH again.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let claude = executable("claude")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "exec \(shellQuote(claude)) \"$@\"", "claude"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + text).suffix(2000))
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processEnded(status: status, process: finished) } }
        }
        do {
            try process.run()
            self.process = process
            stdin = input.fileHandleForWriting
            // Claude Code's own list of what this session can run: built-ins,
            // plugins, skills and the person's commands, described.
            write(["type": "control_request", "request_id": Self.commandsRequest, "request": ["subtype": "initialize"]])
        } catch {
            startupError = "Couldn't start Claude Code: \(error.localizedDescription)"
        }
    }

    /// Pi's documented RPC mode stays alive for the conversation and emits
    /// one JSON event per line. Its session file is retained for reopening.
    private func startPi() {
        guard let process = spawn(command: "exec \(shellQuote(executable("pi"))) --mode rpc") else { return }
        self.process = process
        write(["type": "get_available_models"])
        write(["type": "get_commands"])
        if let threadId {
            write(["type": "switch_session", "sessionPath": threadId])
        } else {
            refreshPiState(includeMessages: false)
        }
    }

    private func refreshPiState(includeMessages: Bool) {
        write(["type": "get_state"])
        write(["type": "get_available_thinking_levels"])
        write(["type": "get_session_stats"])
        if includeMessages { write(["type": "get_messages"]) }
    }

    /// Applies picker changes to a live Pi process. Tracking the last state
    /// avoids resetting the model when only the thinking level moved.
    private func updatePiSettings() {
        guard !piApplyingState, process?.isRunning == true else { return }
        if model != piAppliedModel, let choice = PiModel.selection(model) {
            if write(["type": "set_model", "provider": choice.provider, "modelId": choice.modelId]) {
                piAppliedModel = model
            }
            return
        }
        if let effort, effort != piAppliedThinking,
           write(["type": "set_thinking_level", "level": effort]) {
            piAppliedThinking = effort
        }
    }

    /// Qwen's headless SDK transport uses the same stream-json event shapes
    /// as Claude Code, including partial message events.
    private func startQwen() {
        var args = ["qwen", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages"]
        if hasTurns, let threadId { args += ["--resume", threadId] }
        guard let process = spawn(command: "exec \(shellQuote(executable("qwen"))) \"$@\"", arguments: args) else { return }
        self.process = process
    }

    /// What Octet calls itself to the agents it drives.
    nonisolated static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    /// Codex's app server: one process per conversation, holding one thread.
    /// It asks for its own approvals inside its sandbox, so there's no
    /// permission channel to open the way Claude Code needs.
    private func startCodex() {
        guard let process = spawn(command: "exec \(shellQuote(executable("codex"))) app-server") else {
            startupError = "Couldn't start Codex."
            return
        }
        self.process = process
        nextRequestId = 0
        codexCalls = [:]
        let handshakeId = nextId()
        codexCalls[handshakeId] = .handshake
        for message in CodexRPC.handshake(requestId: handshakeId) { write(message) }
        CodexCatalogStore.shared.load()

        if let threadId {
            call("thread/resume", ["threadId": threadId], as: .thread)
            return
        }
        var params: [String: Any] = ["cwd": cwd]
        // A new thread starts on the settings the pickers show; an existing
        // one keeps its own, and `thread/settings/update` moves it.
        if let codexModel { params["model"] = codexModel }
        if let effort { params["reasoningEffort"] = effort }
        if let permissionProfile { params["permissions"] = permissionProfile }
        #if DEBUG
        // Verification hook: OCTET_CODEX_APPROVAL=untrusted makes Codex ask
        // before every command, to exercise the approval card.
        if let policy = ProcessInfo.processInfo.environment["OCTET_CODEX_APPROVAL"] { params["approvalPolicy"] = policy }
        #endif
        call("thread/start", params, as: .thread)
    }

    /// The model for a Codex thread: the one picked, or nothing, which lets
    /// Codex use its own default rather than Octet guessing at one.
    private var codexModel: String? {
        guard engine == .codex else { return nil }
        return CodexCatalogStore.shared.models.contains(where: { $0.id == model }) ? model : nil
    }

    /// Moves a running thread onto the current model, effort and sandbox.
    /// Needs the `experimentalApi` capability, which the handshake asks for.
    private func updateCodexSettings(threadId: String) {
        var params: [String: Any] = ["threadId": threadId]
        if let codexModel { params["model"] = codexModel }
        if let effort { params["reasoningEffort"] = effort }
        if let permissionProfile { params["permissions"] = permissionProfile }
        guard params.count > 1 else { return }
        call("thread/settings/update", params, as: .settings)
    }

    /// Starts `command` in a login shell with the three pipes wired up, so
    /// the agent sees the PATH and environment it gets in a terminal.
    private func spawn(command: String, arguments: [String] = []) -> Process? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + text).suffix(2000))
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processEnded(status: status, process: finished) } }
        }
        do {
            try process.run()
            stdin = input.fileHandleForWriting
            return process
        } catch {
            startupError = "Couldn't start \(engine.displayName): \(error.localizedDescription)"
            return nil
        }
    }

    /// Discovery searches installer-specific locations that a GUI login shell
    /// may not source (notably ~/.local/bin and versioned NVM bins).
    private func executable(_ agent: String) -> String {
        if let path = AgentDiscoveryStore.shared.agents.first(where: { $0.id == agent })?.executablePath {
            return path
        }
        let command = AgentHosts.executables[agent] ?? agent
        return AgentDiscovery.locate(command: command,
                                     in: AgentDiscovery.searchDirectories(shellPath: nil)) ?? command
    }

    private func stopProcess() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? stdin?.close()
        if process.isRunning { process.terminate() }
        self.process = nil
        stdin = nil
        lineBuffer = Data()
    }

    private func processEnded(status: Int32, process ended: Process) {
        guard ended === process else { return }
        self.process = nil
        stdin = nil
        if conversation.isRunning || status != 0 {
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = status == 127 || detail.contains("command not found")
                ? "\(engine.displayName) isn't installed, or isn't on your shell's PATH."
                : (detail.isEmpty ? "\(engine.displayName) exited (\(status))." : String(detail.suffix(400)))
            conversation.apply(["type": "result", "subtype": "error", "errors": [message]])
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            switch engine {
            case .claude:
                if event["type"] as? String == "control_response",
                   let response = event["response"] as? [String: Any], response["request_id"] as? String == Self.commandsRequest {
                    agentCommands = SlashCommands.claudePublished((response["response"] as? [String: Any])?["commands"] as? [[String: Any]] ?? [])
                    continue
                }
                conversation.apply(event)
                if event["type"] as? String == "rate_limit_event", !conversation.usageWindows.isEmpty {
                    AccountStore.shared.updateClaudeWindows(conversation.usageWindows)
                }
            case .codex:
                receiveCodex(event)
            case .opencode:
                break
            case .pi:
                receivePi(event)
            case .qwen:
                conversation.apply(event)
                if let id = conversation.sessionId, threadId != id {
                    threadId = id
                    AgentCenter.shared.save()
                }
            }
            if !conversation.isRunning { turnStartedAt = nil }
        }
    }

    private func receivePi(_ event: [String: Any]) {
        if let question = PiExtensionUI.question(event, sessionId: sessionId) {
            enqueueQuestion(question, answer: { [weak self] answers in
                self?.write(PiExtensionUI.response(event, answers: answers))
            }, reject: { [weak self] in
                self?.write(PiExtensionUI.cancel(event))
            })
            if let timeout = event["timeout"] as? Int, timeout > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000) { [weak self] in
                    self?.advanceQuestion(question.id)
                }
            }
            return
        }
        if event["type"] as? String == "extension_ui_request" {
            receivePiExtensionUI(event)
            return
        }
        if event["type"] as? String == "response", event["success"] as? Bool == true,
           let command = event["command"] as? String {
            let data = event["data"] as? [String: Any] ?? [:]
            switch command {
            case "get_state":
                if let path = data["sessionFile"] as? String, threadId != path {
                    threadId = path
                    AgentCenter.shared.save()
                }
                if let model = data["model"] as? [String: Any] {
                    applyPiModel(model, thinking: data["thinkingLevel"] as? String)
                }
                if title == engine.displayName, let name = data["sessionName"] as? String, !name.isEmpty { title = name }
            case "get_available_models":
                piModels = (data["models"] as? [[String: Any]] ?? []).compactMap(PiModel.init)
            case "get_available_thinking_levels":
                let levels = data["levels"] as? [String] ?? []
                piThinkingLevels = levels.isEmpty ? ["off"] : levels
            case "set_model":
                applyPiModel(data, thinking: nil)
                write(["type": "get_state"])
                write(["type": "get_available_thinking_levels"])
            case "set_thinking_level":
                piAppliedThinking = effort
            case "switch_session":
                refreshPiState(includeMessages: true)
            case "get_messages":
                if conversation.items.isEmpty {
                    conversation.restorePi(data["messages"] as? [[String: Any]] ?? [])
                }
            case "get_commands":
                let commands = data["commands"] as? [[String: Any]] ?? []
                agentCommands = commands.compactMap { command in
                    guard let name = command["name"] as? String else { return nil }
                    return SlashCommand(name: name,
                                        summary: command["description"] as? String ?? "Pi command",
                                        argumentHint: command["argumentHint"] as? String ?? "")
                }
            case "get_session_stats":
                conversation.costUSD = data["cost"] as? Double ?? conversation.costUSD
                if let context = data["contextUsage"] as? [String: Any] {
                    conversation.contextUsed = context["tokens"] as? Int
                    conversation.contextWindow = context["contextWindow"] as? Int
                }
            default:
                break
            }
        }
        conversation.applyPi(event)
        if event["type"] as? String == "agent_settled" { write(["type": "get_session_stats"]) }
    }

    private func applyPiModel(_ json: [String: Any], thinking: String?) {
        guard let model = PiModel(json) else { return }
        piApplyingState = true
        piAppliedModel = model.id
        self.model = model.id
        conversation.model = model.modelId
        conversation.contextWindow = model.contextWindow > 0 ? model.contextWindow : conversation.contextWindow
        if let thinking {
            piAppliedThinking = thinking
            effort = thinking
        }
        piApplyingState = false
    }

    /// Pi extensions can use a handful of fire-and-forget UI calls in RPC
    /// mode. Surface each one in the native conversation instead of silently
    /// dropping extension feedback.
    private func receivePiExtensionUI(_ event: [String: Any]) {
        let method = event["method"] as? String ?? ""
        switch method {
        case "notify":
            let message = event["message"] as? String ?? "Pi notification"
            if event["notifyType"] as? String == "error" {
                ToastCenter.shared.fail(nil, message)
            } else {
                ToastCenter.shared.info(message)
            }
        case "setStatus":
            let key = event["statusKey"] as? String ?? "pi"
            if let text = event["statusText"] as? String, !text.isEmpty { piStatuses[key] = text }
            else { piStatuses[key] = nil }
            piStatusText = piStatuses.values.first
        case "setWidget":
            let key = event["widgetKey"] as? String ?? event["id"] as? String ?? UUID().uuidString
            piWidgets.removeAll { $0.id == key }
            if let lines = event["widgetLines"] as? [String], !lines.isEmpty {
                piWidgets.append(PiWidget(id: key, lines: lines,
                                          placement: event["widgetPlacement"] as? String ?? "aboveEditor"))
            }
        case "setTitle":
            if let value = event["title"] as? String, !value.isEmpty { title = value }
        case "set_editor_text":
            piEditorRequest = PiEditorRequest(id: event["id"] as? String ?? UUID().uuidString,
                                              text: event["text"] as? String ?? "")
        default:
            break
        }
    }

    /// One JSON-RPC message from the app server: a question it is waiting on,
    /// the answer to a call Octet made, or news about the thread. Its own
    /// requests carry ids of their own that can equal Octet's, so a message is
    /// a request when it has a method, and an answer only when it has none.
    private func receiveCodex(_ message: [String: Any]) {
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            answerCodexRequest(method, id: id, params: message["params"] as? [String: Any] ?? [:])
            return
        }
        if method == nil, let id = message["id"] as? Int, let kind = codexCalls.removeValue(forKey: id) {
            receiveCodexAnswer(kind, message)
            return
        }
        conversation.applyCodex(message)
        if method == "account/rateLimits/updated", !conversation.usageWindows.isEmpty {
            AccountStore.shared.updateCodexWindows(conversation.usageWindows)
        }
    }

    private func receiveCodexAnswer(_ kind: CodexCall, _ message: [String: Any]) {
        let error = (message["error"] as? [String: Any]).map { $0["message"] as? String ?? "unknown error" }
        switch kind {
        case .handshake:
            if let error { startupError = "Codex didn't accept Octet's connection: \(error)" }
        case .thread:
            if let error {
                startupError = "Codex couldn't open the conversation: \(error)"
                return
            }
            guard let thread = (message["result"] as? [String: Any])?["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { return }
            threadId = id
            AgentCenter.shared.save()
            // Anything typed while the thread was opening goes now, in order.
            let queued = queuedTurns
            queuedTurns = []
            for text in queued { startTurn(text, threadId: id) }
        case .turn:
            // A turn Codex refuses never starts, so nothing else would end it
            // and the composer would say "working" forever.
            if let error { conversation.applyCodex(["method": "turn/failed", "params": ["error": ["message": error]]]) }
        case .settings:
            // Changing a running thread rides on Codex's experimental API,
            // which a newer Codex may change; say so rather than pretend.
            if let error {
                notice("Codex didn't take the new settings mid-conversation (\(error)). They apply to conversations started from now.")
            }
        case .interrupt:
            break
        case .command(let name):
            if let error { notice("Codex couldn't run /\(name): \(error)") }
        }
    }

    /// A Codex prompt file's text with its arguments filled in: `$ARGUMENTS`
    /// takes them all, `$1`…`$9` one word each.
    func codexPrompt(_ command: SlashCommand, arguments: String) -> String? {
        let directory = command.origin == .project ? "\(cwd)/.codex/prompts" : NSHomeDirectory() + "/.codex/prompts"
        guard var text = try? String(contentsOfFile: "\(directory)/\(command.name).md", encoding: .utf8) else {
            notice("Couldn't read the prompt file for /\(command.name).")
            return nil
        }
        // Front matter describes the prompt; it isn't part of it.
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = arguments.split(separator: " ").map(String.init)
        for index in (1...9).reversed() {
            text = text.replacingOccurrences(of: "$\(index)", with: index <= words.count ? words[index - 1] : "")
        }
        return text.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
    }

    /// Runs one of Codex's own actions for a `/` command.
    func codexCommand(_ name: String, arguments: String) {
        guard let threadId else { return notice("Send a message first; Codex hasn't opened the conversation yet.") }
        switch name {
        case "compact":
            call("thread/compact/start", ["threadId": threadId], as: .command(name))
        case "review":
            // `/review main` compares with a branch; bare, the working tree.
            let target: [String: Any] = arguments.isEmpty ? ["type": "uncommittedChanges"] : ["type": "baseBranch", "branch": arguments]
            call("review/start", ["threadId": threadId, "target": target], as: .command(name))
        case "rename":
            title = arguments
            call("thread/name/set", ["threadId": threadId, "name": arguments], as: .command(name))
        default:
            break
        }
    }

    /// Runs the session actions Pi exposes over RPC.
    func piCommand(_ name: String, arguments: String) {
        guard engine == .pi else { return }
        switch name {
        case "compact":
            var request: [String: Any] = ["type": "compact"]
            if !arguments.isEmpty { request["customInstructions"] = arguments }
            write(request)
        case "rename":
            guard !arguments.isEmpty else { return }
            title = arguments
            write(["type": "set_session_name", "name": arguments])
        default:
            break
        }
    }

    /// A request Codex is waiting on. Every one is answered, or the turn
    /// would wait forever: approvals go to the permission card, and anything
    /// Octet has no way to ask yet is refused and said in the transcript.
    private func answerCodexRequest(_ method: String, id: Any, params: [String: Any]) {
        if method == "item/tool/requestUserInput",
           let question = CodexUserInput.question(params) {
            let ids = CodexUserInput.questionIds(params)
            enqueueQuestion(question, answer: { [weak self] answers in
                self?.write(["jsonrpc": "2.0", "id": id,
                             "result": CodexUserInput.response(questionIds: ids, answers: answers)])
            }, reject: { [weak self] in
                self?.write(["jsonrpc": "2.0", "id": id,
                             "result": CodexUserInput.response(questionIds: ids, answers: ids.map { _ in [] })])
            })
            return
        }
        guard CodexApproval.approvals.contains(method) else {
            write(["jsonrpc": "2.0", "id": id,
                   "error": ["code": -32601, "message": "Octet can't answer \(method) yet."]])
            notice(CodexApproval.unsupported(method))
            return
        }
        let offered = params["availableDecisions"] as? [Any] ?? []
        receivePermission(CodexApproval.prompt(method: method, params: params)) { [weak self] decision in
            let allow = decision["behavior"] as? String == "allow"
            self?.write(["jsonrpc": "2.0", "id": id,
                         "result": ["decision": CodexApproval.decision(allow: allow, offered: offered)]])
        }
    }

    func notice(_ text: String) {
        conversation.items.append(AgentItem(id: UUID().uuidString, kind: .notice(text)))
    }

    // MARK: - Background

    /// Hands the session to Claude Code's supervisor, which keeps running it
    /// in the background under the same id (`--bg --resume`). The agent
    /// view lists it from then on.
    func moveToBackground(completion: @escaping (Bool) -> Void) {
        // Codex has no supervisor to hand a thread to; its own board lists
        // every thread anyway, so there's nothing to move.
        guard engine == .claude, hasTurns else { completion(false); return }
        close()
        var arguments = ["claude", "--bg", "--resume", sessionId, "--model", model, "--permission-mode", permissionMode.rawValue]
        if let effort, Self.supportsEffort(model: model) { arguments += ["--effort", effort] }
        let cwd = self.cwd
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(arguments, in: cwd)
            DispatchQueue.main.async {
                if result.status != 0 {
                    ToastCenter.shared.fail(nil, "Couldn't move the conversation to the background", detail: result.output)
                }
                completion(result.status == 0)
            }
        }
    }

    // MARK: - Terminal hand-off

    /// How the agent's own interface reopens this conversation.
    private var resumeCommand: String {
        switch engine {
        case .claude: "claude --resume \(sessionId)"
        case .codex: threadId.map { "codex resume \($0)" } ?? "codex"
        case .opencode: threadId.map { "opencode --session \($0)" } ?? "opencode"
        case .pi: threadId.map { "pi --session \(shellQuote($0))" } ?? "pi"
        case .qwen: threadId.map { "qwen --resume \($0)" } ?? "qwen"
        }
    }

    /// Continues this conversation in the agent's own interface, in a new tab
    /// of the same workspace. The headless process stops first so two
    /// processes never write the same session.
    func openInTerminal(window: WindowContext) {
        // Before a first message there's nothing to resume: the agent starts
        // fresh there instead.
        let command = hasTurns ? resumeCommand : engine.agent
        close()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        window.applyLayout([
            "workspace_id": workspaceId,
            "tab_label": title,
            "root": [
                "type": "pane", "label": title, "cwd": cwd,
                "command": [shell, "-lic", "\(command); exec \(shell) -l"],
            ] as [String: Any],
        ], failure: "Couldn't open the conversation in a terminal")
    }
}

/// Every native conversation, by workspace, and which one is showing.
@MainActor
final class AgentCenter: ObservableObject {
    static let shared = AgentCenter()

    @Published private(set) var sessions: [AgentSession] = []
    enum Board { case claude, codex }

    /// What each workspace shows in place of its terminal: a conversation,
    /// or an agents board. A workspace is in one window at a time, so this is
    /// each window's too, and two windows never trade overlays.
    @Published private var activeIds: [String: String] = [:]
    @Published private var boards: [String: Board] = [:] {
        didSet {
            AgentsStore.shared.watching = boards.values.contains(.claude)
            CodexAgentsStore.shared.watching = boards.values.contains(.codex)
        }
    }

    func active(in workspaceId: String?) -> AgentSession? {
        guard let workspaceId, let id = activeIds[workspaceId] else { return nil }
        return sessions.first { $0.id == id && $0.workspaceId == workspaceId }
    }

    /// Shows `sessionId` in its own workspace, or nothing in `workspaceId`.
    func setActive(_ sessionId: String?, in workspaceId: String?) {
        if let sessionId, let session = sessions.first(where: { $0.id == sessionId }) {
            activeIds[session.workspaceId] = sessionId
            boards[session.workspaceId] = nil
        } else if let workspaceId {
            activeIds[workspaceId] = nil
        }
    }

    func board(in workspaceId: String?) -> Board? { workspaceId.flatMap { boards[$0] } }

    func setBoard(_ board: Board?, in workspaceId: String?) {
        guard let workspaceId else { return }
        boards[workspaceId] = board
        if board != nil { activeIds[workspaceId] = nil }
    }

    /// The workspace in the window in front, where a menu or button acts.
    private var frontWorkspace: String? { WindowRegistry.shared.key?.focusedWorkspace?.workspaceId }

    /// The conversation in front: the front window's, set by id wherever
    /// that conversation lives.
    var activeId: String? {
        get { frontWorkspace.flatMap { activeIds[$0] } }
        set { setActive(newValue, in: frontWorkspace) }
    }

    /// The front window's board.
    var board: Board? {
        get { board(in: frontWorkspace) }
        set { setBoard(newValue, in: frontWorkspace) }
    }

    /// The Claude board, kept as a flag for the places that toggle it.
    var showingBoard: Bool {
        get { board == .claude }
        set { board = newValue ? .claude : (board == .claude ? nil : board) }
    }

    /// Takes in a session made elsewhere (brought back from the background).
    func adopt(_ session: AgentSession) {
        sessions.append(session)
        setActive(session.id, in: session.workspaceId)
        save()
    }

    /// ← in an empty composer: the conversation goes to the background and
    /// the board comes up, as in Claude Code.
    func sendToBackground(_ session: AgentSession) {
        showingBoard = true
        guard session.conversation.items.contains(where: { if case .user = $0.kind { return true }; return false }) else { return }
        session.moveToBackground { moved in
            guard moved else { return }
            AgentCenter.shared.setActive(nil, in: session.workspaceId)
            AgentCenter.shared.sessions.removeAll { $0.id == session.id }
            AgentCenter.shared.showingBoard = true
            AgentCenter.shared.save()
            AgentsStore.shared.refresh()
        }
    }
    private static let savedKey = "octet.conversations.v1"
    private var restored = false

    /// Remembers open conversations by folder, so they reopen in the
    /// workspace for that folder on the next launch.
    func save() {
        guard restored else { return }
        // Only conversations that reached the agent have a log to reopen.
        let saved = sessions.map(\.saved).filter(\.hasTurns)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    /// Reopens last launch's conversations once the terminal's workspaces
    /// are known. Each goes to the workspace for its folder, or else the
    /// focused one.
    func restoreIfNeeded(workspaceFor: (String) -> String?, fallback: String?) {
        guard !restored else { return }
        restored = true
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode([AgentSession.Saved].self, from: data) else { return }
        for entry in saved {
            guard let workspaceId = workspaceFor(entry.cwd) ?? fallback else { continue }
            sessions.append(AgentSession.restore(entry, workspaceId: workspaceId))
        }
    }

    func sessions(in workspaceId: String?) -> [AgentSession] {
        sessions.filter { $0.workspaceId == workspaceId }
    }

    @discardableResult
    func newConversation(workspaceId: String, cwd: String, engine: AgentSession.Engine = .claude) -> AgentSession {
        let session = AgentSession(workspaceId: workspaceId, cwd: cwd, engine: engine)
        sessions.append(session)
        setActive(session.id, in: workspaceId)
        session.prewarm()
        save()
        return session
    }

    /// A conversation continuing a session an agent already has, by the id it
    /// reported: Claude Code's session, Codex's thread, or OpenCode's session.
    @discardableResult
    func resume(engine: AgentSession.Engine, sessionId: String, cwd: String, workspaceId: String,
                title: String? = nil) -> AgentSession {
        let saved = AgentSession.Saved(
            sessionId: engine == .claude ? sessionId : UUID().uuidString,
            cwd: cwd, title: title ?? engine.displayName, model: AgentSession.defaultModel, effort: nil,
            permissionMode: AgentSession.PermissionMode.auto.rawValue, hasTurns: true, engine: engine,
            threadId: engine == .claude ? nil : sessionId, permissionProfile: nil, agent: nil)
        let session = AgentSession.restore(saved, workspaceId: workspaceId)
        sessions.append(session)
        setActive(session.id, in: workspaceId)
        session.prewarm()
        save()
        return session
    }

    func close(_ session: AgentSession) {
        session.close()
        if activeIds[session.workspaceId] == session.id { activeIds[session.workspaceId] = nil }
        sessions.removeAll { $0.id == session.id }
        save()
    }
}
