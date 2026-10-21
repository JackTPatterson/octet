import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A native conversation with Claude Code or Codex, drawn in place of the
/// terminal: a streaming transcript, a permission sheet when the agent asks,
/// and a composer, with the model, effort and mode pickers Claude Code takes.
struct ConversationView: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var session: AgentSession
    let client: EngineClient
    @StateObject private var dropdowns = OctetDropdownState()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var enlarged: Data?
    @StateObject private var bridge = ConversationBridge()
    @StateObject private var questions = QuestionDraftModel()

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(session: session, client: client)
            Rectangle().fill(Theme.divider).frame(height: 1)
            Transcript(session: session, find: session.find, bridge: bridge)
                .overlay(alignment: .topTrailing) {
                    if session.find.isOpen {
                        TranscriptFindBar(find: session.find, items: session.conversation.items.filter(Transcript.isShown))
                            .padding(.top, 8)
                            .padding(.trailing, 20)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: session.find.isOpen)
            if session.conversation.isRunning && session.pendingPermission == nil && session.pendingQuestion == nil {
                WorkingLine(session: session)
            }
            // Interactive agent UI belongs to the input dock. Keeping it in
            // one clipped stack lets a new panel rise from behind the composer
            // instead of appearing as a detached card above it.
            VStack(spacing: 0) {
                ComposerQueueDrawer(session: session, bridge: bridge)
                WaitSuggestionBanner(session: session)
                CheckInSuggestionBanner(session: session)
                let suggestedCommands = AgentComposerSyntax.suggestedShellCommands(in: session.conversation.items)
                if !session.conversation.isRunning, !suggestedCommands.isEmpty {
                    SuggestedCommandsPanel(session: session, commands: suggestedCommands)
                }
                if let question = session.pendingQuestion, session.pendingPermission == nil {
                    QuestionBanner(session: session, model: questions, question: question)
                        .id(question.id)
                        .zIndex(0)
                        .transition(motion.animates(.approvals)
                            ? .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
                            : .identity)
                }
                if let request = session.pendingPermission {
                    PermissionBanner(session: session, request: request)
                        // Keyed by request, so each one rises in independently,
                        // including the next queued one after an answer.
                        .id(request.id)
                        .zIndex(0)
                        .transition(motion.animates(.approvals)
                            ? .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
                            : .identity)
                }
                if !session.piWidgets.isEmpty {
                    PiWidgets(widgets: session.piWidgets)
                }
                Composer(session: session, dropdowns: dropdowns, bridge: bridge, questions: questions)
                    .zIndex(1)
            }
            .clipped()
        }
        .onChange(of: session.pendingQuestion?.id, initial: true) { _, _ in questions.sync(session.pendingQuestion) }
        .animation(motion.animation(.approvals, .smooth(duration: 0.26)), value: session.pendingPermission?.id)
        .animation(motion.animation(.approvals, .smooth(duration: 0.26)), value: session.pendingQuestion?.id)
        .background(Theme.terminalBackground)
        .octetDropdownHost(dropdowns)
        .environment(\.openImage) { enlarged = $0 }
        .overlay {
            if let enlarged, let image = NSImage(data: enlarged) {
                ZStack {
                    Color.black.opacity(0.7).onTapGesture { self.enlarged = nil }
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                        .padding(40)
                        .onTapGesture { self.enlarged = nil }
                        .accessibilityLabel("Enlarged image. Click to close.")
                }
                .onExitCommand { self.enlarged = nil }
                .transition(.opacity)
            }
        }
        #if DEBUG
        .onAppear {
            guard let id = ConversationDebug.openDropdown else { return }
            if id == "permission" { session.debugShowPermission(); return }
            if id == "question" { session.debugShowQuestion(); return }
            if id == "error" { session.debugShowError(); return }
            if id == "sample" { session.debugLoadSample(); return }
            if id == "context" {
                session.conversation.contextUsed = 175_600
                session.conversation.contextWindow = 200_000
                session.conversation.lastTokens = TokenUsage(input: 46_100, cacheRead: 108_600, cacheWrite: 20_900)
            }
            if id == "everything" { session.debugLoadEverything(); return }
            if id == "commands" { session.debugLoadSuggestedCommands(); return }
            if id.hasPrefix("transcript") {
                session.debugLoadTranscriptFeatures()
                // Verification hook: the find bar over the sample, on a word it repeats.
                if id == "transcript-find" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        session.find.open()
                        session.find.query = ProcessInfo.processInfo.environment["OCTET_DEBUG_FIND"] ?? "the"
                    }
                }
                if id == "transcript-diff", let turn = TurnChanges.derive(session.conversation.items, cwd: session.cwd).first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        window.ui.openTurnDiff(directory: session.cwd, promptAt: turn.promptAt,
                                               nextPromptAt: turn.nextPromptAt, path: turn.files.first?.path)
                    }
                }
                return
            }
            if id == "queued" { session.debugLoadQueuedMessages(); return }
            if id == "monitor" || id == "monitor-detail" {
                session.debugLoadMonitor()
                window.ui.showSidePanel(.monitors)
                if id == "monitor-detail" {
                    // Let the Runtime panel ingest the fixture entries before
                    // opening one; an early one is correctly dropped as
                    // stale while its list is still empty.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        window.ui.runtimeExpandedEntryIDs.insert("agent-agent-debug-call")
                    }
                }
                return
            }
            if id == "ultracode" { session.effort = "ultracode" }
            if id == "maxeffort" { session.effort = "max" }
            if id == "planmode" { session.permissionMode = .plan }
            let open = ["ultracode": "model", "maxeffort": "model", "planmode": "mode"][id] ?? id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dropdowns.openId = open }
        }
        #endif
    }
}

#if DEBUG
enum ConversationDebug {
    @MainActor static var openDropdown: String?
    /// Scroll the transcript to this item index once loaded.
    @MainActor static var scrollToItem: Int?
}
#endif

// MARK: - Header

private struct ConversationHeader: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var session: AgentSession
    let client: EngineClient
    @ObservedObject private var accounts = AccountStore.shared
    /// Read when a turn ends, not on every streamed word.
    @State private var verification: Verification = .noEdits

    var body: some View {
        let conversation = session.conversation
        HStack(spacing: 10) {
            ProjectLocation(directory: session.cwd, branch: branch, worktree: workspace?.worktree)
            Spacer(minLength: 8)
            if !conversation.isRunning, verification != .noEdits {
                VerificationBadge(verification: verification, compact: true)
            }
            // A subscription spends allowance, which the title bar chip shows
            // for the whole account; an API key spends money, which only this
            // conversation knows.
            if accounts.accounts["claude"]?.kind != .subscription, let cost = conversation.costUSD {
                Text(String(format: "$%.2f", cost))
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help("Cost so far at API prices")
            }
            // Once it's on, the chip under the composer shows it instead.
            if session.engine == .claude, session.remoteControlAvailable,
               session.remoteControl == .off || session.remoteControl.isFailed {
                RemoteControlButton(session: session)
            }
            OctetButton(title: "Open in Terminal", icon: "terminal", kind: .ghost, compact: true) {
                session.openInTerminal(window: window)
            }
            .disabled(conversation.items.isEmpty)
                .help("Continue this conversation in \(session.engine.displayName)'s own interface, in a new tab")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.chrome)
        .onChange(of: conversation.isRunning, initial: true) { _, running in
            if !running { verification = Verification.assess(session.conversation.items) }
        }
    }

    private var workspace: EngineWorkspace? {
        window.store.snapshot.workspaces.first { $0.workspaceId == session.workspaceId }
    }

    private var branch: String? {
        workspace?.worktree?.branch ?? window.store.branches[session.workspaceId]
    }
}

/// Turns on Remote Control: continue this conversation from claude.ai or
/// the Claude app, with what's sent there arriving here.
private struct RemoteControlButton: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        OctetButton(title: "Remote Control", icon: "remote", kind: .ghost, compact: true) {
            session.setRemoteControl(true)
        }
        .help("Continue this conversation from claude.ai or the Claude app. Messages sent there show up here.")
    }
}

/// The composer's Remote Control chip, while it's on: a light passes over
/// it, the way the conversation is live somewhere else too. Its menu opens
/// the session on claude.ai, copies the link, or turns it off.
private struct RemoteControlChip: View {
    @ObservedObject var session: AgentSession
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    var body: some View {
        let url: URL? = if case .on(let url) = session.remoteControl { url } else { nil }
        let connecting = session.remoteControl == .connecting
        Menu {
            if let url {
                Button("Open in claude.ai") { openURL(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    ClipboardWatcher.shared.acknowledge()
                    ToastCenter.shared.info("Copied the Remote Control link", detail: url.absoluteString)
                }
                Divider()
            }
            Button(connecting ? "Cancel" : "Turn Off Remote Control") { session.setRemoteControl(false) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(connecting ? Theme.textTertiary : RemoteGlimmer.tint)
                    .frame(width: 6, height: 6)
                Text(connecting ? "Connecting…" : "Remote")
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(connecting ? Theme.textSecondary : Theme.textPrimary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(connecting ? (hovered ? Theme.hover : Theme.card) : RemoteGlimmer.tint.opacity(hovered ? 0.2 : 0.14))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
                .strokeBorder(connecting ? Theme.border : RemoteGlimmer.tint.opacity(0.45), lineWidth: 1))
            .overlay { if !connecting { RemoteGlimmer(cornerRadius: Theme.rowRadius + 1) } }
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(connecting ? "Starting Remote Control" : "Remote Control is on: this conversation is open in claude.ai and the Claude app")
        .accessibilityLabel(connecting ? "Remote Control connecting" : "Remote Control on")
    }
}

/// The light that crosses a Remote Control chip once as it appears (a tab
/// shown, Remote Control turned on): the SSH chip's sweep, in green. Laid
/// over the chip; motion settings can turn it off.
struct RemoteGlimmer: View {
    static var tint: Color { Theme.success }
    var cornerRadius: CGFloat = 6
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, Self.tint.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.4)
                .offset(x: sweep * proxy.size.width)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
        .onAppear {
            guard motion.animates(.connections) else { return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.15)) { sweep = 1.1 }
        }
    }
}

private struct ProjectLocation: View {
    @Environment(\.openURL) private var openURL
    let directory: String
    let branch: String?
    let worktree: EngineWorktree?
    @State private var changes: WorkingTreeChanges?
    @State private var pullRequest: GitHubPullRequest?
    @State private var loadingPullRequest = false
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let pullRequestRefresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 4) {
                OctetIcon("folder", size: 11)
                Text(directory)
                    .font(Theme.monoFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textSecondary)
            .help(directory)
            if let label = sourceLabel {
                HStack(spacing: 4) {
                    OctetIcon(worktree == nil ? "arrow.triangle.branch" : "square.stack.3d.up", size: 10)
                    Text(label)
                        .font(Theme.captionFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Theme.success)
                .help(sourceHelp)
            }
            if let pullRequest {
                Button { openURL(pullRequest.url) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(pullRequestColor(pullRequest)).frame(width: 5, height: 5)
                        OctetIcon("arrow.triangle.pull", size: 10)
                        Text("#\(pullRequest.number)")
                            .font(Theme.captionFont.monospacedDigit())
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(pullRequest.title)\n\(pullRequest.statusText) · Open on GitHub")
                .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title)")
                .accessibilityValue(pullRequest.statusText)
            }
            if let changes, !changes.isEmpty {
                HStack(spacing: 5) {
                    Text("±")
                        .font(Theme.Text.transcriptMedium)
                        .foregroundStyle(Theme.textTertiary)
                    DiffStatLabel(added: changes.added, removed: changes.removed)
                }
                .font(Theme.captionFont.monospacedDigit())
                .help("Working tree changes")
            }
        }
        .layoutPriority(1)
        .onAppear {
            reloadChanges()
            reloadPullRequest()
        }
        .onChange(of: directory) { _, _ in
            changes = nil
            pullRequest = nil
            reloadChanges()
            reloadPullRequest()
        }
        .onReceive(refresh) { _ in reloadChanges() }
        .onReceive(pullRequestRefresh) { _ in reloadPullRequest() }
    }

    private var sourceLabel: String? {
        if let worktree {
            return worktree.branch ?? worktree.path.map { ($0 as NSString).lastPathComponent }
        }
        return branch
    }

    private var sourceHelp: String {
        if let worktree {
            return worktree.path.map { "Worktree at \($0)" } ?? "Worktree \(sourceLabel ?? "")"
        }
        return "Branch \(branch ?? "")"
    }

    private func reloadChanges() {
        let path = directory
        DispatchQueue.global(qos: .utility).async {
            let value = WorkingTreeChanges.read(in: path)
            DispatchQueue.main.async {
                guard path == directory, value != changes else { return }
                changes = value
            }
        }
    }

    private func reloadPullRequest() {
        guard !loadingPullRequest else { return }
        loadingPullRequest = true
        let path = directory
        DispatchQueue.global(qos: .utility).async {
            let result = LoginShell.run([
                "gh", "pr", "view", "--json",
                "number,title,state,url,isDraft,reviewDecision,statusCheckRollup",
            ], in: path)
            let value = result.status == 0 ? GitHubPullRequest.parse(Data(result.output.utf8)) : nil
            DispatchQueue.main.async {
                guard path == directory else { return }
                loadingPullRequest = false
                // A successful empty lookup means the branch has no PR. A
                // transient auth/network failure keeps the last useful chip.
                if result.status == 0 { pullRequest = value }
            }
        }
    }

    private func pullRequestColor(_ pullRequest: GitHubPullRequest) -> Color {
        if pullRequest.isDraft { return Theme.textTertiary }
        if pullRequest.reviewDecision == "CHANGES_REQUESTED" || pullRequest.checks == .failing {
            return Theme.danger
        }
        if pullRequest.checks == .pending { return Theme.accent }
        return Theme.success
    }
}

