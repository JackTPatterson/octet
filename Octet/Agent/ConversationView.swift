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
                VStack(spacing: 0) {
                ComposerQueueDrawer(session: session, bridge: bridge)
                WaitSuggestionBanner(session: session)
                CheckInSuggestionBanner(session: session)
                // Only read once the turn is over, not on every streamed token.
                let suggestedCommands = session.conversation.isRunning
                    ? [] : AgentComposerSyntax.suggestedShellCommands(in: session.conversation.items)
                if !suggestedCommands.isEmpty {
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
                }
                .chatColumn()
                ConversationContextStrip(session: session)
                Composer(session: session, dropdowns: dropdowns, bridge: bridge, questions: questions)
                    .zIndex(1)
            }
            .clipped()
        }
        .onChange(of: session.pendingQuestion?.id, initial: true) { _, _ in questions.sync(session.pendingQuestion) }
        // A question or an approval waiting on you is felt, not only seen.
        .onChange(of: session.pendingQuestion?.id) { _, id in if id != nil { Haptics.step() } }
        .onChange(of: session.pendingPermission?.id) { _, id in if id != nil { Haptics.step() } }
        .animation(motion.animation(.approvals, .smooth(duration: 0.26)), value: session.pendingPermission?.id)
        .animation(motion.animation(.approvals, .smooth(duration: 0.26)), value: session.pendingQuestion?.id)
        .background(ChatStyle.page)
        .overlay { ChatColumnEdges() }
        .modifier(EscapeStopsTurn(session: session, blocked: enlarged != nil || dropdowns.openId != nil,
                                  inMainArea: !window.isBeside("conversation:" + session.id)))
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
            if id == "mcp" {
                session.debugLoadMCP()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MCPServersDialog.show(session) }
                return
            }
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

// MARK: - Context strip

