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

    /// A model Claude Code can run. The list is the one Claude Code gives
    /// in its `initialize` answer, kept for next launch; until it has run
    /// once, a curated list stands in.
    struct Model: Identifiable {
        let id: String
        let family: String
        let version: String
        let detail: String
        /// The name Claude Code gives it, when it came from Claude Code.
        var name: String? = nil
        /// Its effort levels, when Claude Code said; nil falls back to the
        /// curated rules.
        var efforts: [String]? = nil
        var title: String { name ?? "\(family) \(version)" }
    }

    static var models: [Model] {
        guard !catalog.isEmpty else { return curatedModels }
        return catalog.map { Model(id: $0.id, family: "Claude Code", version: "", detail: $0.detail,
                                   name: $0.name, efforts: $0.efforts) }
    }

    private static let catalogKey = "octet.claude.models.v1"
    /// What Claude Code last said it offers.
    private(set) static var catalog: [ClaudeModelCatalog.Entry] = {
        guard let data = UserDefaults.standard.data(forKey: catalogKey) else { return [] }
        return (try? JSONDecoder().decode([ClaudeModelCatalog.Entry].self, from: data)) ?? []
    }()

    /// Keeps the list from an `initialize` answer, and redraws the pickers.
    static func updateCatalog(fromInitialize initialize: [String: Any]) {
        let entries = ClaudeModelCatalog.entries(fromInitialize: initialize)
        guard !entries.isEmpty, entries != catalog else { return }
        catalog = entries
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: catalogKey) }
        AgentCenter.shared.objectWillChange.send()
    }

    private static let curatedModels: [Model] = [
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
    /// effort setting at all. Claude Code's own list says which have one.
    static func defaultEffort(model: String) -> String? {
        if let levels = Self.model(model)?.efforts {
            guard !levels.isEmpty else { return nil }
            if model.hasSuffix("4-6") { return levels.contains("high") ? "high" : levels.last }
            return levels.contains("xhigh") ? "xhigh" : levels.last
        }
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
                // The turn that restarts carried work has had its chance;
                // whatever it started again now shows up on its own.
                if !conversation.isRunning, !carriedRuntimes.isEmpty { carriedRuntimes = [] }
            }
        }
    }
    /// Work the terminal process had running when this conversation took
    /// over from it, shown until the first turn here has started it again.
    @Published private(set) var carriedRuntimes: [HandoffRuntime] = []
    /// When the current CLI process started. Replayed history is older, so
    /// Runtime can tell calls this process made from ones it only read.
    private(set) var processStartedAt: Date?
    @Published var title: String {
        // The title bar and tab strip watch the center, not each session.
        didSet {
            guard title != oldValue else { return }
            AgentCenter.shared.objectWillChange.send()
            AgentCenter.shared.save()
        }
    }
    // Claude Code starts on these as flags and takes changes live over its
    // control channel; Codex's app server takes them live too.
    @Published var model: String { didSet { if model != oldValue { pickChanged() } } }
    @Published var effort: String? { didSet { if effort != oldValue { pickChanged() } } }

    /// The person's own model and effort while a model policy plugin has the
    /// conversation on others; nil while it's on theirs.
    @Published private(set) var policyHeld: ModelPolicy.Pick?
    /// The person picked a model while a policy had moved the conversation:
    /// theirs stands until the policy no longer calls for a switch.
    private(set) var policyOverridden = false
    /// What the policy was last asked about, so it's asked again only when
    /// the pick or the usage changed.
    var policyKey: String?
    private var applyingPolicy = false

    private func pickChanged() {
        if !applyingPolicy {
            if policyHeld != nil {
                policyHeld = nil
                policyOverridden = true
            }
            // A model policy weighs in on the new pick before the next turn.
            AgentCenter.shared.objectWillChange.send()
        }
        settingsChanged()
    }
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
            if process?.isRunning == true, claudeApplied != nil { updateClaudeSettings() } else { needsRestart = true }
        case .codex:
            if let threadId, process?.isRunning == true { updateCodexSettings(threadId: threadId) }
        case .opencode:
            // Model, variant and agent go with each message; permissions are
            // the session's, and change at once.
            updateOpenCodePermissions()
        case .pi:
            updatePiSettings()
        case .qwen:
            if process?.isRunning == true { updateQwenSettings() } else { needsRestart = true }
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
    /// Claude Code's session. A rewind moves the conversation onto a fork
    /// of it, leaving the original in Claude Code's history.
    private(set) var sessionId: String
    /// The session the next start forks from: Claude Code's session, or
    /// Codex's thread, Pi's session file or OpenCode's session; and for
    /// Claude Code, the assistant message it resumes at (nil: all of it).
    /// Claude Code keeps it until a message goes, since its fork is only
    /// written then; the others fork as they start.
    var forkFrom: (session: String, at: String?)?
    /// Control requests waiting on their answer, by request id.
    private var controlReplies: [String: ([String: Any]) -> Void] = [:]
    var hasTurns = false {
        didSet { if hasTurns != oldValue { AgentCenter.shared.save() } }
    }
    private var needsRestart = false
    /// What the running Claude Code was started on or last told, so a
    /// change sends only what differs.
    private var claudeApplied: (model: String, effort: String?, mode: PermissionMode)?
    static let settingsRequestPrefix = "octet-settings-"

    /// Moves a running Claude Code onto the picked model, effort and mode
    /// with control requests, instead of restarting it (seconds, and the
    /// conversation reloaded). One it refuses falls back to a restart.
    private func updateClaudeSettings() {
        guard var applied = claudeApplied else { needsRestart = true; return }
        if model != applied.model {
            sendClaudeSetting(["subtype": "set_model", "model": model])
            applied.model = model
        }
        if effort != applied.effort {
            if let effort, Self.supportsEffort(model: model) {
                sendClaudeSetting(["subtype": "apply_flag_settings", "settings": ["effortLevel": effort]])
            } else {
                // No control clears it back to the model's default.
                needsRestart = true
            }
            applied.effort = effort
        }
        if permissionMode != applied.mode {
            sendClaudeSetting(["subtype": "set_permission_mode", "mode": permissionMode.rawValue])
            applied.mode = permissionMode
        }
        claudeApplied = applied
    }

    /// Qwen takes model, effort and approval mode live, as control requests.
    private func updateQwenSettings() {
        if qwenModels.contains(where: { $0.id == model }) {
            sendClaudeSetting(["subtype": "set_model", "model": model])
        }
        if let effort, Self.qwenEfforts.contains(effort) {
            sendClaudeSetting(["subtype": "set_effort", "effort": effort])
        }
        sendClaudeSetting(["subtype": "set_permission_mode", "mode": Self.qwenMode(permissionMode)])
    }

    private func sendClaudeSetting(_ request: [String: Any]) {
        write(["type": "control_request", "request_id": Self.settingsRequestPrefix + UUID().uuidString, "request": request])
    }
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
    /// Qwen: the models its configured providers offer (`get_available_models`).
    @Published private(set) var qwenModels: [(id: String, label: String)] = []
    static let qwenModelsRequest = "octet-qwen-models"
    /// Qwen's names for Octet's permission modes: `auto-edit` for accept
    /// edits, `yolo` for bypass.
    static func qwenMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .default: "default"
        case .acceptEdits: "auto-edit"
        case .plan: "plan"
        case .auto: "auto"
        case .bypassPermissions: "yolo"
        }
    }
    nonisolated static let qwenEfforts = ["low", "medium", "high", "xhigh", "max"]
    @Published private(set) var piThinkingLevels: [String] = ["off"]
    @Published private(set) var piStatusText: String?
    @Published private(set) var piWidgets: [PiWidget] = []
    @Published private(set) var editorRequest: EditorRequest?
    private var piStatuses: [String: String] = [:]
    private var piApplyingState = false
    private var piAppliedModel: String?
    private var piAppliedThinking: String?

    struct PiWidget: Identifiable, Equatable {
        let id: String
        let lines: [String]
        let placement: String
    }

    struct EditorRequest: Identifiable, Equatable {
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
    private enum CodexCall { case handshake, thread, turn, settings, interrupt, command(String), steer(String, [[String: Any]]), mcpStatus }
    private var codexCalls: [Int: CodexCall] = [:]
    private var nextRequestId = 0
    /// Messages sent before the thread was open, in order.
    private var queuedTurns: [String] = []
    /// What each waiting message sends, with its images.
    private var queuedInputs: [String: [[String: Any]]] = [:]
    /// The Codex turn running now, which a message sent mid-turn steers.
    private var codexTurnId: String?

    /// Follow-ups waiting behind the current turn. The composer draws these
    /// beside questions and approvals instead of burying them in transcript.
    var queuedMessages: [AgentItem] { conversation.items.filter(\.queued) }

    /// The model a conversation starts on until one is picked: the one
    /// Claude Code recommends, once it has said.
    static var defaultModel: String { catalog.first?.id ?? "claude-sonnet-5" }

    /// `model` nil starts on `defaultModel`, read here rather than as a
    /// default argument, which is evaluated off the main actor.
    init(workspaceId: String, cwd: String, engine: Engine = .claude, model: String? = nil,
         permissionMode: PermissionMode = .auto, sessionId: String = UUID().uuidString, threadId: String? = nil) {
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.engine = engine
        self.model = model ?? Self.defaultModel
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
        /// A fork not yet made, made when it next starts.
        var forkFrom: String?
        var forkAt: String?
        /// The working tree as the conversation started, for its changes.
        var baseline: String?
        /// The person's pick while a model policy has it on another.
        var policyHeld: ModelPolicy.Pick?
        var policyOverridden: Bool?
    }

    var saved: Saved {
        Saved(sessionId: sessionId, cwd: cwd, title: title, model: model, effort: effort,
              permissionMode: permissionMode.rawValue, hasTurns: hasTurns, engine: engine, threadId: threadId,
              permissionProfile: permissionProfile, agent: agentName,
              forkFrom: forkFrom?.session, forkAt: forkFrom?.at, baseline: baselineCommit,
              policyHeld: policyHeld, policyOverridden: policyOverridden ? true : nil)
    }

    static func restore(_ saved: Saved, workspaceId: String, start: Bool = true) -> AgentSession {
        let engine = saved.engine ?? .claude
        let session = AgentSession(workspaceId: workspaceId, cwd: saved.cwd, engine: engine, model: saved.model,
                                   permissionMode: PermissionMode(rawValue: saved.permissionMode) ?? .default,
                                   sessionId: saved.sessionId, threadId: saved.threadId)
        session.effort = saved.effort
        session.permissionProfile = saved.permissionProfile
        session.agentName = saved.agent
        session.title = saved.title
        session.hasTurns = saved.hasTurns
        session.forkFrom = saved.forkFrom.map { ($0, saved.forkAt) }
        session.baselineCommit = saved.baseline
        session.policyHeld = saved.policyHeld
        session.policyOverridden = saved.policyOverridden == true
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
            if start, saved.hasTurns {
                session.startOpenCode()
                session.restoreOpenCodeTranscript()
            }
        case .pi, .qwen:
            if start { session.prewarm() }
        }
        return session
    }

    /// Starts a session that was restored without launching its transport.
    /// Used by the terminal-to-Octet handoff so its real UI can exist before
    /// the native process releases the underlying session.
    func startRestoredProcess() {
        prewarm()
        if engine == .opencode, hasTurns { restoreOpenCodeTranscript() }
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
    static let remoteControlRequest = "octet-remote-control"
    static let remoteControlCommand = SlashCommand(
        name: "remote-control",
        summary: "Continue this conversation from claude.ai or the Claude app (turns it on or off)",
        aliases: ["rc"], handling: .octet)

    /// Whether Remote Control is on or on its way.
    var remoteControlEngaged: Bool { remoteControl != .off && !remoteControl.isFailed }

    /// Remote Control: this conversation, open in claude.ai or the Claude
    /// app, which can send it messages. What they send shows up here too.
    enum RemoteControl: Equatable {
        case off
        case connecting
        /// Connected; the session's page on claude.ai.
        case on(URL?)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    @Published private(set) var remoteControl: RemoteControl = .off
    /// Whether this Claude Code can do Remote Control at all (the account
    /// and its organization allow it), from its `initialize` answer.
    @Published private(set) var remoteControlAvailable = false
    /// Asked for, by the person or their settings: a new process (a model
    /// change restarts it) turns it back on.
    private var wantsRemoteControl = false
    /// The remote session, so a new process rejoins it instead of the
    /// phone's page going dead and a new one appearing.
    private var bridgeSessionId: String?

    /// What `/` offers, from the agent wherever it publishes a list, plus the
    /// actions Octet carries out itself. Nothing here is a guess at what an
    /// agent's own interface shows.
    var slashCommands: [SlashCommand] {
        let commands: [SlashCommand]
        switch engine {
        case .opencode:
            commands = openCodeSlashCommands
        case .claude:
            // Headless Claude Code doesn't list its interactive-only
            // /remote-control; Octet carries it out with the same switch.
            commands = agentCommands + (remoteControlAvailable ? [Self.remoteControlCommand] : [])
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
            // Qwen lists what works headless in its init event.
            commands = agentCommands.isEmpty
                ? conversation.slashCommands.map { SlashCommand(name: $0, summary: "", handling: .agent) }
                : agentCommands
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
                return call.summary.isEmpty ? "Running \(call.displayName)" : "\(call.displayName) \(call.summary)"
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
        takeBaselineIfNeeded()
        let wasRunning = conversation.isRunning
        // Typed in full rather than picked from the menu, /remote-control
        // (and Claude Code's /rc) still switches it here.
        if engine == .claude, ["/remote-control", "/rc"].contains(trimmed), attachments.isEmpty {
            setRemoteControl(!remoteControlEngaged)
            return
        }
        // `/rename` renames the session in Claude Code and the tab here.
        if trimmed.hasPrefix("/rename ") {
            let name = trimmed.dropFirst("/rename ".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { title = name }
        }
        if engine == .opencode, ["/undo", "/redo"].contains(trimmed), attachments.isEmpty {
            // Carried out on the session, not sent to the model.
            if trimmed == "/undo" { undoOpenCode() } else { redoOpenCode() }
            return
        }
        if engine == .opencode {
            if !conversation.isRunning { turnStartedAt = Date() }
            conversation.appendUser(trimmed, images: attachments.map(\.data), queued: wasRunning)
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
        // The item shares the message's uuid, so a queued one can be
        // taken back from Claude Code by it.
        let messageId = UUID().uuidString.lowercased()
        conversation.appendUser(trimmed, images: attachments.map(\.data), queued: wasRunning, id: messageId)
        if trimmed == "/compact" {
            conversation.items.append(AgentItem(id: UUID().uuidString,
                                                kind: .notice("Compacting the conversation to free context…")))
        }
        if title == engine.displayName, !trimmed.hasPrefix("/") { title = String(trimmed.prefix(40)) }
        switch engine {
        case .claude, .qwen:
            var text = trimmed
            var attachments = attachments
            if engine == .qwen {
                // Qwen's command for it is /compress.
                if trimmed == "/compact" { text = "/compress" }
                // Qwen turns every non-text block into JSON text for the
                // model, so images go as files it reads by `@path` instead.
                if !attachments.isEmpty {
                    var environment = ProcessInfo.processInfo.environment
                    environment.merge(Self.accountEnvironment(cwd: cwd)) { $1 }
                    let images = attachments.map { (data: $0.data, fileExtension: $0.mediaType == "image/png" ? "png" : "jpg") }
                    if let paths = QwenImages.save(images, in: QwenImages.directory(environment: environment)) {
                        text = QwenImages.message(text, images: paths)
                    } else {
                        notice("Couldn't hand the images to Qwen; the text was sent.")
                    }
                    attachments = []
                }
            }
            let message: [String: Any] = [
                "type": "user", "uuid": messageId,
                "message": ["role": "user", "content": Self.content(text, attachments)],
                "parent_tool_use_id": NSNull(),
            ]
            if write(message) {
                hasTurns = true
                if forkFrom != nil {
                    forkFrom = nil
                    AgentCenter.shared.save()
                }
            }
        case .codex:
            let input = Self.codexInput(trimmed, attachments)
            // The thread may still be opening, and a turn needs its id.
            guard let threadId else { queuedTurns.append(trimmed); queuedInputs[trimmed] = input; return }
            // Mid-turn, it goes into the running turn, as Codex's own
            // composer does; a message sent between turns waits.
            if wasRunning, let turnId = codexTurnId {
                call("turn/steer", ["threadId": threadId, "input": input, "expectedTurnId": turnId], as: .steer(trimmed, input))
                if let index = conversation.items.firstIndex(where: { $0.id == messageId }) { conversation.items[index].queued = false }
                return
            }
            if wasRunning { queuedTurns.append(trimmed); queuedInputs[trimmed] = input; return }
            startTurn(trimmed, threadId: threadId, input: input)
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
        var message = message
        // Every message Octet sends carries a uuid, so its echo is known as
        // Octet's own and not drawn a second time.
        if engine == .claude, message["type"] as? String == "user" {
            let id = (message["uuid"] as? String ?? UUID().uuidString).lowercased()
            message["uuid"] = id
            conversation.sentUserIds.insert(id)
        }
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

    /// A Codex turn's input: images as data URLs, then the text.
    static func codexInput(_ text: String, _ attachments: [Attachment]) -> [[String: Any]] {
        let images: [[String: Any]] = attachments.map {
            ["type": "image", "url": "data:\($0.mediaType);base64,\($0.data.base64EncodedString())"]
        }
        return images + (text.isEmpty ? [] : [["type": "text", "text": text]])
    }

    private func startTurn(_ text: String, threadId: String, input: [[String: Any]]? = nil) {
        let input = input ?? queuedInputs.removeValue(forKey: text) ?? [["type": "text", "text": text]]
        var params: [String: Any] = ["threadId": threadId, "input": input]
        // Every turn carries the effort picked, so it holds even if a
        // settings update mid-conversation wasn't taken.
        if let effort { params["effort"] = effort }
        let sent = call("turn/start", params, as: .turn)
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
        case .claude:
            // Stops the turn and keeps the process; queued messages stay.
            write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
        case .qwen:
            // A signal ends Qwen's whole session; this stops only the turn.
            write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
        case .codex:
            guard let threadId else { return }
            call("turn/interrupt", ["threadId": threadId], as: .interrupt)
        case .opencode:
            break
        case .pi:
            write(["type": "abort"])
        }
    }

    /// Whether a message waiting behind the running turn can be taken back:
    /// Claude Code holds it by id, and Codex's wait in Octet.
    // MARK: - Rewind

    /// What rewinding to a message would do, from Claude Code's checkpoint.
    struct RewindPreview {
        /// Its file edits can be undone; else only the conversation rewinds.
        let canRestoreFiles: Bool
        let filesChanged: [String]
        let insertions: Int
        let deletions: Int
        /// Why files can't be restored, when they can't.
        let reason: String?
    }

    /// Whether the conversation can go back to before user message `item`.
    func canRewind(to item: AgentItem) -> Bool {
        guard !conversation.isRunning, !item.queued, case .user = item.kind else { return false }
        switch engine {
        case .claude: return process?.isRunning == true || hasTurns
        // Pi forks from an earlier message on the branch it's on.
        case .pi: return process?.isRunning == true && threadId != nil
        default: return false
        }
    }

    /// Asks Claude Code what rewinding to before `item` would change, without
    /// changing anything.
    func previewRewind(to item: AgentItem, then: @escaping (RewindPreview) -> Void) {
        if engine == .pi {
            return then(RewindPreview(canRestoreFiles: false, filesChanged: [], insertions: 0, deletions: 0,
                                      reason: "Pi doesn't keep checkpoints of files"))
        }
        guard process?.isRunning == true else {
            return then(RewindPreview(canRestoreFiles: false, filesChanged: [], insertions: 0, deletions: 0,
                                      reason: "Claude Code isn't running, so its file checkpoints aren't loaded."))
        }
        controlRequest(["subtype": "rewind_files", "user_message_id": item.id.lowercased(), "dry_run": true]) { response in
            let answer = response["response"] as? [String: Any] ?? [:]
            let can = answer["canRewind"] as? Bool == true
            then(RewindPreview(canRestoreFiles: can,
                               filesChanged: answer["filesChanged"] as? [String] ?? [],
                               insertions: answer["insertions"] as? Int ?? 0,
                               deletions: answer["deletions"] as? Int ?? 0,
                               reason: can ? nil : (answer["error"] as? String ?? response["error"] as? String)))
        }
    }

    /// Goes back to before user message `item`: its and later file edits
    /// undone when `restoreFiles`, and the conversation resumed from just
    /// before it on a fork of the session, with the message back in the
    /// composer to edit and send again.
    func rewind(to item: AgentItem, restoreFiles: Bool) {
        guard canRewind(to: item), case .user(let text) = item.kind else { return }
        if engine == .pi { return rewindPi(to: item, text: text) }
        let finish = { [weak self] in
            guard let self else { return }
            let anchor = self.conversation.resumeAnchor(before: item.id)
            self.conversation.truncate(from: item.id)
            self.stopProcess()
            let old = self.sessionId
            self.sessionId = UUID().uuidString.lowercased()
            if let anchor, self.hasTurns {
                self.forkFrom = (session: old, at: Optional(anchor))
            } else {
                // The first message: nothing before it to keep.
                self.hasTurns = false
            }
            self.needsRestart = true
            AgentCenter.shared.save()
            self.editorRequest = EditorRequest(id: UUID().uuidString, text: text)
        }
        guard restoreFiles, process?.isRunning == true else { return finish() }
        controlRequest(["subtype": "rewind_files", "user_message_id": item.id.lowercased()]) { response in
            if response["subtype"] as? String == "error" || (response["response"] as? [String: Any])?["canRewind"] as? Bool == false {
                let reason = (response["response"] as? [String: Any])?["error"] as? String ?? response["error"] as? String
                ToastCenter.shared.fail(nil, "Couldn't restore the files", detail: reason)
                return
            }
            finish()
        }
    }

    // MARK: - MCP servers

    /// What was last checked, else what the agent said as it started.
    @Published private(set) var checkedMCPServers: [MCPServerState]?
    var mcpServers: [MCPServerState]? { checkedMCPServers ?? conversation.mcpServers }
    private var mcpWaiters: [() -> Void] = []

    /// Whether the agent has MCP servers Octet can ask about.
    var hasMCP: Bool { engine != .pi }

    /// Asks the agent how its MCP servers are doing; `then` runs with the
    /// answer in `mcpServers`.
    func checkMCPServers(then: (() -> Void)? = nil) {
        if let then { mcpWaiters.append(then) }
        switch engine {
        case .claude where process?.isRunning == true:
            controlRequest(["subtype": "mcp_status"]) { [weak self] response in
                let servers = (response["response"] as? [String: Any])?["mcpServers"] as? [[String: Any]]
                self?.finishMCPCheck(servers.map(MCPServerState.list))
            }
        case .codex where process?.isRunning == true:
            if !call("mcpServerStatus/list", [:], as: .mcpStatus) { finishMCPCheck(nil) }
        case .opencode:
            OpenCodeServer.shared.request("GET", "mcp", directory: cwd) { [weak self] result in
                guard let self else { return }
                if case .success(let json) = result, let servers = json as? [String: Any] {
                    self.finishMCPCheck(MCPServerState.openCode(servers))
                } else {
                    self.finishMCPCheck(nil)
                }
            }
        default:
            // Qwen Code reports its servers only as it starts; nothing to ask.
            finishMCPCheck(nil)
        }
    }

    private func finishMCPCheck(_ servers: [MCPServerState]?) {
        if let servers { checkedMCPServers = servers }
        let waiters = mcpWaiters
        mcpWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: - Session changes

    /// The working tree as it was when the conversation's first message
    /// went, kept as a checkpoint commit: what it changed since is the diff
    /// against it, new files included.
    @Published private(set) var baselineCommit: String?
    private var takingBaseline = false

    private func takeBaselineIfNeeded() {
        guard baselineCommit == nil, !takingBaseline else { return }
        takingBaseline = true
        let directory = cwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let commit = Checkpoints.create(in: directory, label: "Octet: conversation start", force: true)?.commit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.takingBaseline = false
                    guard let commit else { return }  // Not a repository.
                    self.baselineCommit = commit
                    AgentCenter.shared.save()
                }
            }
        }
    }

    // MARK: - Fork

    /// Whether this conversation can go on in a second one: every agent but
    /// Qwen Code, once it has a session to fork.
    var canFork: Bool {
        guard hasTurns, !conversation.isRunning else { return false }
        switch engine {
        case .claude: return true
        case .codex, .pi, .opencode: return threadId != nil
        case .qwen: return false
        }
    }

    /// A new conversation in this workspace carrying this one's history, to
    /// try something else without losing this one. From `item` (Claude
    /// Code): only what came before that message, which is put in the new
    /// composer to edit.
    @discardableResult
    func fork(from item: AgentItem? = nil) -> AgentSession? {
        guard canFork else { return nil }
        let parent = engine == .claude ? sessionId : threadId ?? ""
        var transcript = conversation
        var anchor: String?
        var refill: String?
        if let item {
            guard engine == .claude, case .user(let text) = item.kind else { return nil }
            anchor = conversation.resumeAnchor(before: item.id)
            transcript.truncate(from: item.id)
            refill = text
        }
        let copy = AgentSession(workspaceId: workspaceId, cwd: cwd, engine: engine, model: model,
                                permissionMode: permissionMode, sessionId: UUID().uuidString.lowercased())
        copy.effort = effort
        copy.permissionProfile = permissionProfile
        copy.agentName = agentName
        copy.title = title.hasSuffix(" (fork)") ? title : title + " (fork)"
        copy.baselineCommit = baselineCommit
        transcript.isRunning = false
        copy.conversation = transcript
        if item != nil, anchor == nil {
            // Forked before the first message: a fresh session.
            copy.hasTurns = false
        } else {
            copy.hasTurns = true
            copy.forkFrom = (parent, anchor)
        }
        AgentCenter.shared.adopt(copy)
        copy.prewarm()
        if let refill { copy.editorRequest = EditorRequest(id: UUID().uuidString, text: refill) }
        return copy
    }

    /// Pi: forks the session from `item`, which Pi does by starting a new
    /// session file from the message before it; the original is kept.
    private func rewindPi(to item: AgentItem, text: String) {
        // Which of the branch's prompts it is, counted, since Octet's ids
        // for Pi's messages aren't Pi's.
        let prompts = conversation.items.filter { if case .user = $0.kind { return !$0.queued }; return false }
        let position = prompts.firstIndex { $0.id == item.id }
        piRequest(["type": "get_fork_messages"]) { [weak self] response in
            guard let self else { return }
            let messages = (response["data"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            let entry = position.flatMap { messages.indices.contains($0) && (messages[$0]["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) ? messages[$0] : nil }
                ?? messages.last { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let id = entry?["entryId"] as? String else {
                return ToastCenter.shared.fail(nil, "Couldn't rewind", detail: "Pi didn't find that message on this branch.")
            }
            self.piRequest(["type": "fork", "entryId": id]) { [weak self] response in
                guard let self else { return }
                let data = response["data"] as? [String: Any] ?? [:]
                guard response["success"] as? Bool == true, data["cancelled"] as? Bool != true else {
                    return ToastCenter.shared.fail(nil, "Couldn't rewind",
                                                   detail: response["error"] as? String ?? "An extension stopped the fork.")
                }
                self.editorRequest = EditorRequest(id: UUID().uuidString, text: data["text"] as? String ?? text)
                // The new session's messages, and its file, which get_state names.
                self.refreshPiState(includeMessages: true)
            }
        }
    }

    /// Pi's session as a tree of the prompts in it, every branch included.
    func piSessionTree(then: @escaping ([PiSessionTree.Line]) -> Void) {
        guard engine == .pi, process?.isRunning == true else { return then([]) }
        piRequest(["type": "get_tree"]) { response in
            let data = response["data"] as? [String: Any] ?? [:]
            then(PiSessionTree.outline(data["tree"] as? [[String: Any]] ?? [], leafId: data["leafId"] as? String))
        }
    }

    /// Sends a Pi command with an id and hands its response to `reply`.
    private func piRequest(_ command: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let id = "octet-reply-" + UUID().uuidString
        controlReplies[id] = reply
        var command = command
        command["id"] = id
        write(command)
    }

    /// Sends a control request to Claude Code or Qwen Code and hands its
    /// answer to `reply`.
    func controlRequest(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let id = "octet-reply-" + UUID().uuidString
        controlReplies[id] = reply
        write(["type": "control_request", "request_id": id, "request": request])
    }

    func canCancelQueued(_ item: AgentItem) -> Bool {
        item.queued && (engine == .claude || engine == .codex)
    }

    /// Takes a queued message back before the agent gets to it.
    func cancelQueued(_ item: AgentItem) {
        guard canCancelQueued(item), case .user(let text) = item.kind else { return }
        switch engine {
        case .claude:
            write(["type": "control_request", "request_id": UUID().uuidString,
                   "request": ["subtype": "cancel_async_message", "message_uuid": item.id]])
        case .codex:
            if let index = queuedTurns.firstIndex(of: text) { queuedTurns.remove(at: index) }
            if !queuedTurns.contains(text) { queuedInputs[text] = nil }
        default:
            return
        }
        conversation.items.removeAll { $0.id == item.id }
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
    /// Verification hook for the tab-scoped Runtime panel. It represents one
    /// live Claude Monitor without starting a real command or spending usage.
    func debugLoadMonitor() {
        title = "Watch preview server"
        conversation.appendUser("Watch the preview server until it reports ready.")
        conversation.apply(["type": "assistant", "message": ["id": "monitor-debug", "content": [[
            "type": "tool_use", "id": "monitor-debug-call", "name": "Monitor", "input": [
                "command": "npm run preview 2>&1 | grep --line-buffered Ready",
                "description": "Waiting for preview server to become ready",
                "timeout_ms": 300_000,
            ],
        ]]]])
        conversation.apply(["type": "user", "message": ["content": [[
            "type": "tool_result", "tool_use_id": "monitor-debug-call",
            "content": "Monitor started (task preview-test, expires in 5m unless the source ends first).",
        ]]]])
        conversation.apply(["type": "assistant", "message": ["id": "monitor-debug-reply", "content": [[
            "type": "text", "text": "The preview monitor is active. I’ll let you know as soon as it reports ready.",
        ]]]])
        conversation.apply(["type": "assistant", "message": ["id": "background-task-debug", "content": [[
            "type": "tool_use", "id": "background-task-debug-call", "name": "Bash", "input": [
                "command": "npm run preview",
                "description": "Preview server",
                "run_in_background": true,
            ],
        ]]]])
        conversation.apply(["type": "user", "message": ["content": [[
            "type": "tool_result", "tool_use_id": "background-task-debug-call",
            "content": "Command running in background with ID preview-server.",
        ]]]])
        conversation.apply(["type": "result", "subtype": "success"])
        conversation.apply(["type": "assistant", "message": ["id": "agent-debug", "content": [[
            "type": "tool_use", "id": "agent-debug-call", "name": "Agent", "input": [
                "description": "Checking the preview response",
                "prompt": "Open the local preview, verify the response, and report any console errors.",
                "subagent_type": "general-purpose",
            ],
        ]]]])
        conversation.apply(["type": "assistant", "parent_tool_use_id": "agent-debug-call",
                            "message": ["id": "child-agent-debug", "content": [[
            "type": "text", "text": "The preview responds. I’m delegating schema validation before I report back.",
        ], [
            "type": "tool_use", "id": "child-agent-debug-call", "name": "Agent", "input": [
                "description": "Inspecting the API response",
                "prompt": "Ask a focused helper to validate the response schema while you inspect the UI.",
                "subagent_type": "general-purpose",
            ],
        ]]]])
        conversation.apply(["type": "assistant", "parent_tool_use_id": "child-agent-debug-call",
                            "message": ["id": "grandchild-agent-debug", "content": [[
            "type": "text", "text": "I found the response payload and am checking its required fields now.",
        ], [
            "type": "tool_use", "id": "grandchild-agent-debug-call", "name": "Agent", "input": [
                "description": "Validating response fields",
                "prompt": "Check the returned JSON fields and report any missing values.",
                "subagent_type": "general-purpose",
            ],
        ]]]])
        conversation.apply(["type": "assistant", "parent_tool_use_id": "grandchild-agent-debug-call",
                            "message": ["id": "grandchild-work-debug", "content": [[
            "type": "tool_use", "id": "grandchild-bash-debug", "name": "Bash", "input": [
                "command": "curl -s http://127.0.0.1:4173/api/health | jq .",
            ],
        ]]]])
        conversation.isRunning = true
    }

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
        conversation.appendUser("Actually, just the settings tests, then open a PR.", queued: true)
        conversation.items.append(AgentItem(id: "compaction-debug", kind: .notice(
            "Compacting the conversation to free context…"
        )))
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
        guard let question = OpenCodeQuestion([
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
        ]) else { return }
        enqueueQuestion(question, answer: { _ in }, reject: {})
    }

    func debugShowError() {
        notice(#"Couldn't answer OpenCode: OpenCode answered 400: Expected a string starting with "que", got "debug-question" at ["requestID"]"#)
    }

    func debugLoadSuggestedCommands() {
        title = "Run the denied checks"
        conversation.items = [
            AgentItem(id: "debug-user", kind: .user("Run the release checks.")),
            AgentItem(id: "debug-answer", kind: .text(
                "The classifier denied execution, but these are the exact commands to run:\n\n! swift test\n! git status --short"
            )),
        ]
        conversation.isRunning = false
    }

    func debugLoadQueuedMessages() {
        title = "Finish the settings work"
        conversation.items = [
            AgentItem(id: "debug-answer", kind: .text("I’m applying the remaining changes now.")),
            AgentItem(id: "debug-queue-1", kind: .user("Run the focused tests next."), queued: true),
            AgentItem(id: "debug-queue-2", kind: .user("Then summarize what changed."), queued: true),
        ]
        conversation.isRunning = true
        turnStartedAt = Date().addingTimeInterval(-12)
    }
    #endif

    func receivePermission(_ prompt: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let question = ClaudeUserInput.question(prompt, sessionId: sessionId) {
            enqueueQuestion(question, answer: { answers in
                reply(ClaudeUserInput.decision(prompt, question: question, answers: answers))
            }, reject: {
                reply(AgentPermissionRequest.decision(
                    allow: false, input: prompt["input"] as? [String: Any] ?? [:],
                    message: "The user skipped this question in Octet."
                ))
            })
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
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

    // MARK: - Remote Control

    /// Turns Remote Control on or off for this conversation. On, it's
    /// listed in claude.ai and the Claude app, and what's sent from there
    /// arrives here as if typed here.
    func setRemoteControl(_ enabled: Bool) {
        guard engine == .claude else { return }
        wantsRemoteControl = enabled
        if enabled, needsRestart || process?.isRunning != true {
            // Starting the process asks for it once it's up.
            restart()
            return
        }
        requestRemoteControl(enabled)
    }

    private func requestRemoteControl(_ enabled: Bool) {
        var request: [String: Any] = ["subtype": "remote_control", "enabled": enabled]
        if enabled {
            request["name"] = title
            if let bridgeSessionId { request["reattach_session_id"] = bridgeSessionId }
        }
        remoteControl = enabled ? .connecting : .off
        if !enabled { bridgeSessionId = nil }
        write(["type": "control_request", "request_id": Self.remoteControlRequest, "request": request])
    }

    /// Claude Code says whether Remote Control is possible, and whether the
    /// person turned it on for every session in its own settings.
    private func remoteControlInitialized(_ initialize: [String: Any]) {
        remoteControlAvailable = initialize["remote_control_available"] as? Bool ?? false
        guard remoteControlAvailable, !wantsRemoteControl else { return }
        let everySession = initialize["remote_control_auto_enable"] as? Bool == true
        if everySession || SettingsStore.shared.values.claudeRemoteControl { setRemoteControl(true) }
    }

    private func remoteControlAnswered(_ response: [String: Any]) {
        guard response["subtype"] as? String == "success" else {
            wantsRemoteControl = false
            let error = response["error"] as? String ?? "Remote Control couldn't start"
            remoteControl = .failed(error)
            ToastCenter.shared.fail(nil, "Remote Control didn't start", detail: error)
            return
        }
        guard wantsRemoteControl else { remoteControl = .off; return }
        let answer = response["response"] as? [String: Any] ?? [:]
        bridgeSessionId = answer["bridge_session_id"] as? String ?? bridgeSessionId
        remoteControl = .on((answer["session_url"] as? String).flatMap(URL.init(string:)))
    }

    // MARK: - Process

    /// Whether the conversation can be moved to another folder: Claude
    /// Code's can, between turns, by copying its transcript into the new
    /// folder's project (`ConversationMove`). Codex, OpenCode, Pi and Qwen
    /// tie a thread to the folder it started in.
    var canMove: Bool { engine == .claude && hasTurns && !conversation.isRunning }

    /// Moves the conversation to `folder`: the same session, resumed there.
    /// The conversation shown is a new one in its place; this one is closed.
    /// Shown in `workspaceId` when given, else where it was.
    @discardableResult
    func move(to folder: String, workspaceId newWorkspaceId: String? = nil) -> Result<AgentSession, Error> {
        guard canMove else {
            return .failure(ConversationMove.Problem(message: "Only a Claude Code conversation that isn't mid-turn can be moved."))
        }
        let folder = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard folder != cwd else { return .failure(ConversationMove.Problem(message: "It's already in \(abbreviateHome(folder)).")) }
        guard let source = AgentConversation.findLog(sessionIds: [sessionId], cwd: cwd) else {
            return .failure(ConversationMove.Problem(message: "Couldn't find the conversation's transcript to move."))
        }
        let destination = ConversationMove.claudeDestination(sessionId: sessionId, folder: folder)
        do {
            try ConversationMove.copyClaudeTranscript(from: source, to: destination, folder: folder)
        } catch {
            return .failure(error)
        }
        let moved = AgentSession(workspaceId: newWorkspaceId ?? workspaceId, cwd: folder, engine: engine, model: model,
                                 permissionMode: permissionMode, sessionId: sessionId)
        moved.effort = effort
        moved.permissionProfile = permissionProfile
        moved.title = title
        var transcript = conversation
        transcript.cwd = folder
        transcript.isRunning = false
        moved.conversation = transcript
        moved.hasTurns = true
        moved.policyHeld = policyHeld
        // Its baseline was another folder's; changes count from here on.
        AgentCenter.shared.close(self)
        AgentCenter.shared.adopt(moved)
        moved.prewarm()
        return .success(moved)
    }

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
            // Echo each message as it's taken up, so ones sent over Remote
            // Control reach the conversation here.
            "--replay-user-messages",
        ]
        if let effort, Self.supportsEffort(model: model) { args += ["--effort", effort] }
        if let fork = forkFrom {
            // A new session under our id, carrying the old one's messages
            // up to the rewind point; the original stays as it was.
            args += ["--resume", fork.session, "--fork-session", "--session-id", sessionId]
            if let at = fork.at { args += ["--resume-session-at", at] }
        } else {
            args += hasTurns ? ["--resume", sessionId] : ["--session-id", sessionId]
        }
        claudeApplied = (model, effort, permissionMode)

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
        var environment = Self.accountEnvironment(cwd: cwd)
        // Checkpoints each message's file edits, so a rewind can undo them.
        environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
        process.environment = environment
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
            processStartedAt = Date()
            stdin = input.fileHandleForWriting
            // Claude Code's own list of what this session can run: built-ins,
            // plugins, skills and the person's commands, described.
            write(["type": "control_request", "request_id": Self.commandsRequest, "request": ["subtype": "initialize"]])
            if wantsRemoteControl { requestRemoteControl(true) }
        } catch {
            startupError = "Couldn't start Claude Code: \(error.localizedDescription)"
        }
    }

    /// Pi's documented RPC mode stays alive for the conversation and emits
    /// one JSON event per line. Its session file is retained for reopening.
    private func startPi() {
        var command = "exec \(shellQuote(executable("pi"))) --mode rpc"
        let fork = forkFrom
        // A new session file carrying the parent's; get_state names it.
        if let fork { command += " --fork \(shellQuote(fork.session))" }
        guard let process = spawn(command: command) else { return }
        self.process = process
        forkFrom = nil
        write(["type": "get_available_models"])
        write(["type": "get_commands"])
        if fork != nil {
            refreshPiState(includeMessages: true)
        } else if let threadId {
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
        var args = ["qwen", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
                    "--approval-mode", Self.qwenMode(permissionMode)]
        if hasTurns, let threadId { args += ["--resume", threadId] }
        guard let process = spawn(command: "exec \(shellQuote(executable("qwen"))) \"$@\"", arguments: args) else { return }
        self.process = process
        qwenPermissionIds = [:]
        write(Self.qwenInitialize)
        write(["type": "control_request", "request_id": Self.qwenModelsRequest, "request": ["subtype": "get_available_models"]])
        // Model and effort picked before it started go as it comes up.
        if qwenModels.contains(where: { $0.id == model }) || effort != nil { updateQwenSettings() }
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

        if let fork = forkFrom {
            // Its history carried into a thread of its own.
            forkFrom = nil
            call("thread/fork", ["threadId": fork.session], as: .thread)
            return
        }
        if let threadId {
            call("thread/resume", ["threadId": threadId], as: .thread)
            return
        }
        var params: [String: Any] = ["cwd": cwd]
        // A new thread starts on the settings the pickers show; an existing
        // one keeps its own, and `thread/settings/update` moves it.
        if let codexModel { params["model"] = codexModel }
        // thread/start has no effort field; it takes it as a config override.
        if let effort { params["config"] = ["model_reasoning_effort": effort] }
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
        if let effort { params["effort"] = effort }
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
        process.environment = Self.accountEnvironment(cwd: cwd)
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

    /// Octet's own environment, plus the account the folder uses, so a
    /// conversation here signs in as the project's account.
    nonisolated static func accountEnvironment(cwd: String) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(AccountProfiles.environment(for: cwd)) { _, account in account }
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
        // The remote session ends with the process; the next one rejoins it.
        if remoteControl != .off { remoteControl = wantsRemoteControl ? .connecting : .off }
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
            if event["type"] as? String == "control_response",
               let response = event["response"] as? [String: Any],
               let id = response["request_id"] as? String, let reply = controlReplies.removeValue(forKey: id) {
                reply(response)
                continue
            }
            switch engine {
            case .claude:
                if event["type"] as? String == "control_response",
                   let response = event["response"] as? [String: Any], response["request_id"] as? String == Self.commandsRequest {
                    let initialize = response["response"] as? [String: Any] ?? [:]
                    agentCommands = SlashCommands.claudePublished(initialize["commands"] as? [[String: Any]] ?? [])
                    Self.updateCatalog(fromInitialize: initialize)
                    remoteControlInitialized(initialize)
                    continue
                }
                if event["type"] as? String == "control_response",
                   let response = event["response"] as? [String: Any], response["request_id"] as? String == Self.remoteControlRequest {
                    remoteControlAnswered(response)
                    continue
                }
                if event["type"] as? String == "control_response",
                   let response = event["response"] as? [String: Any],
                   (response["request_id"] as? String)?.hasPrefix(Self.settingsRequestPrefix) == true {
                    // Refused live: the next message restarts it on the flags.
                    if response["subtype"] as? String == "error" { needsRestart = true }
                    continue
                }
                // The mode changed in Claude Code itself (a plan approved,
                // Remote Control): the picker follows, with nothing to send.
                if event["type"] as? String == "system", event["subtype"] as? String == "status",
                   let raw = event["permissionMode"] as? String, let mode = PermissionMode(rawValue: raw),
                   mode != permissionMode {
                    claudeApplied?.mode = mode
                    permissionMode = mode
                }
                conversation.apply(event)
                // A turn started from elsewhere (Remote Control) runs the clock too.
                if conversation.isRunning, turnStartedAt == nil { turnStartedAt = Date() }
                if event["type"] as? String == "rate_limit_event", !conversation.usageWindows.isEmpty {
                    AccountStore.shared.updateClaudeWindows(conversation.usageWindows)
                }
                // The stream reports a window's use only past a warning
                // threshold, so a finished turn is the moment to read again.
                if event["type"] as? String == "result" { AccountStore.shared.refreshSoon() }
            case .codex:
                receiveCodex(event)
            case .opencode:
                break
            case .pi:
                receivePi(event)
            case .qwen:
                if receiveQwenControl(event) { continue }
                conversation.apply(event)
                if let id = conversation.sessionId, threadId != id {
                    threadId = id
                    AgentCenter.shared.save()
                }
            }
            if !conversation.isRunning { turnStartedAt = nil }
        }
    }

    /// Qwen's control channel. Before a tool runs it asks the host
    /// (`can_use_tool`), which Octet answers with the same card as Claude's;
    /// it withdraws a question it stopped waiting for; and it answers
    /// Octet's own requests. True when `event` was one of these.
    private func receiveQwenControl(_ event: [String: Any]) -> Bool {
        switch event["type"] as? String {
        case "control_request":
            guard let id = event["request_id"] as? String, let request = event["request"] as? [String: Any] else { return true }
            guard request["subtype"] as? String == "can_use_tool" else {
                write(["type": "control_response", "response": [
                    "subtype": "error", "request_id": id,
                    "error": "Octet doesn't handle \(request["subtype"] as? String ?? "this") requests.",
                ]])
                return true
            }
            if let toolUse = request["tool_use_id"] as? String { qwenPermissionIds[id] = toolUse }
            receivePermission(request) { [weak self] decision in
                self?.qwenPermissionIds[id] = nil
                self?.write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": decision]])
            }
            return true
        case "control_cancel_request":
            if let id = event["request_id"] as? String, let toolUse = qwenPermissionIds.removeValue(forKey: id) {
                dropPermission(id: toolUse)
            }
            return true
        case "control_response":
            let response = event["response"] as? [String: Any] ?? [:]
            if response["request_id"] as? String == Self.qwenModelsRequest,
               let models = (response["response"] as? [String: Any])?["models"] as? [[String: Any]] {
                qwenModels = models.compactMap { model in
                    guard let id = model["id"] as? String else { return nil }
                    return (id, model["label"] as? String ?? id)
                }
            } else if (response["request_id"] as? String)?.hasPrefix(Self.settingsRequestPrefix) == true,
                      response["subtype"] as? String == "error" {
                let message = response["error"] as? String ?? (response["error"] as? [String: Any])?["message"] as? String ?? ""
                notice("Qwen didn't take that setting\(message.isEmpty ? "" : ": \(message)").")
            }
            return true
        default:
            return false
        }
    }

    /// Qwen's control requests Octet is waiting on an answer for, by
    /// request id: the tool call each asks about.
    private var qwenPermissionIds: [String: String] = [:]

    /// Qwen's handshake: the host answers tool approvals, and gets the
    /// longest Qwen allows to, since a person is the one answering.
    static let qwenInitialize: [String: Any] = [
        "type": "control_request", "request_id": "octet-init",
        "request": ["subtype": "initialize", "timeout": ["canUseTool": 600_000]],
    ]

    private func receivePi(_ event: [String: Any]) {
        if event["type"] as? String == "response", let id = event["id"] as? String,
           let reply = controlReplies.removeValue(forKey: id) {
            reply(event)
            return
        }
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
            case "prompt" where data["disposition"] as? String == "handled":
                // An extension command took the prompt: no run starts, so
                // nothing else would end the one Octet began showing.
                conversation.isRunning = conversation.activateNextQueuedMessage()
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
        if event["type"] as? String == "agent_settled" {
            conversation.isRunning = conversation.activateNextQueuedMessage()
            write(["type": "get_session_stats"])
        }
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
            editorRequest = EditorRequest(id: event["id"] as? String ?? UUID().uuidString,
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
        if method == "turn/started" {
            codexTurnId = ((message["params"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
        } else if method == "turn/completed" {
            codexTurnId = nil
        }
        conversation.applyCodex(message)
        if ["turn/completed", "turn/failed", "turn/aborted"].contains(method),
           let threadId, !queuedTurns.isEmpty {
            let next = queuedTurns.removeFirst()
            startTurn(next, threadId: threadId)
        }
        if method == "account/rateLimits/updated", !conversation.usageWindows.isEmpty {
            AccountStore.shared.updateCodexWindows(conversation.usageWindows)
        }
        if method == "turn/completed" { AccountStore.shared.refreshSoon() }
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
        case .steer(let text, let input):
            // The turn ended first, or Codex wouldn't take it: it goes as
            // the next turn instead.
            guard error != nil else { return }
            if let threadId, !conversation.isRunning {
                startTurn(text, threadId: threadId, input: input)
            } else {
                queuedTurns.append(text)
                queuedInputs[text] = input
            }
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
        case .mcpStatus:
            let result = message["result"] as? [String: Any] ?? [:]
            finishMCPCheck(error == nil ? MCPServerState.codex(result) : nil)
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
            conversation.items.append(AgentItem(id: UUID().uuidString,
                                                kind: .notice("Compacting the conversation to free context…")))
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
            conversation.items.append(AgentItem(id: UUID().uuidString,
                                                kind: .notice("Compacting the conversation to free context…")))
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

    // MARK: - Model policy

    /// The model and effort the person chose, whatever a policy has the
    /// conversation on now.
    var personalPick: ModelPolicy.Pick { policyHeld ?? ModelPolicy.Pick(model: model, effort: effort) }

    /// Moves the conversation onto what a model policy chose, or back onto
    /// the person's own pick, saying so in the conversation.
    func applyPolicy(_ target: ModelPolicy.Pick, message: String?, modelName: (String) -> String) {
        let pick = personalPick
        if target == pick {
            // The policy no longer calls for a switch.
            policyOverridden = false
        } else if policyOverridden {
            return
        }
        let current = ModelPolicy.Pick(model: model, effort: effort)
        guard target != current else { return }
        applyingPolicy = true
        model = target.model
        effort = target.effort
        applyingPolicy = false
        let name = modelName(target.model) + (target.effort.map { " · \($0) effort" } ?? "")
        if target == pick {
            policyHeld = nil
            notice("Back on \(name)" + (message.map { ": \($0)" } ?? ", the model you picked."))
        } else {
            policyHeld = pick
            notice("Switched to \(name)" + (message.map { ": \($0)" } ?? " to save usage.")
                   + " Picking a model yourself keeps it for this conversation.")
        }
        AgentCenter.shared.save()
    }

    /// Picks up after a terminal session moved here: its log may have grown
    /// while the terminal closed, and the work it had running is started
    /// again by a first turn the person doesn't have to type.
    func continueAfterHandoff(transcript: AgentConversation?, runtimes: [HandoffRuntime], turnInterrupted: Bool) {
        guard engine == .claude, !conversation.isRunning else { return }
        if let transcript, !transcript.items.isEmpty, transcript.items.count >= conversation.items.count {
            conversation.items = transcript.items
        }
        guard let prompt = AgentRuntimeHandoff.continuationPrompt(runtimes, turnInterrupted: turnInterrupted) else { return }
        if needsRestart || process?.isRunning != true { restart() }
        guard stdin != nil else { return }
        let carried = AgentRuntimeHandoff.summary(runtimes)
        notice(carried.isEmpty
               ? "Moved from the terminal. Continuing the turn that was in progress."
               : "Moved from the terminal. Restarting \(carried) it had running.")
        carriedRuntimes = runtimes
        turnStartedAt = Date()
        conversation.isRunning = true
        conversation.lastError = nil
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": prompt],
            "parent_tool_use_id": NSNull(),
        ]
        if !write(message) {
            conversation.isRunning = false
            carriedRuntimes = []
        }
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
    /// What takes the terminal's place: the agents hub. (Claude and Codex
    /// had boards of their own; the hub shows both.)
    enum Board { case all }

    /// What each workspace shows in place of its terminal: a conversation,
    /// or an agents board. A workspace is in one window at a time, so this is
    /// each window's too, and two windows never trade overlays.
    @Published private var activeIds: [String: String] = [:]
    @Published private var boards: [String: Board] = [:] {
        didSet {
            let open = !boards.isEmpty
            AgentsStore.shared.watching = open
            CodexAgentsStore.shared.watching = open
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

    /// The agents hub, kept as a flag for the places that toggle it.
    var showingBoard: Bool {
        get { board != nil }
        set { board = newValue ? .all : nil }
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
    func newConversation(workspaceId: String, cwd: String, engine: AgentSession.Engine = .claude,
                         start: Bool = true) -> AgentSession {
        let session = AgentSession(workspaceId: workspaceId, cwd: cwd, engine: engine)
        sessions.append(session)
        setActive(session.id, in: workspaceId)
        if start { session.prewarm() }
        save()
        return session
    }

    /// A conversation continuing a session an agent already has, by the id it
    /// reported: Claude Code's session, Codex's thread, or OpenCode's session.
    @discardableResult
    func resume(engine: AgentSession.Engine, sessionId: String, cwd: String, workspaceId: String,
                title: String? = nil, start: Bool = true) -> AgentSession {
        let saved = AgentSession.Saved(
            sessionId: engine == .claude ? sessionId : UUID().uuidString,
            cwd: cwd, title: title ?? engine.displayName, model: AgentSession.defaultModel, effort: nil,
            permissionMode: AgentSession.PermissionMode.auto.rawValue, hasTurns: true, engine: engine,
            threadId: engine == .claude ? nil : sessionId, permissionProfile: nil, agent: nil)
        let session = AgentSession.restore(saved, workspaceId: workspaceId, start: false)
        sessions.append(session)
        setActive(session.id, in: workspaceId)
        if start { session.startRestoredProcess() }
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