// MARK: - Message actions

/// What a message's right-click menu offers: copying it, and for your own
/// messages, editing and sending it again, going back to before it, or
/// forking from it; for the last reply, asking for it again.
private struct MessageMenu: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var bridge: ConversationBridge
    let item: AgentItem

    var body: some View {
        if let text = copyableText {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ClipboardWatcher.shared.acknowledge()
            }
        }
        if case .user = item.kind, session.canRewind(to: item) || (session.engine == .claude && session.canFork) {
            Divider()
            if MessageResend.canEdit(item, in: session) {
                Button("Edit and Resend…") { MessageResend.edit(item, in: session, bridge: bridge) }
                    .help("Put this message back in the box to change and send again, from where it was")
            }
            if session.canRewind(to: item) {
                Button("Rewind to Here…") { askToRewind() }
            }
            if session.engine == .claude, session.canFork {
                Button("Fork From Here") { session.fork(from: item) }
                    .help("A new conversation with what came before this message, which you can edit and send")
            }
        }
        if case .text = item.kind, MessageResend.canRegenerate(item, in: session) {
            Divider()
            Button("Regenerate Reply") { MessageResend.regenerate(in: session) }
        }
    }

    private var copyableText: String? {
        switch item.kind {
        case .user(let text), .text(let text): text.isEmpty ? nil : text
        default: nil
        }
    }

    /// Shows what a rewind would undo, from Claude Code's checkpoint, and
    /// rewinds when confirmed.
    private func askToRewind() {
        session.previewRewind(to: item) { preview in
            let files = preview.filesChanged.map { ($0 as NSString).lastPathComponent }
            let message: String
            if preview.canRestoreFiles, !files.isEmpty {
                message = "Undoes \(files.count == 1 ? "1 file's" : "\(files.count) files'") changes since then (+\(preview.insertions) −\(preview.deletions)) and goes back to before this message. It comes back in the box below to edit."
            } else if preview.canRestoreFiles {
                message = "No files changed since then. The conversation goes back to before this message, which comes back in the box below to edit."
            } else {
                message = "The conversation goes back to before this message, which comes back in the box below to edit. Files stay as they are: \(preview.reason ?? "there's no checkpoint for them")."
            }
            ConfirmCenter.shared.ask(title: "Rewind to before this message?", message: message, items: Array(files.prefix(8)),
                                     detail: "\(session.engine.displayName) keeps the conversation as it was in its history.",
                                     confirmTitle: "Rewind", destructive: true) { _ in
                session.rewind(to: item, restoreFiles: preview.canRestoreFiles)
            }
        }
    }
}

/// Sending an earlier message again: edited, from where it was, or the
/// last one as it was, for a new reply. Claude Code only, whose rewind
/// resumes on a fork of the session at that message and can put files back
/// from its checkpoints; Pi's rewind reloads its history as it goes, which
/// a message sent at once would race.
@MainActor
enum MessageResend {
    static func canEdit(_ item: AgentItem, in session: AgentSession) -> Bool {
        session.engine == .claude && session.canRewind(to: item)
    }

    /// The prompt the last reply answered, when that reply is the latest
    /// thing in the conversation.
    static func lastPrompt(in session: AgentSession) -> AgentItem? {
        let items = session.conversation.items.filter { !$0.queued }
        guard let index = items.lastIndex(where: { if case .user = $0.kind { true } else { false } }) else { return nil }
        return items[index]
    }

    static func canRegenerate(_ item: AgentItem, in session: AgentSession) -> Bool {
        guard session.engine == .claude, !session.conversation.isRunning,
              let prompt = lastPrompt(in: session), session.canRewind(to: prompt),
              let reply = session.conversation.items.last(where: { if case .text = $0.kind { true } else { false } })
        else { return false }
        return reply.id == item.id
    }

    /// Puts the message in the composer, with the choice to put files back
    /// as they were when it was sent, where there's a checkpoint for that.
    static func edit(_ item: AgentItem, in session: AgentSession, bridge: ConversationBridge) {
        guard case .user(let text) = item.kind else { return }
        let attachments = item.images.compactMap { NSImage(data: $0) }.compactMap(AgentSession.Attachment.init(image:))
        session.previewRewind(to: item) { preview in
            let files = preview.canRestoreFiles ? preview.filesChanged.count : 0
            bridge.draft = ConversationBridge.Draft(text: text, attachments: attachments,
                                                    purpose: .resend(itemId: item.id, revertFiles: files > 0),
                                                    revertableFiles: files)
        }
    }

    /// Sends `text` in place of user message `itemId`: the conversation
    /// goes back to before it (and its files too, when asked), then it goes.
    static func resend(_ itemId: String, text: String, attachments: [AgentSession.Attachment],
                       revertFiles: Bool, in session: AgentSession) {
        guard let item = session.conversation.items.first(where: { $0.id == itemId }), session.canRewind(to: item) else {
            ToastCenter.shared.fail(nil, "Couldn't send it from there", detail: "That message can't be gone back to any more.")
            return
        }
        session.rewind(to: item, restoreFiles: revertFiles, refill: false) {
            session.send(text, attachments: attachments)
        }
    }

    /// The last prompt again, for a new reply, its files put back first
    /// when Claude Code has a checkpoint for them.
    static func regenerate(in session: AgentSession) {
        guard let prompt = lastPrompt(in: session), case .user(let text) = prompt.kind else { return }
        let attachments = prompt.images.compactMap { NSImage(data: $0) }.compactMap(AgentSession.Attachment.init(image:))
        session.previewRewind(to: prompt) { preview in
            session.rewind(to: prompt, restoreFiles: preview.canRestoreFiles && !preview.filesChanged.isEmpty, refill: false) {
                session.send(text, attachments: attachments)
            }
        }
    }
}

// MARK: - Transcript