/// Where the conversation is working, under the composer, after T3 Code's
/// context strip: the branch or worktree, its pull request and changes,
/// and whether the last edits were checked, small and muted. The thread's
/// own title is the tab's, so there is no header above the transcript.
private struct ConversationContextStrip: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var session: AgentSession
    @ObservedObject private var accounts = AccountStore.shared
    /// Read when a turn ends, not on every streamed word.
    @State private var verification: Verification = .noEdits

    var body: some View {
        let conversation = session.conversation
        let showsCost = accounts.accounts["claude"]?.kind != .subscription && conversation.costUSD != nil
        let showsBadge = !conversation.isRunning && verification != .noEdits
        // The credential profiles this folder's agents and commands run with.
        let credentials = CredentialProfiles.inForce(for: session.cwd)
        HStack(spacing: 10) {
            // Branch and working-tree changes are the status bar's.
            if !credentials.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill").font(.system(size: 9))
                    Text(credentials.map(\.name).joined(separator: ", ")).lineLimit(1)
                }
                .foregroundStyle(ChatStyle.mutedText)
                .help("Credential profiles in use here: " + credentials.map { $0.name + " (" + $0.variables.map(\.name).joined(separator: ", ") + ")" }.joined(separator: "; "))
            }
            Spacer(minLength: 8)
            if !conversation.isRunning, verification != .noEdits {
                VerificationBadge(verification: verification, compact: true)
            }
            // A subscription spends allowance, which the title bar chip shows
            // for the whole account; an API key spends money, which only this
            // conversation knows.
            if accounts.accounts["claude"]?.kind != .subscription, let cost = conversation.costUSD {
                Text(String(format: "$%.2f", cost))
                    .font(ChatStyle.meta.monospacedDigit())
                    .foregroundStyle(ChatStyle.faintIcon)
                    .help("Cost so far at API prices")
            }
        }
        .font(ChatStyle.meta)
        .frame(height: 20)
        .padding(.horizontal, 22 + 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .chatColumn()
        // Nothing to say: no strip at all, not an empty band.
        .frame(height: showsCost || showsBadge || !credentials.isEmpty ? nil : 0)
        .clipped()
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

    var body: some View {
        // The folder is the breadcrumb's; this says where in it.
        HStack(spacing: 10) {
            if let label = sourceLabel {
                HStack(spacing: 4) {
                    OctetIcon(worktree == nil ? "arrow.triangle.branch" : "square.stack.3d.up", size: 11)
                    Text(label)
                        .font(ChatStyle.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(ChatStyle.mutedText)
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
            // A lookup for the old folder mustn't keep the new one waiting.
            loadingPullRequest = false
            reloadChanges()
            reloadPullRequest()
        }
        // Changes every 3 seconds and the pull request every 30, for as long
        // as the header shows. A Timer.publish stored on the view was made
        // anew on every redraw.
        .task(id: directory) {
            var ticks = 0
            while true {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                ticks += 1
                reloadChanges()
                if ticks % 10 == 0 { reloadPullRequest() }
            }
        }
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
                loadingPullRequest = false
                guard path == directory else { return }
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
        if pullRequest.checks == .pending { return ChatStyle.primary }
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
    /// Keeping up with the latest as it streams. Only scrolling up turns it
    /// off; a reply growing past the bottom of the view doesn't. Reaching
    /// the end again, Jump to Latest, or sending a message turns it back on.
    @State private var following: Bool
    /// The tool call whose whole output is open over the transcript.
    @State private var outputItem: String?
    @State private var changesCache = TurnChangesCache()
    /// The rows and the rest, kept while a reply streams in (see
    /// `TranscriptLayoutCache`): worked out again only when the items
    /// change shape, not on every token.
    @State private var layoutCache = TranscriptLayoutCache()
    /// The row at the top of the view, to come back to it.
    @State private var position: String?
    /// Folded runs of tool calls that have been opened, by row id.
    @State private var openRuns: Set<String> = []
    /// How many rows there were when the view left the end, for "Jump to
    /// Latest" to say how many came since.
    @State private var rowsWhenLeft: Int?
    /// A follow-to-the-end scroll is already on its way.
    @State private var scrollQueued = false

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
        _following = State(initialValue: saved == nil)
    }

    var body: some View {
        let items = session.conversation.items
        let running = session.conversation.isRunning
        let blocking = blockingState
        let layout = layoutCache.layout(for: session.conversation)
        let rows = layout.rows
        let byId = { (id: String) in layout.item(id, in: items) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let blocking {
                        AgentBlockingState(session: session, state: blocking)
                    } else if items.isEmpty {
                        EmptyConversation(session: session)
                    }
                    if blocking == nil {
                        let depths = layout.depths
                        let thinkingDurations = layout.thinkingDurations
                        let turns = changesCache.turns(items, layout: layoutCache.generation, cwd: session.cwd,
                                                       running: running, isShown: Self.isShown)
                        let lastId = layout.lastShownId
                        let regenerable = Self.regenerableReply(session, reply: layout.lastTextPosition.map { items[$0] })
                        ForEach(rows) { row in
                            let first = row.itemIds.first ?? ""
                            let depth = depths[first] ?? 0
                            VStack(alignment: .leading, spacing: 12) {
                                Group {
                                    switch row {
                                    case .item(let id):
                                        if let item = byId(id) {
                                            if let report = session.usageReports[item.id] {
                                                UsageCard(report: report)
                                            } else {
                                                ItemRow(item: item, running: running, isLast: id == lastId,
                                                        thinkingDuration: thinkingDurations[item.id],
                                                        canRegenerate: id == regenerable)
                                                    .equatable()
                                            }
                                        }
                                    case .toolRun(let ids):
                                        ToolRunRow(items: ids.compactMap(byId), running: running,
                                                   expanded: Binding(get: { openRuns.contains(row.id) },
                                                                     set: { open in
                                                                         if open { openRuns.insert(row.id) } else { openRuns.remove(row.id) }
                                                                     }),
                                                   marks: { find.marks(for: $0) })
                                    }
                                }
                                .contextMenu {
                                    if case .item(let id) = row, let item = byId(id) {
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
                        .onAppear { atBottom = true; following = true }
                        .onDisappear { atBottom = false }
                }
                // T3 Code's chat column: 46rem, centred, the page's gutters.
                .padding(.vertical, 24)
                .chatColumn()
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .top)
            .modifier(TranscriptFollow(following: $following))
            .modifier(CopyOnSelect())
            // Opens at the latest, not the first message.
            .defaultScrollAnchor(.bottom)
            // And stays on it as the reply grows, with the system's own
            // smooth pinning, until you scroll up.
            .modifier(PinToEnd(following: following))
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
            // Growth while following is the pinned anchor's job (`PinToEnd`):
            // the system keeps the end in view as the reply lengthens, in
            // step with layout, which is what stays smooth. Scrolling by
            // hand on top of it fought it and made it jump.
            .onChange(of: items) { old, new in
                // Your own message brings the view back to the end, once.
                if new.count != old.count, let last = new.last, case .user = last.kind, !last.queued {
                    following = true
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    return
                }
                // Before macOS 15 there's no pinned anchor, so follow by hand,
                // at most every tenth of a second.
                if #unavailable(macOS 15.0), following, !scrollQueued {
                    scrollQueued = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollQueued = false
                        if following { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
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
                let marks = layout.marks
                if blocking == nil, marks.count > 1 {
                    TranscriptMinimap(marks: marks, current: Self.currentPrompt(position, rows: rows, items: byId)) { id in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 4)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom && !following && !items.isEmpty {
                    let fresh = max(0, rows.count - (rowsWhenLeft ?? rows.count))
                    OctetButton(title: fresh > 0 ? "Jump to Latest · \(fresh) new" : "Jump to Latest",
                                icon: "arrow.down", kind: .secondary, compact: true) {
                        following = true
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

    /// The reply Regenerate is offered on, if any: the last reply, found
    /// with the layout, so a streaming turn doesn't search for it.
    static func regenerableReply(_ session: AgentSession, reply: AgentItem?) -> String? {
        guard let reply, MessageResend.canRegenerate(reply, in: session) else { return nil }
        return reply.id
    }

    /// The prompt at or above the top of the view.
    static func currentPrompt(_ position: String?, rows: [TranscriptRow], items: (String) -> AgentItem?) -> String? {
        let top = position.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count - 1
        guard top >= 0 else { return nil }
        return rows[...min(top, rows.count - 1)].reversed().first { row in
            if case .item(let id) = row, case .user = items(id)?.kind { return true }
            return false
        }?.id
    }

    /// The prompt before or after the one at the top of the view.
    static func prompt(_ direction: ConversationBridge.Jump.Direction, from position: String?,
                       rows: [TranscriptRow], items: (String) -> AgentItem?, atBottom: Bool) -> String? {
        let prompts = rows.indices.filter { index in
            if case .item(let id) = rows[index], case .user = items(id)?.kind { return true }
            return false
        }
        guard !prompts.isEmpty else { return nil }
        let top = atBottom ? rows.count : position.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        switch direction {
        case .previous: return prompts.last { $0 < top }.map { rows[$0].id } ?? rows[prompts[0]].id
        case .next: return prompts.first { $0 > top }.map { rows[$0].id }
        }
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

/// Stops following the stream when you scroll up, and starts again when
/// you reach the end. Content growing under the view moves neither: only
/// the offset moving up, landing away from the end, counts as leaving.
/// The terminal's "Copy on select", for the conversation: letting go of
/// the mouse after selecting text in the transcript copies it, as the
/// setting says. The transcript's selectable text takes `copy:` like ⌘C.
private struct CopyOnSelect: ViewModifier {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                    handle(event)
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func handle(_ event: NSEvent) {
        guard settings.values.copyOnSelect, let window = event.window, window === NSApp.keyWindow,
              let height = window.contentView?.bounds.height else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        guard frame.contains(point) else { return }
        // A selection made in the message box is its own, not the transcript's.
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
    }
}

/// Keeps the view on the end while following, so a growing reply scrolls
/// with the system's own smoothing instead of jumping.
private struct PinToEnd: ViewModifier {
    let following: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
        } else {
            content
        }
    }
}

private struct TranscriptFollow: ViewModifier {
    @Binding var following: Bool

    struct Reading: Equatable {
        var offset: CGFloat
        var fromEnd: CGFloat
        var contentHeight: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Reading.self) { geometry in
                Reading(offset: geometry.contentOffset.y,
                        fromEnd: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height,
                        contentHeight: geometry.contentSize.height)
            } action: { old, new in
                if new.fromEnd < 24 {
                    if !following { following = true }
                } else if new.offset < old.offset - 1, new.fromEnd > 60, following,
                          // Lazy rows settling to their real heights move the
                          // offset too; only a scroll with the content as it
                          // was is you leaving the end.
                          abs(new.contentHeight - old.contentHeight) < 1 {
                    following = false
                }
            }
        } else {
            content
        }
    }
}

extension Transcript {
    static func isShown(_ item: AgentItem) -> Bool { TranscriptTimeline.isShown(item) }
}

private struct SuggestedCommandsPanel: View {
    @ObservedObject var session: AgentSession
    let commands: [String]
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            ChatBanner {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        OctetIcon("terminal", size: 13).foregroundStyle(ChatStyle.primary)
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
        Group { content }
            .animation(.smooth(duration: 0.28), value: typingCommand)
            .animation(.smooth(duration: 0.28), value: session.shellRunning != nil)
    }

    @ViewBuilder private var content: some View {
        if typingCommand || session.shellRunning != nil || !session.shellRuns.isEmpty {
            HStack(spacing: 7) {
                OctetIcon("terminal", size: 12).foregroundStyle(ChatStyle.link)
                if let running = session.shellRunning {
                    LoadingLine(width: 14)
                    Text("Running `\(running)`").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Stop") { session.stopShell() }.buttonStyle(.plain).foregroundStyle(ChatStyle.link)
                    Keycap(text: "esc")
                } else if typingCommand {
                    Text("Runs in \(abbreviateHome(session.cwd)); \(session.engine.displayName) responds to its output")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                } else {
                    let count = session.shellRuns.count
                    Text(count == 1 ? "1 command's output goes with your next message"
                                    : "\(count) commands' output goes with your next message")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Don't Send") { session.dropShellRuns() }.buttonStyle(.plain).foregroundStyle(ChatStyle.link)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
            .transition(.opacity.combined(with: .offset(y: 5)))
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
            UserMessage(item: item, text: text)
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

/// Your message: what it carried (images, files, pasted text) as tiles
/// above, then the words in T3 Code's bubble, right-aligned, 18pt round.
private struct UserMessage: View {
    let item: AgentItem
    let text: String
    @Environment(\.transcriptActions) private var actions

    var body: some View {
        let parts = ChatAttachmentFormat.parse(text)
        VStack(alignment: .trailing, spacing: 6) {
            if !item.images.isEmpty || !parts.files.isEmpty || !parts.pasted.isEmpty {
                SentAttachments(images: item.images, parts: parts, cwd: actions.cwd)
                    .frame(maxWidth: 560, alignment: .trailing)
            }
            if !parts.body.isEmpty || item.queued || item.remote {
                bubble(parts.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: " + parts.body
            + (item.images.isEmpty ? "" : ", \(item.images.count) \(item.images.count == 1 ? "image" : "images")")
            + (parts.files.isEmpty ? "" : ", \(parts.files.count) \(parts.files.count == 1 ? "file" : "files")")
            + (parts.pasted.isEmpty ? "" : ", pasted text"))
    }

    private func bubble(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.queued {
                HStack(spacing: 5) {
                    OctetIcon("clock", size: 11)
                    Text("Queued")
                }
                .font(Theme.captionFont)
                .foregroundStyle(ChatStyle.primary)
            }
            if item.remote {
                HStack(spacing: 5) {
                    OctetIcon("remote", size: 11)
                    Text("Sent over Remote Control")
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            }
            if !body.isEmpty {
                FoundText(body)
                    .font(ChatStyle.body)
                    .lineSpacing(ChatStyle.bodyLineSpacing)
                    .foregroundStyle(ChatStyle.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(item.queued ? ChatStyle.primary.opacity(0.07) : ChatStyle.bubble)
        .overlay {
            if item.queued {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(ChatStyle.primary.opacity(0.35), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 560, alignment: .trailing)
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
                Circle().fill(ChatStyle.primary.opacity(0.14))
                if !complete && running {
                    LoadingLine(width: 12)
                } else {
                    OctetIcon(complete ? "checkmark" : "arrow.counterclockwise", size: 13)
                        .foregroundStyle(ChatStyle.primary)
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
        // A file's name rather than its whole path; the path is a hover away.
        let shown = call.filePath.map { subtitle.replacingOccurrences(of: $0, with: ($0 as NSString).lastPathComponent) } ?? subtitle
        // An MCP tool leads with its service's logo where there is one,
        // not the generic plug.
        let mcpLogo = LanguageLogo(mcpTool: call.name, size: 14)
        WorkLogDisclosure(title: call.displayName, subtitle: shown, subtitleIsCode: call.filePath == nil,
                   tint: call.isError ? ChatStyle.removed : ChatStyle.secondaryText,
                   icon: mcpLogo == nil ? call.iconName : nil,
                   logo: mcpLogo ?? (artifact == nil ? LanguageLogo(path: call.filePath) : nil),
                   logoLeads: mcpLogo != nil,
                   outcome: call.name.caseInsensitiveCompare("Bash") == .orderedSame && call.result != nil
                       ? !call.isError : nil,
                   highlightsShell: call.name.caseInsensitiveCompare("Bash") == .orderedSame
                       || call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
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
        .help(call.filePath ?? "")
    }

    @ViewBuilder private func status(_ diff: [LineDiff.Line]?) -> some View {
        HStack(spacing: 6) {
            if let diff {
                Text(DiffView.summary(diff))
                    .font(ChatStyle.meta.monospacedDigit())
                    .foregroundStyle(ChatStyle.mutedText)
            }
            if call.result == nil && running {
                LoadingLine(width: 14)
            } else if call.result == nil {
                // The conversation stopped with this call still out.
                Text("Interrupted").font(Theme.Text.caption).foregroundStyle(Theme.warning)
            } else if call.isError {
                OctetIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(Theme.danger)
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

/// The soft blue light that falls from the top of the composer card while it holds a
/// `!` command: a wash for a bare `!`, brighter once there is something
/// to run, drifting up into place and fading back out.
private struct CommandGlow: View {
    let level: Int

    var body: some View {
        let strength: Double = level == 2 ? 1 : level == 1 ? 0.4 : 0
        // One wide pool of light from the top middle of the card, falling
        // off like a gaussian so it has no visible edge, and grown and
        // shrunk from the top as it fades so it feathers in and out.
        let link = ChatStyle.link
        RadialGradient(stops: [
            .init(color: link.opacity(0.46), location: 0),
            .init(color: link.opacity(0.34), location: 0.18),
            .init(color: link.opacity(0.2), location: 0.4),
            .init(color: link.opacity(0.09), location: 0.62),
            .init(color: link.opacity(0.03), location: 0.82),
            .init(color: .clear, location: 1),
        ], center: .top, startRadius: 0, endRadius: 190)
            .scaleEffect(x: 3.4, y: level == 0 ? 0.55 : 1, anchor: .top)
            .blur(radius: 10)
            .opacity(strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(level == 0 ? .easeInOut(duration: 0.7) : .easeInOut(duration: 0.9), value: level)
    }
}

/// A `!` line in the shell's colours, laid over the box that holds it.
private struct ShellPromptText: View {
    let source: String

    var body: some View {
        Text(highlighted)
            .font(Theme.Text.mono(13.5))
            .lineSpacing(ChatStyle.bodyLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlighted: AttributedString {
        var result = AttributedString("!")
        result.foregroundColor = ChatStyle.link
        let body = String(source.dropFirst())
        var cursor = body.startIndex
        func add(_ piece: Substring, _ color: Color) {
            var part = AttributedString(String(piece))
            part.foregroundColor = color
            result += part
        }
        for span in ShellSyntax.spans(in: body) {
            if cursor < span.range.lowerBound { add(body[cursor..<span.range.lowerBound], ChatStyle.text) }
            add(body[span.range], span.role.color(argument: ChatStyle.text))
            cursor = span.range.upperBound
        }
        if cursor < body.endIndex { add(body[cursor...], ChatStyle.text) }
        return result
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
    /// Files and long pastes going with the message, as tiles.
    @State private var extras: [ComposerExtra] = []
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
    /// other file becomes a tile that goes in the message as a path the
    /// agent can read, since none of the agents take arbitrary files inline.
    private func attach(files urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                if let image = NSImage(contentsOf: url), let attachment = AgentSession.Attachment(image: image) {
                    attachments.append(attachment)
                } else {
                    failed.append(url.lastPathComponent)
                }
            } else if !extras.contains(where: { $0.kind == .file(url.path) }) {
                extras.append(ComposerExtra(kind: .file(url.path)))
            }
        }
        if !failed.isEmpty {
            ToastCenter.shared.fail(nil, "Couldn't attach \(failed.joined(separator: ", "))", detail: "The image couldn't be read.")
        }
    }

    /// Octet's own file picker, starting in the conversation's folder.
    private func pickFiles() {
        PathPickerCenter.shared.pick("Attach Files",
                                     message: "Images go along with the message; other files as paths the agent can read. Space marks several.",
                                     prompt: "Attach", mode: .files(multiple: true), start: session.cwd,
                                     in: window.nsWindow) { urls in
            if !urls.isEmpty { attach(files: urls) }
        }
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
        guard let plan = ComposerPlanFollowUp.latestPlan(in: session.conversation.items, planMode: session.isPlanning,
                                                         running: session.conversation.isRunning),
              plan.id != dismissedPlan else { return nil }
        return plan
    }

    private func implement(_ plan: ComposerPlanFollowUp.Plan) {
        dismissedPlan = plan.id
        refiningPlan = false
        // Out of plan mode, asking before edits, as Approve does.
        session.setPlanning(false, askingBeforeEdits: true)
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
        let mentionOpen = referenceQuery != nil && AgentComposerSyntax.mention(in: text, caret: caret) != nil
        VStack(spacing: 0) {
            commandMenu(matches: matches, references: references, mentionOpen: mentionOpen)
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
                if !attachments.isEmpty || !extras.isEmpty {
                    ComposerAttachmentTray(images: attachments, extras: extras, cwd: session.cwd,
                                           removeImage: { attachments.remove(at: $0) },
                                           removeExtra: { extra in extras.removeAll { $0.id == extra.id } })
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
                            .font(ChatStyle.prompt)
                            .lineSpacing(ChatStyle.bodyLineSpacing)
                            .foregroundStyle(ChatStyle.placeholder)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    if commandMode {
                        // The box's own text goes clear and this draws it in
                        // the shell's colours, in the same place.
                        ShellPromptText(source: text)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    TextEditor(text: $text)
                        .font(commandMode ? Theme.Text.mono(13.5) : ChatStyle.prompt)
                        .lineSpacing(ChatStyle.bodyLineSpacing)
                        .foregroundStyle(commandMode ? Color.clear : ChatStyle.text)
                        .tint(commandMode ? ChatStyle.link : nil)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focused)
                        // One line and a half at rest, scrolling past 208.
                        .frame(minHeight: 34, maxHeight: 208)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topLeading) {
                            if spaceHold.listening { ListeningIndicator(heard: voice.partial) }
                        }
                        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                            holdSpace(press)
                        }
                        .onChange(of: focused) { _, isFocused in
                            // Files and images dropped on the box become tiles
                            // (the composer's own drop), not their paths typed in.
                            if isFocused { DispatchQueue.main.async { ComposerCaret.textView?.unregisterDraggedTypes() } }
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
                        .onKeyPress(keys: [.leftArrow]) { press in sendToBackground(press) }
                        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                            // ⌘↑ in an empty box: the prompt before, in the transcript.
                            if ComposerKeys.isCommandOnly(press.modifiers), text.isEmpty {
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
                            if ComposerKeys.isCommandOnly(press.modifiers), text.isEmpty {
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
                        .onChange(of: text) { old, new in
                            // A long paste becomes a tile, as ChatGPT does,
                            // rather than a wall of text in the box.
                            // Files dragged in that still landed as their paths
                            // become tiles too.
                            if let inserted = ChatAttachmentFormat.insertion(from: old, to: new),
                               let dragged = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL], !dragged.isEmpty,
                               dragged.allSatisfy({ inserted.text.contains($0.path) || inserted.text.contains($0.absoluteString) }) {
                                text = old
                                attach(files: dragged)
                                return
                            }
                            if let pasted = ChatAttachmentFormat.insertion(from: old, to: new),
                               ChatAttachmentFormat.collapses(pasted.text),
                               NSPasteboard.general.string(forType: .string).map({ pasted.text.contains($0) || $0.contains(pasted.text) }) == true {
                                extras.append(ComposerExtra(kind: .pasted(pasted.text)))
                                text = old
                                return
                            }
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
                        select: { choice in setMode(AgentSession.PermissionMode(rawValue: choice) ?? .default) },
                        panel: { close in
                            AnyView(PermissionModePanel(selected: session.permissionMode, detail: Self.modeDetail,
                                                        choose: { setMode($0) }, close: close))
                        }
                    ), state: dropdowns) { open in
                        ModeChip(mode: session.permissionMode, open: open)
                    }
                    .accessibilityLabel("Permission mode")
                    .accessibilityValue(session.permissionMode.title)
                    .help("How Claude asks before using tools. Changes apply from the next message.")
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
                    ComposerStashControls(project: session.cwd, text: $text, attachments: $attachments, dropdowns: dropdowns)
                    MCPProblemChip(session: session)
                    Spacer()
                    ContextWindowControl(session: session, dropdowns: dropdowns) {
                        window.newConversation(engine: session.engine)
                    }
                    // Remote Control (lit while it's on), the agent's own
                    // interface in the terminal, and attaching: one icon family.
                    HStack(spacing: 2) {
                        if session.engine == .claude, session.remoteControlAvailable || session.remoteControlEngaged {
                            RemoteControlControl(session: session, dropdowns: dropdowns)
                        }
                        ChatSymbolButton(symbol: "apple.terminal",
                                         help: "Continue this conversation in \(session.engine.displayName)'s own interface, in its terminal tab") {
                            window.continueInTerminal(session)
                        }
                        .disabled(session.conversation.items.isEmpty)
                        ChatSymbolButton(symbol: "paperclip", help: "Attach files or images (or paste or drop them here)") { pickFiles() }
                    }
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && extras.isEmpty
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
                            .accessibilityLabel(kind == .steer ? "Steer" : kind == .queue ? "Queue" : kind == .run ? "Run command" : bridge.editing == nil ? "Send" : "Update")
                    }
                }
            }
            // T3 Code's composer: a card floating in the chat column, rounded,
            // with a hairline and a soft drop under it.
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            // A `!` line lights the inside of the card with a soft blue
            // glow falling from its top middle (`CommandGlow`), no border.
            .background(composerShape.fill(ChatStyle.card)
                .overlay(alignment: .top) { CommandGlow(level: commandLevel).clipShape(composerShape) })
            .overlay(composerShape.strokeBorder(ChatStyle.composerOutline, lineWidth: 1))
            .onChange(of: commandRunnable) { _, ready in if ready { Haptics.step() } }

            // The inner top highlight; dark mode has no drop shadow.
            .overlay(alignment: .top) {
                Capsule().fill(Color.white.opacity(Theme.isLight ? 0 : 0.03)).frame(height: 1)
                    .padding(.horizontal, ChatStyle.composerRadius)
            }
            .shadow(color: .black.opacity(Theme.isLight ? 0.4 : 0), radius: 14, y: 12)
        }
        .padding(.top, 8)
        .onAppear {
            #if DEBUG
            if ConversationDebug.openDropdown == "command" {
                text = "! git log --oneline -5 | grep -i \"fix\" > /tmp/out.txt && echo $HOME"
            }
            if ConversationDebug.openDropdown == "reference" {
                text = "@"
                refreshReferences()
            }
            // Verification hook: tiles in the box, and a sent message carrying them.
            if ConversationDebug.openDropdown == "attachments" {
                let sample = (1...24).map { "line \($0) of the stack trace that was pasted in" }.joined(separator: "\n")
                extras = [ComposerExtra(kind: .file(session.cwd + "/README.md")),
                          ComposerExtra(kind: .file(session.cwd + "/report.pdf")),
                          ComposerExtra(kind: .pasted(sample))]
                text = "Why does this crash on launch?"
                session.conversation.items.append(AgentItem(id: "debug-sent", kind: .user(
                    ChatAttachmentFormat.compose("Here's the failing log and the spec, can you take a look?",
                                                 extras: extras, cwd: session.cwd))))
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

    /// Docked to the pane's sides and bottom, so only the top corners round.
    private var composerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: ChatStyle.composerRadius, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: ChatStyle.composerRadius,
                               style: .continuous)
    }

    /// `/` and `@` open T3 Code's command menu: a banner on the card's top
    /// edge, growing up out of it.
    @ViewBuilder
    private func commandMenu(matches: [SlashCommandSearch.Result], references: [AgentComposerSyntax.Reference],
                             mentionOpen: Bool) -> some View {
        if !matches.isEmpty || !references.isEmpty || mentionOpen {
            ChatBanner {
                if !matches.isEmpty {
                    SlashSuggestions(commands: matches,
                                     highlighted: min(highlighted, matches.count - 1),
                                     highlight: { highlighted = $0 }) { accept($0) }
                } else if !references.isEmpty {
                    ReferenceSuggestions(references: references,
                                         highlighted: min(highlighted, references.count - 1),
                                         highlight: { highlighted = $0 }) { accept($0) }
                } else if let query = referenceQuery {
                    NoReferenceMatches(query: query)
                }
            }
            .padding(.bottom, 8)
            .transition(motion.animates(.palette)
                ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                              removal: .opacity.combined(with: .offset(y: 4)))
                : .identity)
        }
    }

    /// A paste or drop: image data as an image, files by URL (images as
    /// images, anything else as a path). Says whether any of it could be
    /// taken; what fails to load is said, not dropped silently.

    /// ← on an empty message opens the agents board and sends this
    /// conversation to the background. A plain ← only, and not mid-turn:
    /// moving restarts the agent, which would cut the turn off.
    private func sendToBackground(_ press: KeyPress) -> KeyPress.Result {
        guard text.isEmpty, attachments.isEmpty, extras.isEmpty, !session.conversation.isRunning,
              press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]) else { return .ignored }
        AgentCenter.shared.sendToBackground(session)
        return .handled
    }
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
    /// The line starts with `!`: Return runs it in the shell, not the agent.
    private var commandMode: Bool { text.hasPrefix("!") && session.engine != .opencode }

    /// And there is a command after the `!` to run.
    private var commandRunnable: Bool {
        commandMode && !text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commandLevel: Int { commandRunnable ? 2 : commandMode ? 1 : 0 }

    private func sendKind(running: Bool) -> RoundComposerButton.Kind {
        if commandRunnable, !running, bridge.editing == nil { return .run }
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
        case .run:
            return "Run it in the shell (Return); its output goes to \(session.engine.displayName) with your next message"
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

    /// Shift-Tab: Claude's and Qwen's permission modes, OpenCode's two
    /// asking presets (allowing everything is only ever picked, never cycled
    /// into), and plan mode on or off for Codex and Pi, whose own settings
    /// have no mode to cycle. Says whether it did anything.
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
            session.setPlanning(!session.isPlanning)
            return true
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

    /// Bypass runs every tool without asking: it's confirmed first.
    private func setMode(_ mode: AgentSession.PermissionMode) {
        guard mode == .bypassPermissions, session.permissionMode != mode else {
            session.permissionMode = mode
            return
        }
        ConfirmCenter.shared.ask(
            title: "Bypass all permission checks?",
            message: "Claude will run commands, edit and delete files, and use every tool without asking you first, for the rest of this conversation. Use it only in a folder you can afford to lose changes in.",
            confirmTitle: "Bypass Permissions",
            destructive: true
        ) { _ in session.permissionMode = .bypassPermissions }
    }

    static let modeDetail: [AgentSession.PermissionMode: String] = [
        .default: "Asks before tools that change things",
        .acceptEdits: "Edits files without asking",
        .plan: "Reads and plans, changes nothing",
        .auto: "Decides for itself what needs asking",
        .bypassPermissions: "Never asks. Use with care",
    ]

    private func submit(confirmedLength: Bool = false, commandHeld: Bool = false) {
        // Pasted text and files go as the agent reads them; the bubble
        // shows them as tiles again.
        let message = ChatAttachmentFormat.compose(text, extras: extras, cwd: session.cwd)
        // The question the agent asked takes what's typed as its answer.
        if session.pendingPermission == nil, session.pendingQuestion != nil, questions.draft != nil, bridge.editing == nil {
            let typed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            questions.submit(typed: typed.isEmpty ? nil : typed, session: session)
            if !typed.isEmpty { text = "" }
            return
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let sentExtras = extras
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
            extras = []
            cancelEditing()
            return
        case .resend(let itemId, let revertFiles):
            guard !session.conversation.isRunning else {
                ToastCenter.shared.info("Wait for this turn to end",
                                        detail: "A message can be sent again from an earlier point once the agent stops.")
                return
            }
            let images = attachments
            extras = []
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
        if attachments.isEmpty, extras.isEmpty,
           let (command, arguments) = SlashCommands.invoked(message.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             in: session.slashCommands),
           command.handling != .agent {
            text = ""
            return run(command, arguments: arguments)
        }
        text = ""
        attachedPaths = false
        extras = []
        let images = attachments
        attachments = []
        // Mid-turn: steer by default where the engine can, ⌘ flipping it.
        let delivery: AgentSession.Delivery = session.canSteer && !commandHeld ? .steer : .queue
        // Diff review notes the person chose to send along go with it, once.
        let sent = session.send(ReviewNotesOutbox.shared.attach(to: message, cwd: session.cwd), attachments: images, delivery: delivery)
        // The agent wouldn't start: the draft comes back rather than vanishing.
        if !sent, text.isEmpty, attachments.isEmpty {
            text = ChatAttachmentFormat.parse(message).body
            extras = sentExtras
            attachments = images
        }
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
            OctetIcon("pencil", size: 12).foregroundStyle(ChatStyle.primary)
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
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(ChatStyle.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(ChatStyle.primary.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// An @ mention that matches no file.
private struct NoReferenceMatches: View {
    let query: String

    var body: some View {
        Text(query.isEmpty ? "No matching files or folders." : "No files or folders match “\(query)”.")
            .font(ChatStyle.meta)
            .foregroundStyle(ChatStyle.secondaryText)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Modifier checks for the composer's keys.
enum ComposerKeys {
    /// Only ⌘ held. Arrow keys also carry the numeric-pad and function
    /// flags, so an exact comparison never matched ⌘↑ or ⌘↓.
    static func isCommandOnly(_ modifiers: EventModifiers) -> Bool {
        modifiers.subtracting([.numericPad, .function, .capsLock]) == .command
    }
}

/// Esc stops a running turn from anywhere in the conversation, not only
/// from the message box. Text being edited and other views that take keys
/// (a terminal beside it, a web page) keep their own Esc. With two
/// conversations in one window (one beside the terminal, one over it), Esc
/// stops only the one last clicked or typed in, else the one over it.
@MainActor
final class ConversationEscape: ObservableObject {
    weak var session: AgentSession?
    weak var window: NSWindow?
    /// The conversation's own area of the window, to tell clicks and
    /// typing in it from those in the other one.
    weak var area: NSView?
    /// Something in the view takes Esc first: an enlarged image, a menu.
    var blocked = false
    /// Over the terminal rather than beside it.
    var inMainArea = true
    private var monitor: Any?

    /// A conversation showing in a window, for choosing which one Esc stops.
    struct Candidate: Equatable {
        let id: String
        let inMainArea: Bool
        /// Has something Esc can stop: a turn, or a `!` command.
        var busy = true
    }

    /// Every conversation's Esc that's listening, to find the others in
    /// the same window.
    private static var live: [WeakEscape] = []
    private struct WeakEscape { weak var escape: ConversationEscape? }
    /// The conversation last clicked or typed in, by window.
    private static var lastActive: [ObjectIdentifier: String] = [:]

    func start() {
        guard monitor == nil else { return }
        Self.live.removeAll { $0.escape == nil || $0.escape === self }
        Self.live.append(WeakEscape(escape: self))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true ? nil : event }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.live.removeAll { $0.escape == nil || $0.escape === self }
    }

    /// Which conversation Esc is for: the one last clicked or typed in,
    /// while it still shows, else the one over the terminal.
    static func target(among candidates: [Candidate], lastActive: String?) -> String? {
        // Esc is for stopping something: the one last used when it has
        // something running, else one that does, the main area's first.
        let busy = candidates.filter(\.busy)
        let pool = busy.isEmpty ? candidates : busy
        if let lastActive, pool.contains(where: { $0.id == lastActive }) { return lastActive }
        return (pool.first { $0.inMainArea } ?? pool.first)?.id
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let session, let window, event.window === window else { return false }
        noteActivity(event, session: session, window: window)
        guard event.type == .keyDown, !blocked, window.attachedSheet == nil,
              Self.isPlainEscape(keyCode: event.keyCode, flags: event.modifierFlags),
              !Self.takesEscape(window.firstResponder) else { return false }
        // Only one conversation in the window answers; the rest let it pass.
        let others = Self.live.compactMap(\.escape).filter { $0.window === window && $0.session != nil }
        let candidates = others.map { escape in
            Candidate(id: escape.session?.id ?? "", inMainArea: escape.inMainArea,
                      busy: escape.session.map { $0.conversation.isRunning || $0.shellRunning != nil } ?? false)
        }
        guard Self.target(among: candidates, lastActive: Self.lastActive[ObjectIdentifier(window)]) == session.id
        else { return false }
        // As in the message box: a `!` command first, then the turn.
        if session.shellRunning != nil {
            session.stopShell()
            return true
        }
        guard session.conversation.isRunning else { return false }
        session.interrupt()
        return true
    }

    /// A click in this conversation, or typing into something in it (its
    /// message box), makes it the one Esc stops.
    private func noteActivity(_ event: NSEvent, session: AgentSession, window: NSWindow) {
        guard let area, !area.isHiddenOrHasHiddenAncestor else { return }
        let frame = area.convert(area.bounds, to: nil)
        let inside: Bool
        if event.type == .keyDown {
            guard let view = window.firstResponder as? NSView, view.window === window else { return }
            let rect = view.convert(view.visibleRect, to: nil)
            inside = frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        } else {
            inside = frame.contains(event.locationInWindow)
        }
        if inside { Self.lastActive[ObjectIdentifier(window)] = session.id }
    }

    static func isPlainEscape(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty
    }

    /// Whether the view with the keyboard handles Esc itself: editable text
    /// (the message box, find, rename) or an AppKit view that isn't
    /// SwiftUI's own, such as a terminal. Selectable transcript text and
    /// SwiftUI's controls don't.
    static func takesEscape(_ responder: NSResponder?) -> Bool {
        guard let responder, !(responder is NSWindow) else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return !String(describing: type(of: responder)).contains("Hosting")
    }
}

/// Wires `ConversationEscape` to the conversation's window while it shows.
private struct EscapeStopsTurn: ViewModifier {
    let session: AgentSession
    let blocked: Bool
    let inMainArea: Bool
    @StateObject private var escape = ConversationEscape()

    func body(content: Content) -> some View {
        content
            .background(WindowReader(escape: escape))
            .onAppear {
                escape.session = session
                escape.start()
            }
            .onDisappear { escape.stop() }
            .onChange(of: blocked, initial: true) { _, now in escape.blocked = now }
            .onChange(of: inMainArea, initial: true) { _, now in escape.inMainArea = now }
    }

    private struct WindowReader: NSViewRepresentable {
        let escape: ConversationEscape

        func makeNSView(context: Context) -> Reader {
            let view = Reader()
            view.escape = escape
            return view
        }

        func updateNSView(_ view: Reader, context: Context) {}

        final class Reader: NSView {
            weak var escape: ConversationEscape?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                escape?.window = window
                escape?.area = self
            }
        }
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

/// Slash commands matching what's typed, after T3 Code's command menu:
/// the command in 12pt medium with the matched letters lit, what it does
/// beside it, where it comes from at the end.
private struct SlashSuggestions: View {
    let commands: [SlashCommandSearch.Result]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (SlashCommandSearch.Result) -> Void

    var body: some View {
        ChatCommandList(items: commands, highlighted: highlighted, highlight: highlight, choose: choose) { result, _ in
            let command = result.command
            ChatCommandRow(icon: { EmptyView() }, label: {
                MatchHighlightedText(text: command.insertion, indices: result.nameIndices,
                                     base: result.nameIndices.isEmpty ? ChatStyle.text : ChatStyle.secondaryText,
                                     lit: ChatStyle.text)
            }, description: command.summary.isEmpty ? command.argumentHint : command.summary,
               badge: command.origin.label)
        }
    }
}

/// Workspace files matching the unfinished @ mention: the file's own icon
/// and name, its folder beside it.
private struct ReferenceSuggestions: View {
    let references: [AgentComposerSyntax.Reference]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (AgentComposerSyntax.Reference) -> Void

    var body: some View {
        ChatCommandList(items: references, highlighted: highlighted, highlight: highlight, choose: choose) { reference, _ in
            let name = (reference.path as NSString).lastPathComponent
            let folder = (reference.path as NSString).deletingLastPathComponent
            ChatCommandRow(icon: {
                Group {
                    if reference.path.hasSuffix("/") {
                        OctetIcon("folder", size: 16).foregroundStyle(ChatStyle.secondaryText)
                    } else if let logo = LanguageLogo(path: reference.path, size: 14) {
                        logo
                    } else {
                        OctetIcon("doc", size: 16).foregroundStyle(ChatStyle.secondaryText)
                    }
                }
                .frame(width: 16)
            }, label: {
                Text(name.isEmpty ? reference.path : name)
            }, description: folder)
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
        PlanModeToggle(session: session)

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
        PlanModeToggle(session: session)

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
            MarkdownView(text: text, streaming: streaming, chat: true)
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
    enum Kind { case send, queue, steer, stop, run }
    let kind: Kind
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(kind == .stop ? ChatStyle.removed.opacity(hovered && enabled ? 1 : 0.9)
                              : kind == .run ? ChatStyle.link.opacity(hovered && enabled ? 1 : 0.92)
                              : hovered && enabled ? ChatStyle.primaryHover : ChatStyle.primary)
                switch kind {
                case .stop:
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 8, height: 8)
                default:
                    Image(systemName: Self.symbol(kind))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind == .run ? Color.white : ChatStyle.onPrimary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .overlay(alignment: .top) {
                // The lit top edge filled buttons have.
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 14, height: 1).padding(.top, 1)
            }
            .frame(width: ChatStyle.sendSize, height: ChatStyle.sendSize)
            .shadow(color: (kind == .stop ? ChatStyle.removed : kind == .run ? ChatStyle.link : ChatStyle.primary).opacity(enabled ? 0.24 : 0), radius: 1, y: 1)
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
        case .run: "play.fill"
        }
    }
}