private struct Transcript: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var find: TranscriptFindState
    @ObservedObject var bridge: ConversationBridge
    @EnvironmentObject private var window: WindowContext
    @State private var atBottom: Bool
    /// The tool call whose whole output is open over the transcript.
    @State private var outputItem: String?
    @State private var changesCache = TurnChangesCache()
    /// The row at the top of the view, to come back to it.
    @State private var position: String?
    /// Folded runs of tool calls that have been opened, by row id.
    @State private var openRuns: Set<String> = []
    /// How many rows there were when the view left the end, for "Jump to
    /// Latest" to say how many came since.
    @State private var rowsWhenLeft: Int?

    /// Starts where it should on its very first layout: where you were
    /// reading, else the latest (`defaultScrollAnchor`). Scrolling there
    /// after it appears showed the wrong place for a moment first.
    init(session: AgentSession, find: TranscriptFindState, bridge: ConversationBridge) {
        _session = ObservedObject(wrappedValue: session)
        _find = ObservedObject(wrappedValue: find)
        _bridge = ObservedObject(wrappedValue: bridge)
        let saved = session.transcriptReadingAt.flatMap { id in
            let itemId = id.hasPrefix("run:") ? String(id.dropFirst(4)) : id
            return session.conversation.items.contains { $0.id == itemId } ? id : nil
        }
        _position = State(initialValue: saved)
        _atBottom = State(initialValue: saved == nil)
    }

    var body: some View {
        let items = session.conversation.items
        let running = session.conversation.isRunning
        let blocking = blockingState
        let shown = items.filter(Self.isShown)
        let rows = TranscriptTimeline.rows(shown)
        let byId = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let blocking {
                        AgentBlockingState(session: session, state: blocking)
                    } else if items.isEmpty {
                        EmptyConversation(session: session)
                    }
                    if blocking == nil {
                        let depths = Self.depths(items)
                        let turns = changesCache.turns(items, cwd: session.cwd, running: running, isShown: Self.isShown)
                        let lastId = shown.last?.id
                        let regenerable = Self.regenerableReply(session)
                        ForEach(rows) { row in
                            let first = row.itemIds.first ?? ""
                            let depth = depths[first] ?? 0
                            VStack(alignment: .leading, spacing: 12) {
                                Group {
                                    switch row {
                                    case .item(let id):
                                        if let item = byId[id] {
                                            if let report = session.usageReports[item.id] {
                                                UsageCard(report: report)
                                            } else {
                                                ItemRow(item: item, running: running, isLast: id == lastId,
                                                        thinkingDuration: Self.thinkingDuration(item, in: items),
                                                        canRegenerate: id == regenerable)
                                                    .equatable()
                                            }
                                        }
                                    case .toolRun(let ids):
                                        ToolRunRow(items: ids.compactMap { byId[$0] }, running: running,
                                                   expanded: Binding(get: { openRuns.contains(row.id) },
                                                                     set: { open in
                                                                         if open { openRuns.insert(row.id) } else { openRuns.remove(row.id) }
                                                                     }),
                                                   marks: { find.marks(for: $0) })
                                    }
                                }
                                .contextMenu {
                                    if case .item(let id) = row, let item = byId[id] {
                                        MessageMenu(session: session, bridge: bridge, item: item)
                                    }
                                }
                                // A subagent's work is indented under the call that
                                // started it, a rail per level, so a subagent's own
                                // subagents sit one step further in.
                                .padding(.leading, CGFloat(depth) * 18)
                                .overlay(alignment: .leading) {
                                    if depth > 0 {
                                        HStack(spacing: 16) {
                                            ForEach(0..<depth, id: \.self) { _ in
                                                Rectangle().fill(Theme.border).frame(width: 2)
                                            }
                                        }
                                        .padding(.leading, 6)
                                    }
                                }
                                // The files the turn edited, under its last item.
                                if let changes = row.itemIds.lazy.compactMap({ turns[$0] }).first {
                                    TurnChangedFilesCard(changes: changes)
                                }
                            }
                            .environment(\.transcriptFindMarks, row.itemIds.count == 1 ? find.marks(for: first) : nil)
                            .id(row.id)
                        }
                    }
                    // Visible only when scrolled to the end.
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.leading, 20)
                .padding(.trailing, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .top)
            // Opens at the latest, not the first message.
            .defaultScrollAnchor(.bottom)
            .octetScrollIndicators()
            // Coming back to where you were reading: the position above
            // takes it there on first layout; this settles it once the lazy
            // rows above it have their real heights. Following the latest
            // needs nothing: the bottom anchor opens there.
            .onAppear {
                guard let saved = position else { return }
                DispatchQueue.main.async { proxy.scrollTo(saved, anchor: .top) }
            }
            .onChange(of: position) { _, id in
                session.transcriptReadingAt = atBottom ? nil : id
            }
            .onChange(of: atBottom) { _, bottom in
                if bottom { session.transcriptReadingAt = nil }
                rowsWhenLeft = bottom ? nil : rows.count
            }
            // Follow the stream only while at the end, so reading back isn't
            // yanked away; a button jumps to the latest instead.
            .onChange(of: items) { _, _ in
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Find in conversation: go to the current match, once what it
            // opens has taken its height. A match inside a folded run opens it.
            .onChange(of: find.scrollRequest) { _, _ in
                guard let match = find.current else { return }
                let row = rows.first { $0.itemIds.contains(match.itemId) }
                if let row, case .toolRun = row { openRuns.insert(row.id) }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row?.id ?? match.itemId, anchor: .center) }
                }
            }
            // ⌘↑ and ⌘↓ from the composer: the prompt before or after the
            // one at the top of the view.
            .onChange(of: bridge.jump) { _, jump in
                guard let jump, let target = Self.prompt(jump.direction, from: position, rows: rows, items: byId,
                                                         atBottom: atBottom) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .top) }
            }
            // The Runtime panel's "Jump to conversation": the call that
            // started a subagent or task, its folded run opened first.
            .onReceive(NotificationCenter.default.publisher(for: RuntimePanel.scrollToConversationItem)) { note in
                guard note.userInfo?["sessionId"] as? String == session.id,
                      let itemId = note.userInfo?["itemId"] as? String else { return }
                let row = rows.first { $0.itemIds.contains(itemId) }
                if let row, case .toolRun = row { openRuns.insert(row.id) }
                MotionPreferences.shared.perform(.agentStatus, .easeOut(duration: 0.2)) {
                    proxy.scrollTo(row?.id ?? itemId, anchor: .top)
                }
                // Inside a run the call has its own id once the run is open
                // and laid out: then go to it exactly.
                if let row, case .toolRun = row {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        MotionPreferences.shared.perform(.agentStatus, .easeOut(duration: 0.15)) {
                            proxy.scrollTo(itemId, anchor: .top)
                        }
                    }
                }
            }
            #if DEBUG
            .onAppear {
                guard let index = ConversationDebug.scrollToItem else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard !rows.isEmpty else { return }
                    proxy.scrollTo(rows[min(index, rows.count - 1)].id, anchor: .top)
                }
            }
            #endif
            .overlay(alignment: .trailing) {
                let marks = TranscriptPromptMark.marks(shown)
                if blocking == nil, marks.count > 1 {
                    TranscriptMinimap(marks: marks, current: Self.currentPrompt(position, rows: rows, items: byId)) { id in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 4)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom && !items.isEmpty {
                    let fresh = max(0, rows.count - (rowsWhenLeft ?? rows.count))
                    OctetButton(title: fresh > 0 ? "Jump to Latest · \(fresh) new" : "Jump to Latest",
                                icon: "arrow.down", kind: .secondary, compact: true) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.bottom, 10)
                    .accessibilityLabel(fresh > 0 ? "Jump to latest, \(fresh) new" : "Jump to latest")
                }
            }
        }
        .environment(\.transcriptActions, actions)
        .overlay {
            if let outputItem {
                TranscriptOutputPanel(session: session, itemId: outputItem) { self.outputItem = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: outputItem)
        #if DEBUG
        .onAppear {
            guard ConversationDebug.openDropdown == "transcript-output" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { outputItem = TranscriptDebug.outputItemId }
        }
        #endif
    }

    /// What rows can ask of the conversation they're in.
    private var actions: TranscriptActions {
        let session = session
        let window = window
        return TranscriptActions(
            cwd: session.cwd,
            quote: { passage, action in session.quoteInComposer(passage, action: action) },
            openTurnDiff: { turn, path in
                window.ui.openTurnDiff(directory: session.cwd, promptAt: turn.promptAt,
                                       nextPromptAt: turn.nextPromptAt, path: path)
            },
            openFile: { path in window.openFile(URL(fileURLWithPath: path)) },
            openOutput: { id in outputItem = id },
            runInTerminal: { command in
                guard window.store.snapshot.focusedPaneId != nil else {
                    ToastCenter.shared.info("No terminal to run it in", detail: "Open a terminal pane in this tab first.")
                    return
                }
                window.store.runInFocusedPane(command)
                // The pane may be behind this conversation: say where it went.
                ToastCenter.shared.info("Running in the terminal",
                                        detail: command.split(separator: "\n").first.map(String.init))
            },
            agentName: session.engine.displayName,
            regenerate: { MessageResend.regenerate(in: session) }
        )
    }

    /// The reply Regenerate is offered on, if any.
    static func regenerableReply(_ session: AgentSession) -> String? {
        guard let reply = session.conversation.items.last(where: { if case .text = $0.kind { true } else { false } }),
              MessageResend.canRegenerate(reply, in: session) else { return nil }
        return reply.id
    }

    /// How long a thinking block took, from the item after it.
    static func thinkingDuration(_ item: AgentItem, in items: [AgentItem]) -> TimeInterval? {
        guard case .thinking = item.kind, let index = items.firstIndex(where: { $0.id == item.id }),
              index + 1 < items.count else { return nil }
        return AgentElapsed.thinking(item, next: items[index + 1])
    }

    /// The prompt at or above the top of the view.
    static func currentPrompt(_ position: String?, rows: [TranscriptRow], items: [String: AgentItem]) -> String? {
        let top = position.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count - 1
        guard top >= 0 else { return nil }
        return rows[...min(top, rows.count - 1)].reversed().first { row in
            if case .item(let id) = row, case .user = items[id]?.kind { return true }
            return false
        }?.id
    }

    /// The prompt before or after the one at the top of the view.
    static func prompt(_ direction: ConversationBridge.Jump.Direction, from position: String?,
                       rows: [TranscriptRow], items: [String: AgentItem], atBottom: Bool) -> String? {
        let prompts = rows.indices.filter { index in
            if case .item(let id) = rows[index], case .user = items[id]?.kind { return true }
            return false
        }
        guard !prompts.isEmpty else { return nil }
        let top = atBottom ? rows.count : position.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        switch direction {
        case .previous: return prompts.last { $0 < top }.map { rows[$0].id } ?? rows[prompts[0]].id
        case .next: return prompts.first { $0 > top }.map { rows[$0].id }
        }
    }

    /// How deep each item sits: 0 for the conversation's own, 1 for a
    /// subagent's, 2 for that subagent's own subagent's, and so on, by
    /// following each item's parent call up.
    static func depths(_ items: [AgentItem]) -> [String: Int] {
        let parents = Dictionary(items.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var depths: [String: Int] = [:]
        for item in items where item.parent != nil {
            var depth = 0
            var parent = item.parent
            var seen = Set<String>()
            while let id = parent, seen.insert(id).inserted {
                depth += 1
                parent = parents[id] ?? nil
            }
            depths[item.id] = depth
        }
        return depths
    }

    /// The page that replaces the transcript when the agent can't go on:
    /// it isn't installed, or it stopped on a usage limit. Both come from
    /// what the session and the engine reported, not from reading the
    /// words of an error, and only while the conversation is stopped there.
    private var blockingState: AgentBlockState? {
        if case .notInstalled(let detail) = session.launchFailure {
            return AgentBlockState(title: "\(session.engine.displayName) isn’t installed", message: detail)
        }
        guard !session.conversation.isRunning, let limit = session.conversation.limitHit else { return nil }
        let words = limit.message.isEmpty ? (session.conversation.lastError ?? "") : limit.message
        let parts = AgentLimitText.parts(words)
        return AgentBlockState(title: "\(session.engine.displayName) usage limit reached",
                               message: parts.lines.joined(separator: "\n"),
                               actions: parts.actions.map { AgentBlockAction(title: $0.title, url: $0.url) },
                               resetAt: limit.resetsAt ?? AgentLimitText.resetDate(in: words), isLimit: true)
    }
}

extension Transcript {
    /// Thinking blocks arrive empty when the model keeps its reasoning to
    /// itself; there's nothing to expand.
    static func isShown(_ item: AgentItem) -> Bool {
        if item.queued { return false }
        if case .thinking(let text) = item.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }
}

private struct SuggestedCommandsPanel: View {
    @ObservedObject var session: AgentSession
    let commands: [String]
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            OctetPalettePanel {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        OctetIcon("terminal", size: 13).foregroundStyle(Theme.accent)
                        Text(commands.count == 1 ? "Run the suggested command?" : "Run the suggested commands?")
                            .font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        OctetButton(title: "Dismiss", kind: .ghost, compact: true) { dismissed = true }
                        OctetButton(title: "Run", kind: .primary, compact: true) { confirmRun() }
                    }
                    CodePanel(text: commands.map { "! \($0)" }.joined(separator: "\n"),
                              language: "shell", maxLines: 8)
                }
                .padding(12)
            }
            .onChange(of: commands) { _, _ in dismissed = false }
        }
    }

    private func confirmRun() {
        ConfirmCenter.shared.ask(
            title: commands.count == 1 ? "Run this command?" : "Run these commands?",
            message: session.engine == .opencode
                ? "The commands will run through OpenCode in \(abbreviateHome(session.cwd))."
                : "They run in \(abbreviateHome(session.cwd)), one after another, stopping at the first that fails; \(session.engine.displayName) sees the output with your next message.",
            detail: commands.joined(separator: "\n"),
            confirmTitle: "Run"
        ) { _ in
            dismissed = true
            if session.engine == .opencode {
                for command in commands { session.send("!" + command) }
            } else {
                session.send("!" + commands.joined(separator: " && "))
            }
        }
    }
}

/// Over the message field: that a line starting with `!` runs as a shell
/// command, what's running now (Esc stops it), and output still to go to
/// the agent with the next message.
private struct ShellModeStrip: View {
    @ObservedObject var session: AgentSession
    let typingCommand: Bool

    var body: some View {
        if typingCommand || session.shellRunning != nil || !session.shellRuns.isEmpty {
            HStack(spacing: 7) {
                OctetIcon("terminal", size: 12).foregroundStyle(Theme.accent)
                if let running = session.shellRunning {
                    LoadingLine(width: 14)
                    Text("Running `\(running)`").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Stop") { session.stopShell() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    Keycap(text: "esc")
                } else if typingCommand {
                    Text("Runs in \(abbreviateHome(session.cwd)); its output goes to \(session.engine.displayName) with your next message")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                } else {
                    let count = session.shellRuns.count
                    Text(count == 1 ? "1 command's output goes with your next message"
                                    : "\(count) commands' output goes with your next message")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Don't Send") { session.dropShellRuns() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
        }
    }
}

private struct EmptyConversation: View {
    @ObservedObject var session: AgentSession

    static func intro(_ session: AgentSession) -> String {
        let folder = abbreviateHome(session.cwd)
        switch session.engine {
        case .claude:
            return "Claude Code works in \(folder) with your usual settings, hooks and MCP servers. Tool calls that need permission ask you here."
        case .codex:
            return "Codex works in \(folder) with your usual config, and asks for what it needs inside its own sandbox."
        case .opencode:
            return "OpenCode works in \(folder) with your usual config, providers and agents. Pick any model you're signed in to; what needs permission asks you here."
        case .pi:
            return "Pi works in \(folder) through its native RPC session, with your configured model, tools, extensions and skills."
        case .qwen:
            return "Qwen Code works in \(folder) through its headless stream, with your usual config, tools and MCP servers."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New conversation")
                .font(Theme.Text.title3)
                .foregroundStyle(Theme.textPrimary)
            Text(Self.intro(session))
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = session.startupError {
                Text(error).font(Theme.uiFont).foregroundStyle(Theme.danger)
            }
        }
        .padding(.top, 24)
    }
}

private struct AgentBlockState {
    let title: String
    let message: String
    var actions: [AgentBlockAction] = []
    var resetAt: Date? = nil
    /// A usage or spend limit, which another agent or a later time can get past.
    var isLimit = false
}

private struct AgentBlockAction: Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

private struct AgentBlockingState: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var session: AgentSession
    let state: AgentBlockState

    var body: some View {
        VStack(spacing: 12) {
            if let brand = AgentBrand.forAgent(session.engine.agent) {
                AgentLogo(brand: brand, size: 48)
            }
            Text(state.title)
                .font(Theme.Text.title1)
                .foregroundStyle(Theme.textPrimary)
            Text(state.message)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let resetAt = state.resetAt {
                LimitCountdown(resetAt: resetAt)
            }
            if state.isLimit { limitWays(resetAt: state.resetAt) }
            if !state.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(state.actions) { action in
                        Link(destination: action.url) {
                            HStack(spacing: 5) {
                                Text(action.title)
                                OctetIcon("arrow.right", size: 12)
                            }
                            .font(Theme.uiFontMedium)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Theme.cardSelected)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

extension AgentBlockingState {
    /// What can be done instead of waiting: carry on in another agent, or
    /// have this one carry on by itself when the limit resets.
    @ViewBuilder
    fileprivate func limitWays(resetAt: Date?) -> some View {
        let others = ConversationHandoff.otherEngines(than: session)
        let canHandOff = ConversationHandoff.canHandOff(session)
        VStack(spacing: 8) {
            if canHandOff, !others.isEmpty {
                HStack(spacing: 8) {
                    ForEach(others, id: \.self) { engine in
                        OctetButton(title: "Continue in \(engine.displayName)", kind: .primary, compact: true) {
                            ConversationHandoff.continueConversation(session, in: engine, reason: .limit, store: window.store)
                        }
                        .help("Open a conversation in \(engine.displayName) here with a summary of the work so far")
                    }
                }
            }
            if let resetAt, resetAt > Date() {
                if let at = session.resumeAt {
                    HStack(spacing: 8) {
                        Text("Will continue at \(at.formatted(date: .omitted, time: .shortened))")
                            .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                        OctetButton(title: "Cancel", kind: .ghost, compact: true) { session.cancelResume() }
                    }
                } else {
                    OctetButton(title: "Continue when it resets", icon: "clock", kind: .secondary, compact: true) {
                        session.scheduleResume(afterReset: resetAt)
                    }
                    .help("Octet sends \u{201C}continue\u{201D} for you just after the limit resets. Octet has to be open.")
                }
            }
        }
    }
}

private struct LimitCountdown: View {
    let resetAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(at: context.date))
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        }
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func label(at now: Date) -> String {
        let remaining = max(0, Int(resetAt.timeIntervalSince(now)))
        guard remaining > 0 else { return "Available now" }
        let days = remaining / 86_400
        let hours = remaining % 86_400 / 3_600
        let minutes = remaining % 3_600 / 60
        let seconds = remaining % 60
        if days > 0 { return "Available in \(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "Available in \(hours)h \(minutes)m \(seconds)s" }
        return "Available in \(minutes)m \(seconds)s"
    }
}

/// Equatable so rows that didn't change skip re-rendering while the last
/// one streams.
struct ItemRow: View, Equatable {
    let item: AgentItem
    let running: Bool
    /// The last row shown: a reply still streaming, a thought still going.
    var isLast = false
    var thinkingDuration: TimeInterval?
    /// The last reply, which Regenerate can ask for again.
    var canRegenerate = false

    var body: some View {
        switch item.kind {
        case .user(let text):
            VStack(alignment: .leading, spacing: 8) {
                if item.queued {
                    HStack(spacing: 5) {
                        OctetIcon("clock", size: 11)
                        Text("Queued")
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.accent)
                }
                if item.remote {
                    HStack(spacing: 5) {
                        OctetIcon("remote", size: 11)
                        Text("Sent over Remote Control")
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                }
                if !item.images.isEmpty { ImageGallery(images: item.images) }
                if !text.isEmpty {
                    FoundText(text)
                        .font(Theme.Text.transcript)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: " + text + (item.images.isEmpty ? "" : ", \(item.images.count) \(item.images.count == 1 ? "image" : "images")"))
                // T3 Code's message bubble: right-aligned, 18pt round, no border.
                .padding(12)
                .background(item.queued ? Theme.accent.opacity(0.07) : Theme.card)
                .overlay {
                    if item.queued {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .text(let text):
            AssistantMessage(text: text, streaming: running && isLast, canRegenerate: canRegenerate)
        case .thinking(let text):
            ThinkingBlock(text: text, live: running && isLast, duration: thinkingDuration)
        case .tool(let call):
            ToolCard(call: call, running: running, itemId: item.id)
        case .notice(let text):
            switch item.noticeStyle {
            case .compacting, .compacted:
                CompactionNotice(complete: item.noticeStyle == .compacted, running: running)
            case .error:
                ErrorNotice(text: text)
            case .plain:
                FoundText(text)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Compaction is a conversation lifecycle event, not a low-priority log line.
/// Give it a stable place in the transcript while context is summarized.
private struct CompactionNotice: View {
    let complete: Bool
    let running: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.14))
                if !complete && running {
                    LoadingLine(width: 12)
                } else {
                    OctetIcon(complete ? "checkmark" : "arrow.counterclockwise.circle", size: 13)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(complete ? "Conversation compacted" : "Compacting conversation")
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text(complete ? "Earlier context was summarized and the conversation can continue."
                              : "Summarizing earlier context to make room for the next turn.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.card.opacity(0.65))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

/// Errors stay in the transcript, but read as a structured state rather than
/// a raw log line. The first clause is the action that failed; protocol and
/// server detail sits below it in selectable monospace text.
private struct ErrorNotice: View {
    let text: String

    var body: some View {
        let content = Self.parts(text)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Theme.danger)
                OctetIcon("xmark", size: 12)
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                if !content.detail.isEmpty {
                    Text(content.detail)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.danger.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.danger.opacity(0.38)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(text)")
    }

    static func parts(_ text: String) -> (title: String, detail: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = value.range(of: ": ") else { return (value, "") }
        let title = String(value[..<separator.lowerBound])
        var detail = String(value[separator.upperBound...])
        detail = detail.replacingOccurrences(of: #": (?=(Expected|Invalid|Missing|Unexpected)\b)"#,
                                             with: "\n", options: .regularExpression)
        detail = detail.replacingOccurrences(of: #"\s+at (\[[^\n]+\])$"#,
                                             with: "\nat $1", options: .regularExpression)
        return (title, detail)
    }
}

/// A published artifact: its title and description, and buttons to open
/// the page, copy its link, or preview the local file it came from.
private struct ArtifactPanel: View {
    let artifact: ArtifactCall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = artifact.title {
                Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            }
            if let detail = artifact.detail {
                Text(detail).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = artifact.url {
                Text(url.absoluteString)
                    .font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if let url = artifact.url {
                    OctetButton(title: "Open", icon: "safari", kind: .primary, compact: true) {
                        NSWorkspace.shared.open(url)
                    }
                    OctetButton(title: "Copy Link", kind: .secondary, compact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        ToastCenter.shared.info("Copied the artifact's link")
                    }
                }
                if let path = artifact.filePath, FileManager.default.fileExists(atPath: path) {
                    OctetButton(title: "Preview File", kind: .ghost, compact: true) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }
}

struct ToolCard: View {
    let call: AgentToolCall
    let running: Bool
    var itemId: String?
    @Environment(\.transcriptActions) private var actions
    @State private var startLine: Int?
    @State private var hovered = false

    var body: some View {
        let diff = call.diff
        // Edits show their diff straight away; other calls stay one line.
        let todos = call.todos
        let artifact = call.artifact
        let subtitle = todos.map { list in "\(list.filter { $0.state == .completed }.count) of \(list.count) done" }
            ?? artifact?.summary ?? call.summary
        Disclosure(title: call.displayName, subtitle: subtitle, tint: call.isError ? Theme.danger : Theme.textSecondary,
                   icon: call.iconName, logo: artifact == nil ? LanguageLogo(path: call.filePath) : nil,
                   highlightsShell: call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
                   initiallyOpen: diff != nil || todos != nil || !call.resultImages.isEmpty
                       || (artifact?.url != nil && !call.isError),
                   trailing: { status(diff) }) {
            VStack(alignment: .leading, spacing: 8) {
                if let artifact, !call.isError, artifact.url != nil || artifact.filePath != nil {
                    ArtifactPanel(artifact: artifact)
                }
                if let todos {
                    TodoList(todos: todos)
                } else if let diff {
                    DiffView(lines: diff, path: call.filePath, startLine: startLine)
                        .task(id: call.inputData) { startLine = await call.fileStartLine() }
                } else if !call.input.isEmpty {
                    CodePanel(text: call.input, language: "input", tint: Theme.textSecondary, maxLines: 10, highlights: false,
                              findField: TranscriptFind.toolInput)
                }
                if !call.resultImages.isEmpty {
                    ImageGallery(images: call.resultImages)
                }
                if call.result == nil, let live = call.liveOutput, !live.isEmpty {
                    CodePanel(text: live, language: "output", tint: Theme.textSecondary, maxLines: 14, highlights: false,
                              findField: TranscriptFind.toolOutput)
                }
                if let result = call.result, !result.isEmpty, todos == nil, diff == nil || call.isError {
                    CodePanel(text: result, language: call.isError ? "error" : "output",
                              tint: call.isError ? Theme.danger : Theme.textSecondary, maxLines: 14, highlights: false,
                              findField: TranscriptFind.toolOutput)
                }
                if let itemId, todos == nil, diff == nil || call.isError,
                   let output = call.result ?? call.liveOutput, !output.isEmpty {
                    // The whole output, searchable, after T3 Code's command output panel.
                    let count = output.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    OctetButton(title: count > 14 ? "Show All \(count) Lines" : "Open Output",
                                icon: "arrow.up.left.and.arrow.down.right", kind: .ghost, compact: true) {
                        actions.openOutput(itemId)
                    }
                    .help("Open the full output with search and copy")
                }
            }
        }
        // T3 Code's work log: a quiet line, no box, a fill under the pointer.
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover.opacity(0.6) : .clear))
        .onHover { hovered = $0 }
    }

    @ViewBuilder private func status(_ diff: [LineDiff.Line]?) -> some View {
        HStack(spacing: 6) {
            if let diff {
                Text(DiffView.summary(diff))
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if call.result == nil && running {
                LoadingLine(width: 14)
            } else if call.result == nil {
                // The conversation stopped with this call still out.
                Text("Interrupted").font(Theme.Text.caption).foregroundStyle(Theme.warning)
            } else if call.isError {
                OctetIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(Theme.danger)
            } else if call.result != nil {
                OctetIcon("checkmark", size: 13).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// A one-line header that expands to show detail.
struct Disclosure<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String = ""
    let tint: Color
    /// Names the kind of thing, before the title.
    var icon: String?
    /// Shown before the subtitle, e.g. the file's language.
    var logo: LanguageLogo?
    var highlightsShell = false
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @State private var open: Bool
    @Environment(\.transcriptFindMarks) private var marks

    init(title: String, subtitle: String = "", tint: Color, icon: String? = nil, logo: LanguageLogo? = nil,
         highlightsShell: Bool = false,
         initiallyOpen: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.icon = icon
        self.logo = logo
        self.highlightsShell = highlightsShell
        _open = State(initialValue: initiallyOpen)
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    OctetIcon("chevron.right", size: 11)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    if let icon { OctetIcon(icon, size: 14).foregroundStyle(Theme.textTertiary) }
                    Text(title).font(Theme.uiFontMedium).foregroundStyle(tint)
                    if let logo { logo }
                    if !subtitle.isEmpty {
                        if highlightsShell {
                            ShellHighlightedText(subtitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            FoundText(subtitle, field: TranscriptFind.toolSummary)
                                .font(Theme.monoFont)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    trailing()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) \(subtitle)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { content() }
        }
        // The current match is in what this hides: show it.
        .onChange(of: revealed) { _, now in if now { open = true } }
        .onAppear { if revealed { open = true } }
    }

    private var revealed: Bool {
        guard let field = marks?.current?.field else { return false }
        return field != TranscriptFind.toolSummary
    }
}

private struct ShellHighlightedText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View { highlighted.font(Theme.monoFont) }

    private var highlighted: Text {
        var rendered = Text("")
        var cursor = source.startIndex
        for span in ShellSyntax.spans(in: source) {
            if cursor < span.range.lowerBound {
                rendered = rendered + Text(String(source[cursor..<span.range.lowerBound]))
                    .foregroundStyle(Theme.textTertiary)
            }
            rendered = rendered + Text(String(source[span.range])).foregroundStyle(span.role.color(argument: Theme.textTertiary))
            cursor = span.range.upperBound
        }
        if cursor < source.endIndex {
            rendered = rendered + Text(String(source[cursor...])).foregroundStyle(Theme.textTertiary)
        }
        return rendered
    }
}

// MARK: - Listening

/// Over the message box while Space is held: what's been heard so far.
private struct ListeningIndicator: View {
    let heard: String
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Theme.danger)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(heard.isEmpty ? "Listening… let go of Space to type it" : heard)
                .font(Theme.Text.transcript)
                .foregroundStyle(heard.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(4)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .allowsHitTesting(false)
        .accessibilityLabel("Listening")
        .accessibilityValue(heard)
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    @ObservedObject var bridge: ConversationBridge
    @ObservedObject var questions: QuestionDraftModel
    @EnvironmentObject private var window: WindowContext
    @StateObject private var modifiers = ComposerModifierKeys()
    /// The @ query being looked up, while a mention is open, so an empty
    /// answer can say "No matching files".
    @State private var referenceQuery: String?
    /// The draft put aside while a queued or earlier message is edited here.
    @State private var setAside: (text: String, attachments: [AgentSession.Attachment])?
    /// Attached files went in as @ paths, for the note under the box.
    @State private var attachedPaths = false
    @State private var text = ""
    @State private var spaceHold = SpaceHold()
    @ObservedObject private var voice = VoiceInput.shared
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    @State private var attachments: [AgentSession.Attachment] = []
    @State private var referenceSuggestions: [AgentComposerSyntax.Reference] = []
    @State private var referenceTask: Task<Void, Never>?
    @ObservedObject private var motion = MotionPreferences.shared
    /// The commands on show, changed inside an animation so the list, the
    /// composer card around it and the transcript above all move together.
    @State private var shownSuggestions: [SlashCommandSearch.Result] = []
    /// Where ↑ and ↓ are in this project's sent prompts.
    @State private var historyCursor = ComposerHistoryCursor()
    /// The plan whose follow-up banner was closed.
    @State private var dismissedPlan: String?
    /// Refine was picked with nothing typed: the box asks for the changes.
    @State private var refiningPlan = false

    /// Hold Space to talk: a tap types, a hold listens until let go.
    private func holdSpace(_ press: KeyPress) -> KeyPress.Result {
        guard SettingsStore.shared.values.holdSpaceToTalk, press.modifiers.isEmpty || spaceHold.listening else { return .ignored }
        let action: SpaceHold.Action
        switch press.phase {
        case .down: action = spaceHold.down(at: Date(), text: text)
        case .repeat: action = spaceHold.repeated(at: Date())
        default: action = spaceHold.up()
        }
        switch action {
        case .type:
            return .ignored
        case .swallow:
            return .handled
        case .startListening(let restore):
            text = restore
            voice.start { problem in
                spaceHold.cancel()
                ToastCenter.shared.fail(nil, "Can't listen", detail: problem)
            }
            return .handled
        case .stopListening:
            voice.stop { said in text = SpaceHold.inserting(said, into: text) }
            return .handled
        }
    }

    private func attach(_ images: [NSImage]) {
        attachments += images.compactMap(AgentSession.Attachment.init(image:))
    }

    /// Files picked, dropped or pasted: images go along as images; any
    /// other file goes in the message as a path the agent can read, as
    /// Orca does, since none of the agents take arbitrary files inline.
    private func attach(files urls: [URL]) {
        var paths: [String] = []
        var failed: [String] = []
        for url in urls {
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                if let image = NSImage(contentsOf: url), let attachment = AgentSession.Attachment(image: image) {
                    attachments.append(attachment)
                } else {
                    failed.append(url.lastPathComponent)
                }
            } else {
                paths.append(AgentComposerSyntax.mentionPath(url.path, cwd: session.cwd))
            }
        }
        if !paths.isEmpty {
            let mentions = paths.map { "@" + $0 }.joined(separator: " ")
            text = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? text + mentions + " " : text + " " + mentions + " "
            attachedPaths = true
        }
        if !failed.isEmpty {
            ToastCenter.shared.fail(nil, "Couldn't attach \(failed.joined(separator: ", "))", detail: "The image couldn't be read.")
        }
    }

    /// The file picker, as a sheet on the window rather than a modal that
    /// blocks everything else.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Images go along with the message. Other files are added as paths the agent can read."
        panel.directoryURL = URL(fileURLWithPath: session.cwd)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            attach(files: panel.urls)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Commands matching a `/` at the start of the message, until a space,
    /// ranked as T3 Code ranks them.
    private var suggestions: [SlashCommandSearch.Result] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n"), dismissedFor != text else { return [] }
        return Array(SlashCommandSearch.search(String(text.dropFirst()), in: session.slashCommands).prefix(8))
    }

    /// ↑ and ↓ through this project's sent prompts, when the caret is where
    /// they can't move it (see `ComposerHistoryCursor`).
    private func walkHistory(_ direction: ComposerHistoryCursor.Direction) -> KeyPress.Result {
        let entries = PromptHistoryStore.shared.entries(for: session.cwd)
        guard let recalled = historyCursor.step(direction, entries: entries, text: text, caret: ComposerCaret.current()) else {
            return .ignored
        }
        text = recalled
        // A recalled `/command` shouldn't pop the command menu open.
        dismissedFor = recalled
        ComposerCaret.place(atStart: direction == .back)
        return .handled
    }

    /// The plan the last turn ended on, while still in plan mode.
    private var followUpPlan: ComposerPlanFollowUp.Plan? {
        guard session.pendingPermission == nil, session.pendingQuestion == nil else { return nil }
        let planMode = switch session.engine {
        case .claude: session.permissionMode == .plan
        case .opencode: session.agentName?.lowercased() == "plan"
        default: false
        }
        guard let plan = ComposerPlanFollowUp.latestPlan(in: session.conversation.items, planMode: planMode,
                                                         running: session.conversation.isRunning),
              plan.id != dismissedPlan else { return nil }
        return plan
    }

    private func implement(_ plan: ComposerPlanFollowUp.Plan) {
        dismissedPlan = plan.id
        refiningPlan = false
        // Out of plan mode, asking before edits, as Approve does.
        switch session.engine {
        case .claude: session.permissionMode = .default
        case .opencode: session.agentName = nil
        default: break
        }
        session.send(ComposerPlanFollowUp.implementationPrompt(plan))
    }

    private func refine(_ plan: ComposerPlanFollowUp.Plan) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refiningPlan = true
            focused = true
        } else {
            dismissedPlan = plan.id
            submit()
        }
    }

    /// What's left of the context window, when the agent has said.
    private var contextLeft: Int? {
        guard let window = session.conversation.contextWindow, let used = session.conversation.contextUsed else { return nil }
        return max(0, window - used)
    }

    private func refreshSuggestions() {
        let next = suggestions
        guard next != shownSuggestions else { return }
        // The same commands with new letters lit don't need to move.
        if next.map(\.id) == shownSuggestions.map(\.id) {
            shownSuggestions = next
            return
        }
        motion.perform(.palette, .smooth(duration: 0.22)) { shownSuggestions = next }
    }

    /// Where the caret is in the message, while the box has the keyboard.
    private var caret: Int? {
        guard focused, let view = ComposerCaret.textView else { return nil }
        return view.selectedRange().location
    }

    private func refreshReferences() {
        referenceTask?.cancel()
        guard let mention = AgentComposerSyntax.mention(in: text, caret: caret) else {
            referenceQuery = nil
            motion.perform(.palette, .smooth(duration: 0.22)) { referenceSuggestions = [] }
            return
        }
        let expected = text
        let cwd = session.cwd
        referenceTask = Task {
            // Avoid walking the project once per keystroke while someone is
            // typing quickly; only the settled @ query starts filesystem work.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                AgentComposerSyntax.references(in: cwd, matching: mention.query)
            }.value
            guard !Task.isCancelled, text == expected else { return }
            referenceQuery = mention.query
            motion.perform(.palette, .smooth(duration: 0.22)) {
                referenceSuggestions = matches
                highlighted = min(highlighted, max(0, matches.count - 1))
            }
        }
    }

    private func accept(_ reference: AgentComposerSyntax.Reference) {
        guard let mention = AgentComposerSyntax.mention(in: text, caret: caret) else { return }
        let insertion = "@" + reference.path + " "
        let start = text.utf16.distance(from: text.utf16.startIndex, to: mention.range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        text.replaceSubrange(mention.range, with: insertion)
        referenceSuggestions = []
        referenceQuery = nil
        highlighted = 0
        // The caret after what was put in, not at the end of the message.
        let location = start + insertion.utf16.count
        DispatchQueue.main.async { ComposerCaret.textView?.setSelectedRange(NSRange(location: location, length: 0)) }
    }

    private func accept(_ result: SlashCommandSearch.Result) {
        let command = result.command
        highlighted = 0
        // Picking one of Octet's or the terminal's commands runs it, as the
        // agent's own menu does; one that takes arguments waits for them.
        if command.handling != .agent, command.argumentHint.isEmpty, command.children.isEmpty {
            text = ""
            return run(command, arguments: "")
        }
        text = command.insertion + " "
    }

    /// A command Octet carries out itself: Claude's model, effort and fresh
    /// start, and Codex's actions and prompt files.
    private func run(_ command: SlashCommand, arguments: String) {
        // A Codex prompt file, expanded here as Codex's own interface does.
        if session.engine == .codex, command.origin == .user || command.origin == .project {
            if let prompt = session.codexPrompt(command, arguments: arguments) { session.send(prompt) }
            return
        }
        switch command.name {
        case "model":
            if !arguments.isEmpty, let match = modelMatching(arguments) { session.model = match } else { dropdowns.openId = "model" }
        case "usage": session.showUsage()
        case "effort": dropdowns.openId = "model"
        case "permissions": dropdowns.openId = "mode"
        case "new", "clear": window.newConversation(engine: session.engine)
        case "remote-control" where session.engine == .claude: session.setRemoteControl(!session.remoteControlEngaged)
        case "quit": AgentCenter.shared.close(session)
        case "rename" where arguments.isEmpty: text = "/rename "
        case "compact" where session.engine == .pi,
             "rename" where session.engine == .pi:
            session.piCommand(command.name, arguments: arguments)
        case "compact", "review", "rename": session.codexCommand(command.name, arguments: arguments)
        default:
            session.send("/" + command.name + (arguments.isEmpty ? "" : " " + arguments))
        }
    }

    /// A model named in `/model <name>`: its id, or one of Claude's families.
    private func modelMatching(_ name: String) -> String? {
        let needle = name.lowercased()
        switch session.engine {
        case .claude:
            return AgentSession.models.first {
                $0.id.lowercased() == needle || $0.family.lowercased() == needle || $0.title.lowercased() == needle
            }?.id
        case .codex:
            return CodexCatalogStore.shared.models.first { $0.id.lowercased() == needle }?.id
        case .pi:
            return session.piModels.first {
                $0.id.lowercased() == needle || $0.modelId.lowercased() == needle || $0.name.lowercased() == needle
            }?.id
        case .opencode, .qwen:
            return nil
        }
    }

    var body: some View {
        let running = session.conversation.isRunning
        let matches = shownSuggestions
        let references = referenceSuggestions
        let plan = followUpPlan
        let length = ComposerPromptLength.check(text, contextLeft: contextLeft)
        VStack(spacing: 8) {
            if let plan, !running {
                PlanFollowUpBanner(plan: plan,
                                   hasDraft: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   implement: { implement(plan) },
                                   refine: { refine(plan) },
                                   dismiss: { withAnimation(.easeOut(duration: 0.18)) { dismissedPlan = plan.id } })
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let editing = bridge.editing {
                EditingBanner(purpose: editing, revertableFiles: bridge.lastDraftRevertable,
                              running: running, engine: session.engine.displayName,
                              setRevert: { revert in
                                  if case .resend(let id, _) = editing { bridge.editing = .resend(itemId: id, revertFiles: revert) }
                              },
                              cancel: cancelEditing)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if !matches.isEmpty {
                SlashSuggestions(commands: matches,
                                 highlighted: min(highlighted, matches.count - 1),
                                 highlight: { highlighted = $0 }) { accept($0) }
                    // Grows up out of the message field, and folds back into it.
                    .transition(motion.animates(.palette)
                        ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                      removal: .opacity.combined(with: .offset(y: 4)))
                        : .identity)
            }
            if references.isEmpty, let query = referenceQuery, AgentComposerSyntax.mention(in: text, caret: caret) != nil {
                NoReferenceMatches(query: query)
            }
            if !references.isEmpty {
                ReferenceSuggestions(references: references,
                                     highlighted: min(highlighted, references.count - 1),
                                     highlight: { highlighted = $0 }) { accept($0) }
                    .transition(motion.animates(.palette)
                        ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                      removal: .opacity.combined(with: .offset(y: 4)))
                        : .identity)
            }
            if !attachments.isEmpty {
                AttachmentStrip(images: attachments.map(\.data)) { index in attachments.remove(at: index) }
            }
            if showsFileNote {
                Text("Files are added to your message as paths the agent can read.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ShellModeStrip(session: session, typingCommand: text.hasPrefix("!") && session.engine != .opencode)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder(plan: plan))
                        .font(Theme.Text.transcript)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(Theme.Text.transcript)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 22, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) {
                        if spaceHold.listening { ListeningIndicator(heard: voice.partial) }
                    }
                    .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                        holdSpace(press)
                    }
                    .onChange(of: focused) { _, isFocused in
                        // ⌘S stashes while the message box has the keyboard.
                        if isFocused {
                            ComposerStash.focus(session.id) {
                                ComposerStash.stash(text: $text, attachments: $attachments, project: session.cwd)
                            }
                        } else {
                            ComposerStash.blur(session.id)
                        }
                        // Space's release goes elsewhere once focus does.
                        guard !isFocused, spaceHold.listening else { return }
                        _ = spaceHold.up()
                        voice.stop { said in text = SpaceHold.inserting(said, into: text) }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        // An input method composing text (Japanese, Chinese,
                        // Korean, accents) takes Return to confirm it.
                        if ComposerCaret.textView?.hasMarkedText() == true { return .ignored }
                        // Return sends (or takes the highlighted command); Shift-Return adds a line.
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        let matches = suggestions
                        if !references.isEmpty {
                            accept(references[min(highlighted, references.count - 1)])
                        } else if !matches.isEmpty {
                            accept(matches[min(highlighted, matches.count - 1)])
                        } else {
                            submit(commandHeld: press.modifiers.contains(.command))
                        }
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { press in
                        // Shift-Tab cycles how the agent asks, as in Claude Code.
                        if press.modifiers.contains(.shift) { return cycleMode() ? .handled : .ignored }
                        let matches = suggestions
                        if !references.isEmpty {
                            accept(references[min(highlighted, references.count - 1)])
                        } else if !matches.isEmpty {
                            accept(matches[min(highlighted, matches.count - 1)])
                        } else {
                            // Tab cycles OpenCode's agents, as in its own interface.
                            return cycleOpenCodeAgent() ? .handled : .ignored
                        }
                        return .handled
                    }
                    .onKeyPress(phases: .down) { press in
                        // A question's options by number, while the box is empty.
                        guard text.isEmpty, press.modifiers.isDisjoint(with: [.command, .control, .option]),
                              session.pendingPermission == nil, session.pendingQuestion != nil,
                              let digit = Int(press.characters), (1...9).contains(digit) else { return .ignored }
                        return questions.pick(number: digit, session: session) ? .handled : .ignored
                    }
                    .onKeyPress(.leftArrow) {
                        // ← on an empty message opens the agents board and
                        // sends this conversation to the background.
                        guard text.isEmpty, attachments.isEmpty else { return .ignored }
                        AgentCenter.shared.sendToBackground(session)
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                        // ⌘↑ in an empty box: the prompt before, in the transcript.
                        if press.modifiers == .command, text.isEmpty {
                            bridge.jumpToPrompt(.previous)
                            return .handled
                        }
                        let count = referenceSuggestions.isEmpty ? suggestions.count : referenceSuggestions.count
                        guard count > 0 else {
                            // Earlier prompts, as a shell's history.
                            guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]) else { return .ignored }
                            return walkHistory(.back)
                        }
                        highlighted = (min(highlighted, count - 1) - 1 + count) % count
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                        if press.modifiers == .command, text.isEmpty {
                            bridge.jumpToPrompt(.next)
                            return .handled
                        }
                        let count = referenceSuggestions.isEmpty ? suggestions.count : referenceSuggestions.count
                        guard count > 0 else {
                            guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]) else { return .ignored }
                            return walkHistory(.forward)
                        }
                        highlighted = (min(highlighted, count - 1) + 1) % count
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty || !referenceSuggestions.isEmpty {
                            dismissedFor = text
                            referenceSuggestions = []
                            refreshSuggestions()
                            return .handled
                        }
                        if bridge.editing != nil {
                            cancelEditing()
                            return .handled
                        }
                        // A `!` command running stops first.
                        if session.shellRunning != nil {
                            session.stopShell()
                            return .handled
                        }
                        // What the agent is waiting on is answered no.
                        if session.pendingPermission != nil {
                            session.answerPermission(allow: false)
                            return .handled
                        }
                        if let question = session.pendingQuestion {
                            session.rejectQuestion(question)
                            return .handled
                        }
                        // As the hint says: Esc stops the turn, at once.
                        guard running else { return .ignored }
                        session.interrupt()
                        return .handled
                    }
                    .onChange(of: text) { _, _ in
                        highlighted = 0
                        refreshSuggestions()
                        refreshReferences()
                    }
                    .onChange(of: bridge.draft?.id) { _, _ in takeDraft() }
                    .onChange(of: session.editorRequest?.id) { _, _ in
                        guard let request = session.editorRequest else { return }
                        session.editorRequestTaken = request.id
                        text = request.applied(to: text)
                        focused = true
                    }
                    .onAppear {
                        guard let request = session.editorRequest, session.editorRequestTaken != request.id else { return }
                        session.editorRequestTaken = request.id
                        text = request.applied(to: text)
                        focused = true
                    }
                    .accessibilityLabel("Message \(session.engine.displayName)")
            }
            if length != .fine {
                PromptLengthNotice(verdict: length)
            }
            HStack(spacing: 6) {
                // Model, effort and permission mode are Claude Code's own
                // settings, passed as flags when Octet starts it. Codex reads
                // its config and runs its own approvals, so it shows none.
                if session.engine == .claude {
                OctetDropdown(spec: OctetDropdownSpec(
                    id: "model",
                    options: AgentSession.models.map {
                        OctetDropdownOption(id: $0.id, title: $0.title, detail: $0.detail, section: $0.family)
                    },
                    selected: session.model,
                    select: { session.model = $0 },
                    searchPlaceholder: "Search models…",
                    modelEffort: AgentSession.supportsEffort(model: session.model) ? $session.effort : nil,
                    modelEffortLevels: AgentSession.model(session.model)?.efforts ?? AgentSession.efforts,
                    modelDefaultEffort: AgentSession.defaultEffort(model: session.model),
                    modelAgent: session.engine.agent
                ), label: "Model", state: dropdowns)
                OctetDropdownAnchor(spec: OctetDropdownSpec(
                    id: "mode",
                    options: AgentSession.PermissionMode.allCases.map {
                        OctetDropdownOption(id: $0.rawValue, title: $0.title, detail: Self.modeDetail[$0],
                                           dangerous: $0 == .bypassPermissions,
                                           tint: $0 == .default ? nil : ModeStyle.color($0), glyph: ModeStyle.glyph($0))
                    },
                    selected: session.permissionMode.rawValue,
                    select: { choice in
                        let mode = AgentSession.PermissionMode(rawValue: choice) ?? .default
                        guard mode == .bypassPermissions, session.permissionMode != mode else {
                            session.permissionMode = mode
                            return
                        }
                        // Bypass runs every tool without asking: confirm first.
                        ConfirmCenter.shared.ask(
                            title: "Bypass all permission checks?",
                            message: "Claude will run commands, edit and delete files, and use every tool without asking you first, for the rest of this conversation. Use it only in a folder you can afford to lose changes in.",
                            confirmTitle: "Bypass Permissions",
                            destructive: true
                        ) { _ in session.permissionMode = .bypassPermissions }
                    }
                ), state: dropdowns) { open in
                    ModeChip(mode: session.permissionMode, open: open)
                }
                .accessibilityLabel("Permission mode")
                .accessibilityValue(session.permissionMode.title)
                .help("How Claude asks before using tools. Changes apply from the next message.")
                if session.remoteControlEngaged {
                    RemoteControlChip(session: session)
                }
                } else if session.engine == .codex {
                    CodexControls(session: session, dropdowns: dropdowns)
                } else if session.engine == .opencode {
                    OpenCodeControls(session: session, dropdowns: dropdowns)
                } else if session.engine == .pi {
                    PiControls(session: session, dropdowns: dropdowns)
                } else if session.engine == .qwen {
                    QwenControls(session: session, dropdowns: dropdowns)
                } else if let brand = AgentBrand.forAgent(session.engine.agent) {
                    HStack(spacing: 5) {
                        AgentLogo(brand: brand, size: 12)
                        Text("Using \(session.engine.displayName) settings")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                OctetIconButton(icon: "paperclip", help: "Attach files or images (or paste or drop them here)") { pickFiles() }
                ComposerStashControls(project: session.cwd, text: $text, attachments: $attachments, dropdowns: dropdowns)
                MCPProblemChip(session: session)
                Spacer()
                ContextWindowControl(session: session, dropdowns: dropdowns) {
                    window.newConversation(engine: session.engine)
                }
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                if running {
                    RoundComposerButton(kind: .stop) { session.interrupt() }
                        .keyboardShortcut(OctetShortcut.stopTurn.keyboardShortcut)
                        .help(OctetShortcut.stopTurn.keys.map { "Stop this turn (Esc or \($0))" } ?? "Stop this turn (Esc)")
                        .accessibilityLabel("Stop")
                }
                if !running || !empty {
                    let kind = sendKind(running: running)
                    RoundComposerButton(kind: kind) { submit(commandHeld: NSEvent.modifierFlags.contains(.command)) }
                        .disabled(empty)
                        .help(sendHelp(kind))
                        .accessibilityLabel(kind == .steer ? "Steer" : kind == .queue ? "Queue" : bridge.editing == nil ? "Send" : "Update")
                }
            }
        }
        // Flat and flush with the conversation's sides, as the rest of
        // Octet's chrome is: a strip with a divider above, not a card.
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .onAppear {
            #if DEBUG
            if ConversationDebug.openDropdown == "reference" {
                text = "@"
                refreshReferences()
            }
            ComposerDebugHooks.run(ConversationDebug.openDropdown, session: session, dropdowns: dropdowns) { text = $0 }
            #endif
            DispatchQueue.main.async { focused = true }
            modifiers.start()
            takeDraft()
        }
        .onDisappear {
            referenceTask?.cancel()
            ComposerStash.blur(session.id)
            modifiers.stop()
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.2)), value: plan?.id)
        .onPasteCommand(of: [.image, .fileURL]) { providers in _ = load(providers) }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in load(providers) }
    }

    /// A paste or drop: image data as an image, files by URL (images as
    /// images, anything else as a path). Says whether any of it could be
    /// taken; what fails to load is said, not dropped silently.
    private func load(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    DispatchQueue.main.async {
                        if let url { attach(files: [url]) } else { failedToLoad(error) }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, error in
                    DispatchQueue.main.async {
                        if let image = image as? NSImage { attach([image]) } else { failedToLoad(error) }
                    }
                }
            }
        }
        return accepted
    }

    private func failedToLoad(_ error: Error?) {
        ToastCenter.shared.fail(nil, "Couldn't attach that", detail: error?.localizedDescription ?? "It couldn't be read.")
    }

    /// Files were attached as paths: say what that means, until the
    /// message goes or the paths are gone from it.
    private var showsFileNote: Bool { attachedPaths && text.contains("@") }

    private func placeholder(plan: ComposerPlanFollowUp.Plan?) -> String {
        if session.pendingPermission == nil, let draft = questions.draft, session.pendingQuestion != nil {
            if !draft.item.custom { return "Pick an option above (1–\(min(9, draft.item.options.count)))" }
            return draft.item.options.isEmpty ? "Type your answer" : "Type your own answer, or press a number to pick"
        }
        if refiningPlan && plan != nil { return "What should change in the plan?" }
        if session.conversation.isRunning {
            return session.canSteer ? "Steer \(session.engine.displayName), or ⌘Return to queue"
                                    : "Queue a message for when \(session.engine.displayName) finishes"
        }
        return "Message \(session.engine.displayName), @ to mention files, ! to run a command"
    }

    /// The send button while a turn runs: steer where the engine can take
    /// it, ⌘ held flipping that to queue; queue where it can't.
    private func sendKind(running: Bool) -> RoundComposerButton.Kind {
        guard running, bridge.editing == nil else { return .send }
        guard session.canSteer else { return .queue }
        return modifiers.command ? .queue : .steer
    }

    private func sendHelp(_ kind: RoundComposerButton.Kind) -> String {
        switch kind {
        case .steer:
            return "Steer: send into the running turn now (Return). Hold ⌘ to queue it for after instead."
        case .queue:
            return session.canSteer
                ? "Queue for when this turn ends (⌘Return). Let go of ⌘ to steer instead."
                : "Queue for when this turn ends (Return). \(session.engine.displayName) can't take a message mid-turn."
        case .send:
            switch bridge.editing {
            case .editHeld: return "Update the queued message (Return)"
            case .resend: return "Send it again from there (Return)"
            case nil: return "Send (Return)"
            }
        case .stop:
            return "Stop"
        }
    }

    /// Takes a draft the queue or the transcript handed over, putting what
    /// was being typed aside until it's done.
    private func takeDraft() {
        guard let draft = bridge.draft else { return }
        if bridge.editing == nil { setAside = (text, attachments) }
        bridge.draft = nil
        bridge.lastDraftRevertable = draft.revertableFiles
        text = draft.text
        attachments = draft.attachments
        dismissedFor = draft.text
        bridge.editing = draft.purpose
        focused = true
    }

    private func cancelEditing() {
        bridge.editing = nil
        text = setAside?.text ?? ""
        attachments = setAside?.attachments ?? []
        setAside = nil
    }

    /// Shift-Tab: Claude's and Qwen's permission modes, and OpenCode's two
    /// asking presets (allowing everything is only ever picked, never cycled
    /// into). Codex's sandboxes aren't cycled. Says whether it did anything.
    private func cycleMode() -> Bool {
        switch session.engine {
        case .claude, .qwen:
            let cycle = ModeStyle.cycle
            let index = cycle.firstIndex(of: session.permissionMode) ?? -1
            session.permissionMode = cycle[(index + 1) % cycle.count]
            return true
        case .opencode:
            session.permissionProfile = session.permissionProfile == "ask" ? nil : "ask"
            return true
        case .codex, .pi:
            return false
        }
    }

    /// Tab: the next of OpenCode's agents, as its own interface does.
    private func cycleOpenCodeAgent() -> Bool {
        guard session.engine == .opencode else { return false }
        let agents = OpenCodeCatalogStore.shared.catalog(for: session.cwd).agents
        guard agents.count > 1 else { return false }
        let current = agents.firstIndex { $0.name == (session.agentName ?? agents[0].name) } ?? 0
        let next = agents[(current + 1) % agents.count]
        session.agentName = next.name == agents[0].name ? nil : next.name
        return true
    }

    static let modeDetail: [AgentSession.PermissionMode: String] = [
        .default: "Asks before tools that change things",
        .acceptEdits: "Edits files without asking",
        .plan: "Reads and plans, changes nothing",
        .auto: "Decides for itself what needs asking",
        .bypassPermissions: "Never asks. Use with care",
    ]

    private func submit(confirmedLength: Bool = false, commandHeld: Bool = false) {
        let message = text
        // The question the agent asked takes what's typed as its answer.
        if session.pendingPermission == nil, session.pendingQuestion != nil, questions.draft != nil, bridge.editing == nil {
            let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            questions.submit(typed: typed.isEmpty ? nil : typed, session: session)
            if !typed.isEmpty { text = "" }
            return
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // A very long prompt asks first, where T3 Code's length check stops one.
        if !confirmedLength, case .tooLong(_, let why) = ComposerPromptLength.check(message, contextLeft: contextLeft) {
            ConfirmCenter.shared.ask(
                title: "Send a very long prompt?",
                message: why + " Shorten or split it if it doesn't all need to go at once.",
                confirmTitle: "Send Anyway",
                destructive: false
            ) { _ in submit(confirmedLength: true, commandHeld: commandHeld) }
            return
        }
        switch bridge.editing {
        case .editHeld(let id):
            session.updateHeld(id, text: message, attachments: attachments)
            cancelEditing()
            return
        case .resend(let itemId, let revertFiles):
            guard !session.conversation.isRunning else {
                ToastCenter.shared.info("Wait for this turn to end",
                                        detail: "A message can be sent again from an earlier point once the agent stops.")
                return
            }
            let images = attachments
            cancelEditing()
            PromptHistoryStore.shared.record(message, project: session.cwd)
            MessageResend.resend(itemId, text: message, attachments: images, revertFiles: revertFiles, in: session)
            return
        case nil:
            break
        }
        PromptHistoryStore.shared.record(message, project: session.cwd)
        historyCursor.reset()
        refiningPlan = false
        if attachments.isEmpty,
           let (command, arguments) = SlashCommands.invoked(message.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             in: session.slashCommands),
           command.handling != .agent {
            text = ""
            return run(command, arguments: arguments)
        }
        text = ""
        attachedPaths = false
        let images = attachments
        attachments = []
        // Mid-turn: steer by default where the engine can, ⌘ flipping it.
        let delivery: AgentSession.Delivery = session.canSteer && !commandHeld ? .steer : .queue
        // Diff review notes the person chose to send along go with it, once.
        session.send(ReviewNotesOutbox.shared.attach(to: message, cwd: session.cwd), attachments: images, delivery: delivery)
    }
}

/// Over the message box while it holds something being edited: a queued
/// message, or an earlier one to send again (with the choice of putting the
/// files back as they were then, where there's a checkpoint for that).
private struct EditingBanner: View {
    let purpose: ConversationBridge.Draft.Purpose
    let revertableFiles: Int
    let running: Bool
    let engine: String
    let setRevert: (Bool) -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            OctetIcon("pencil", size: 12).foregroundStyle(Theme.accent)
            switch purpose {
            case .editHeld:
                Text("Editing a queued message").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textSecondary)
                Text("Return updates it").font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
            case .resend(_, let revertFiles):
                Text("Editing an earlier message").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textSecondary)
                if running {
                    Text("Sendable once \(engine) stops").font(Theme.Text.caption).foregroundStyle(Theme.warning)
                } else if revertableFiles > 0 {
                    OctetSegmented(selection: Binding(get: { revertFiles }, set: setRevert),
                                   items: [(true, "Revert files too"), (false, "Keep changes")])
                        .help(revertableFiles == 1 ? "1 file changed since then" : "\(revertableFiles) files changed since then")
                } else {
                    Text("Files stay as they are").font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: Theme.Space.md)
            OctetButton(title: "Cancel", kind: .ghost, compact: true, action: cancel)
                .help("Put back what you were typing (Esc)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// An @ mention that matches no file.
private struct NoReferenceMatches: View {
    let query: String

    var body: some View {
        OctetPalettePanel(divider: .bottom) {
            HStack(spacing: 9) {
                OctetIcon("doc", size: 12).foregroundStyle(Theme.textTertiary)
                Text(query.isEmpty ? "No files here" : "No matching files")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityLabel("No matching files")
    }
}

/// Whether ⌘ is held, so the send button can show what Return would do.
@MainActor
final class ComposerModifierKeys: ObservableObject {
    @Published private(set) var command = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        command = NSEvent.modifierFlags.contains(.command)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.command)
            if self?.command != held { self?.command = held }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}


/// Status widgets Pi extensions place around the editor. RPC sends text
/// lines rather than arbitrary terminal UI, which keeps this native view safe.
private struct PiWidgets: View {
    let widgets: [AgentSession.PiWidget]

    var body: some View {
        OctetPalettePanel {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(widgets) { widget in
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// Slash commands matching what's typed, above the message field, with the
/// letters that matched lit.
private struct SlashSuggestions: View {
    let commands: [SlashCommandSearch.Result]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (SlashCommandSearch.Result) -> Void

    var body: some View {
        OctetPalettePanel(divider: .bottom) {
            OctetAnimatedList(items: commands, highlighted: highlighted, highlight: highlight, choose: choose) { result, _ in
                let command = result.command
                HStack(spacing: 10) {
                    MatchHighlightedText(text: command.insertion, indices: result.nameIndices,
                                         base: result.nameIndices.isEmpty ? Theme.textPrimary : Theme.textTertiary,
                                         lit: Theme.textPrimary)
                        .font(Theme.monoFont)
                        .fixedSize()
                    if !command.argumentHint.isEmpty {
                        Text(command.argumentHint)
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    if !command.summary.isEmpty {
                        MatchHighlightedText(text: command.summary, indices: result.summaryIndices,
                                             base: Theme.textTertiary, lit: Theme.textPrimary)
                            .font(Theme.captionFont)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !command.origin.label.isEmpty {
                        Text(command.origin.label)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }
}

/// Workspace files matching the unfinished @ mention in the composer.
private struct ReferenceSuggestions: View {
    let references: [AgentComposerSyntax.Reference]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (AgentComposerSyntax.Reference) -> Void

    var body: some View {
        OctetPalettePanel(divider: .bottom) {
            OctetAnimatedList(items: references, highlighted: highlighted, highlight: highlight, choose: choose) { reference, _ in
                HStack(spacing: 9) {
                    OctetIcon("doc", size: 12).foregroundStyle(Theme.textTertiary)
                    Text("@" + reference.path)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

/// Thumbnails of attached images; removable while composing.
private struct AttachmentStrip: View {
    let images: [Data]
    var remove: ((Int) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
                            .overlay(alignment: .topTrailing) {
                                if let remove {
                                    Button { remove(index) } label: {
                                        OctetIcon("xmark", size: 13)
                                            .foregroundStyle(Theme.textPrimary)
                                            .frame(width: 18, height: 18)
                                            .background(Circle().fill(Theme.card))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                    .accessibilityLabel("Remove image")
                                }
                            }
                            .accessibilityLabel("Attached image \(index + 1)")
                    }
                }
            }
        }
    }
}

private struct OpenImageKey: EnvironmentKey {
    static let defaultValue: (Data) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Shows an image large, above the conversation.
    var openImage: (Data) -> Void {
        get { self[OpenImageKey.self] }
        set { self[OpenImageKey.self] = newValue }
    }
}

/// Images in the transcript at a readable size; click one to enlarge it.
struct ImageGallery: View {
    let images: [Data]
    @Environment(\.openImage) private var openImage

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = NSImage(data: data) {
                        let height = min(240, image.size.height)
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: height)
                            .frame(maxWidth: 480)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
                            .contentShape(Rectangle())
                            .onTapGesture { openImage(data) }
                            .help("Click to enlarge")
                            .accessibilityLabel("Image \(index + 1)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }
}

/// A task list as Claude keeps it: done, in progress, still to do.
private struct TodoList: View {
    let todos: [AgentToolCall.Todo]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OctetIcon(icon(todo.state), size: 14)
                        .foregroundStyle(todo.state == .completed ? Theme.success
                                         : todo.state == .inProgress ? Theme.textPrimary : Theme.textTertiary)
                    Text(todo.text)
                        .font(Theme.uiFont)
                        .foregroundStyle(todo.state == .pending ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough(todo.state == .completed, color: Theme.textTertiary)
                        .fontWeight(todo.state == .inProgress ? .medium : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(todo.state == .completed ? "done" : todo.state == .inProgress ? "in progress" : "to do")
            }
        }
        .padding(.leading, 4)
    }

    private func icon(_ state: AgentToolCall.Todo.State) -> String {
        switch state {
        case .completed: "tool.todo.done"
        case .inProgress: "tool.todo.active"
        case .pending: "tool.todo.open"
        }
    }
}

/// Codex's answers to the same three questions Claude Code's pickers ask:
/// which model, how hard it thinks, and what it may do without asking. The
/// options are Codex's own, read from `model/list` and `permissionProfile/list`
/// rather than written down here, and a change reaches a running thread at
/// once instead of waiting for the next message.
private struct CodexControls: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    @ObservedObject private var catalog = CodexCatalogStore.shared

    var body: some View {
        let model = catalog.model(session.model)
        OctetDropdown(spec: OctetDropdownSpec(
            id: "model",
            options: catalog.models.map {
                OctetDropdownOption(id: $0.id, title: $0.displayName, detail: $0.description)
            },
            selected: model?.id ?? "",
            select: { session.model = $0 },
            searchPlaceholder: "Search models…",
            modelEffort: model?.efforts.isEmpty == false ? $session.effort : nil,
            modelEffortLevels: model?.efforts ?? [],
            modelDefaultEffort: model?.defaultEffort,
            modelAgent: session.engine.agent
        ), label: "Model", state: dropdowns)
        .disabled(catalog.models.isEmpty)

        if !catalog.profiles.isEmpty {
            let options = [OctetDropdownOption(id: SandboxStyle.unset, title: "From your config",
                                              detail: "Whatever ~/.codex says, unchanged")]
                + catalog.profiles.map {
                    OctetDropdownOption(id: $0.id, title: $0.title, detail: $0.detail, dangerous: $0.isDangerous,
                                       tint: SandboxStyle.color($0.id), glyph: SandboxStyle.glyph($0.id))
                }
            OctetDropdownAnchor(spec: OctetDropdownSpec(
                id: "mode",
                options: options,
                selected: session.permissionProfile ?? SandboxStyle.unset,
                select: { choice in
                    let profile = choice == SandboxStyle.unset ? nil : choice
                    guard catalog.profiles.first(where: { $0.id == choice })?.isDangerous == true else {
                        session.permissionProfile = profile
                        return
                    }
                    // Full access is Codex's sandbox off entirely: confirm it,
                    // as Claude Code's bypass mode is confirmed.
                    ConfirmCenter.shared.ask(
                        title: "Give Codex full access?",
                        message: "Codex will run commands, edit and delete files anywhere, and reach the network, without a sandbox, for the rest of this conversation. Use it only in a folder you can afford to lose changes in.",
                        confirmTitle: "Allow Full Access",
                        destructive: true
                    ) { _ in session.permissionProfile = choice }
                }
            ), state: dropdowns) { open in
                SandboxChip(profile: session.permissionProfile, profiles: catalog.profiles, open: open)
            }
            .help("What Codex may do without asking. Applies at once.")
            .accessibilityLabel("Sandbox")
            .accessibilityValue(SandboxStyle.label(session.permissionProfile, profiles: catalog.profiles))
        }
    }
}

/// OpenCode's pickers: the agent a message goes to (Build, Plan, or the
/// person's own), any model of any provider it's signed in to, that model's
/// own reasoning variants, and what it may do without asking. All but
/// permissions travel with each message, so a change applies from the next.
private struct OpenCodeControls: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    @ObservedObject private var store = OpenCodeCatalogStore.shared
    @EnvironmentObject private var window: WindowContext
    @State private var browsing = false
    private static let viewAll = "octet.view-all"

    var body: some View {
        let catalog = store.catalog(for: session.cwd)
        let model = catalog.model(session.model)
        if catalog.agents.count > 1 {
            OctetDropdown(spec: OctetDropdownSpec(
                id: "agent",
                options: catalog.agents.map {
                    OctetDropdownOption(id: $0.name, title: $0.name.capitalized,
                                       detail: $0.description.isEmpty ? nil : String($0.description.prefix(80)))
                },
                selected: session.agentName ?? catalog.agents.first?.name ?? "build",
                select: { choice in
                    session.agentName = choice == catalog.agents.first?.name ? nil : choice
                    // An agent with a model of its own brings it along.
                    if let agent = catalog.agents.first(where: { $0.name == choice }),
                       let own = agent.model, catalog.model(own) != nil {
                        session.model = own
                        session.effort = agent.variant
                    }
                }
            ), label: "Agent", state: dropdowns)
            .help("Who handles the message: Build works, Plan only reads and plans. Tab cycles them.")
        }

        OctetDropdown(spec: OctetDropdownSpec(
            id: "model",
            options: catalog.models.map {
                OctetDropdownOption(id: $0.id, title: $0.name, detail: $0.detail.isEmpty ? nil : $0.detail,
                                   section: $0.providerName)
            } + [OctetDropdownOption(id: Self.viewAll, title: "View all models…",
                                    detail: "Every provider OpenCode supports", section: "More")],
            selected: model?.id ?? session.model,
            select: { choice in
                guard choice != Self.viewAll else { browsing = true; return }
                session.model = choice
                // Variants are per model; keep the choice only where it exists.
                if let effort = session.effort, catalog.model(choice)?.variants.contains(effort) != true { session.effort = nil }
                session.conversation.contextWindow = catalog.model(choice)?.context
            },
            searchPlaceholder: "Search models…"
        ), label: "Model", state: dropdowns)
        .sheet(isPresented: $browsing, onDismiss: {
            // A provider signed in to meanwhile joins the menu.
            store.load(cwd: session.cwd, refresh: true)
        }) {
            OpenCodeModelBrowser(session: session) { browsing = false }
                .environmentObject(window)
        }

        if let model, !model.variants.isEmpty {
            let spec = OctetDropdownSpec(
                id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
                panel: { close in
                    AnyView(EffortSliderPanel(initial: session.effort, implicit: nil,
                                              levels: model.variants, detail: OpenCodeCatalog.variantDetail,
                                              apply: { session.effort = $0 }, close: close))
                }
            )
            OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
                EffortChip(level: session.effort, implicit: nil, open: open)
            }
            .help("How hard \(model.name) reasons: the variants this model offers. Applies from the next message.")
            .accessibilityLabel("Reasoning variant")
            .accessibilityValue(session.effort ?? "default")
        }

        OctetDropdown(spec: OctetDropdownSpec(
            id: "mode",
            options: [
                OctetDropdownOption(id: "config", title: "From your config",
                                   detail: "OpenCode's own rules: most tools run, outside folders ask"),
                OctetDropdownOption(id: "ask", title: "Ask first",
                                   detail: "Asks before edits, commands, fetches and subagents"),
                OctetDropdownOption(id: "allow", title: "Allow everything",
                                   detail: "Never asks, like opencode --auto. Use with care", dangerous: true),
            ],
            selected: session.permissionProfile ?? "config",
            select: { choice in
                let preset = choice == "config" ? nil : choice
                guard preset == "allow", session.permissionProfile != "allow" else {
                    session.permissionProfile = preset
                    return
                }
                ConfirmCenter.shared.ask(
                    title: "Let OpenCode do anything?",
                    message: "OpenCode will edit files, run commands and work outside this folder without asking, for the rest of this conversation.",
                    confirmTitle: "Allow Everything",
                    destructive: true
                ) { _ in session.permissionProfile = "allow" }
            }
        ), label: "Permissions", state: dropdowns)
        .help("What OpenCode may do without asking. Applies at once.")
    }
}

/// Pi's live RPC controls. The model list and supported thinking levels come
/// from the installed Pi instance and its configured providers.
private struct PiControls: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState

    var body: some View {
        let selected = session.piModels.first { $0.id == session.model }
        OctetDropdown(spec: OctetDropdownSpec(
            id: "model",
            options: session.piModels.map {
                OctetDropdownOption(id: $0.id, title: $0.name,
                                    detail: $0.detail.isEmpty ? nil : $0.detail,
                                    section: $0.provider)
            },
            selected: selected?.id ?? session.model,
            select: { session.model = $0 },
            searchPlaceholder: "Search models…"
        ), label: "Model", state: dropdowns)
        .disabled(session.piModels.isEmpty)
        .help(session.piModels.isEmpty
              ? "Pi has no authenticated models yet. Configure a provider with pi /login."
              : "Pi models available through your configured providers. Applies at once.")

        if session.piThinkingLevels.count > 1 || session.piThinkingLevels.first != "off" {
            let details = Dictionary(uniqueKeysWithValues: session.piThinkingLevels.map { level in
                (level, level == "off" ? "No extended reasoning" : "\(level.capitalized) reasoning")
            })
            let spec = OctetDropdownSpec(
                id: "effort", options: [], selected: session.effort ?? "off", select: { _ in },
                panel: { close in
                    AnyView(EffortSliderPanel(initial: session.effort, implicit: "off",
                                              levels: session.piThinkingLevels, detail: details,
                                              apply: { session.effort = $0 }, close: close))
                }
            )
            OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
                EffortChip(level: session.effort, implicit: "off", open: open)
            }
            .help("How hard Pi reasons. Applies at once.")
            .accessibilityLabel("Thinking level")
            .accessibilityValue(session.effort ?? "off")
        }
    }
}

/// Qwen's model (what its providers offer), effort and approval mode, all
/// taken live by its control channel.
private struct QwenControls: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState

    var body: some View {
        let models = session.qwenModels
        OctetDropdown(spec: OctetDropdownSpec(
            id: "model",
            options: models.map { OctetDropdownOption(id: $0.id, title: $0.label, detail: $0.label == $0.id ? nil : $0.id) },
            selected: models.contains(where: { $0.id == session.model }) ? session.model : "",
            select: { session.model = $0 },
            searchPlaceholder: "Search models…"
        ), label: "Model", state: dropdowns)
        .disabled(models.isEmpty)
        .help(models.isEmpty ? "Qwen lists its models once it has started." : "Models from Qwen's providers. Applies at once.")

        let effortSpec = OctetDropdownSpec(
            id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
            panel: { close in
                AnyView(EffortSliderPanel(initial: session.effort, implicit: nil, levels: AgentSession.qwenEfforts,
                                          apply: { session.effort = $0 }, close: close))
            }
        )
        OctetDropdownAnchor(spec: effortSpec, state: dropdowns) { open in
            EffortChip(level: session.effort, implicit: nil, open: open)
        }
        .help("How hard Qwen reasons. Applies at once.")
        .accessibilityLabel("Effort")
        .accessibilityValue(session.effort ?? "default")

        OctetDropdownAnchor(spec: OctetDropdownSpec(
            id: "mode",
            options: AgentSession.PermissionMode.allCases.map {
                OctetDropdownOption(id: $0.rawValue, title: $0.title, detail: Composer.modeDetail[$0],
                                   dangerous: $0 == .bypassPermissions,
                                   tint: $0 == .default ? nil : ModeStyle.color($0), glyph: ModeStyle.glyph($0))
            },
            selected: session.permissionMode.rawValue,
            select: { choice in
                let mode = AgentSession.PermissionMode(rawValue: choice) ?? .default
                guard mode == .bypassPermissions, session.permissionMode != mode else {
                    session.permissionMode = mode
                    return
                }
                ConfirmCenter.shared.ask(
                    title: "Run Qwen in YOLO mode?",
                    message: "Qwen will run commands, edit and delete files, and use every tool without asking you first, for the rest of this conversation. Use it only in a folder you can afford to lose changes in.",
                    confirmTitle: "Use YOLO Mode",
                    destructive: true
                ) { _ in session.permissionMode = .bypassPermissions }
            }
        ), state: dropdowns) { open in
            ModeChip(mode: session.permissionMode, open: open)
        }
        .accessibilityLabel("Approval mode")
        .accessibilityValue(session.permissionMode.title)
        .help("How Qwen asks before using tools (its approval mode). Applies at once.")
    }
}

/// The effort chip, opening Octet's slider panel above the composer.
private struct EffortControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState

    var body: some View {
        let spec = OctetDropdownSpec(
            id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
            panel: { close in
                let levels = AgentSession.model(session.model)?.efforts.flatMap { $0.isEmpty ? nil : $0 }
                return AnyView(EffortSliderPanel(initial: session.effort, implicit: AgentSession.defaultEffort(model: session.model),
                                                 levels: levels ?? AgentSession.efforts,
                                                 apply: { session.effort = $0 }, close: close))
            }
        )
        let supported = AgentSession.supportsEffort(model: session.model)
        OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
            EffortChip(level: supported ? session.effort : nil,
                       implicit: supported ? AgentSession.defaultEffort(model: session.model) : nil, open: open)
        }
        .disabled(!supported)
        .opacity(supported ? 1 : 0.5)
        .help(supported ? "How hard Claude thinks. Applies at once." : "This model has no effort setting.")
        .accessibilityLabel("Effort")
        .accessibilityValue(session.effort ?? "default")
    }
}

/// An agent's message, with a copy button that shows on hover.
private struct AssistantMessage: View {
    let text: String
    var streaming = false
    var canRegenerate = false
    @State private var hovered = false
    @State private var selection: AssistantSelection?
    @Environment(\.transcriptActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(text: text, streaming: streaming)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Selecting part of the reply offers to quote it, after T3 Code.
                .overlay {
                    SelectionWatcher { found in
                        withAnimation(.easeOut(duration: 0.12)) { selection = found }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    if let selection {
                        GeometryReader { proxy in
                            let origin = AssistantSelectionToolbar.origin(for: selection.point, in: proxy.size)
                            AssistantSelectionToolbar(selection: selection, quote: { action in
                                actions.quote(selection.text, action)
                                self.selection = nil
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }, dismiss: { self.selection = nil })
                            .offset(x: origin.x, y: origin.y)
                        }
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovered && selection == nil {
                        HStack(spacing: 2) {
                            if canRegenerate {
                                Button { actions.regenerate() } label: {
                                    OctetIcon("arrow.clockwise", size: 12)
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 20, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Regenerate this reply: the prompt goes again, its file changes put back first")
                                .accessibilityLabel("Regenerate reply")
                            }
                            TranscriptCopyButton(text: text, label: "Copy as Markdown")
                        }
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.chrome))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
                        .offset(y: -4)
                        .transition(.opacity)
                    }
                }
            TranscriptMediaStrip(text: text, cwd: actions.cwd)
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(actions.agentName)
        .contextMenu {
            MessageCopyMenu(text: text)
            if canRegenerate {
                Divider()
                Button("Regenerate Reply") { actions.regenerate() }
            }
        }
        #if DEBUG
        .onAppear {
            // Verification hook: the selection bar over a passage of the sample.
            guard ConversationDebug.openDropdown == "transcript-quote",
                  let range = text.range(of: TranscriptDebug.quotedPassage) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                selection = AssistantSelection(text: String(text[range]), point: CGPoint(x: 220, y: 40))
            }
        }
        #endif
    }
}

/// The composer's round action, after T3 Code's: send in the accent with an
/// up arrow, growing a touch under the pointer; stop in red with a square.
private struct RoundComposerButton: View {
    /// Send; while a turn runs, queue it for after or steer it in now.
    enum Kind { case send, queue, steer, stop }
    let kind: Kind
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(kind == .stop ? Theme.danger.opacity(0.9) : Theme.accent)
                switch kind {
                case .stop:
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.white).frame(width: 10, height: 10)
                default:
                    Image(systemName: Self.symbol(kind))
                        .font(Theme.Text.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .overlay(alignment: .top) {
                // The lit top edge filled buttons have.
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 14, height: 1).padding(.top, 1)
            }
            .frame(width: 30, height: 30)
            .shadow(color: (kind == .stop ? Theme.danger : Theme.accent).opacity(enabled ? 0.28 : 0), radius: 2, y: 1)
            .scaleEffect(hovered && enabled ? 1.05 : 1)
            .opacity(enabled ? 1 : 0.64)
            .contentShape(Circle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.easeOut(duration: 0.15), value: kind)
    }

    private static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .send: "arrow.up"
        case .queue: "text.line.last.and.arrowtriangle.forward"
        case .steer: "arrow.turn.up.right"
        case .stop: "stop.fill"
        }
    }
}
