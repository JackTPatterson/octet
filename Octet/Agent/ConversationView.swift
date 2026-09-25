import Combine
import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(session: session, client: client)
            Rectangle().fill(Theme.divider).frame(height: 1)
            Transcript(session: session)
            if session.conversation.isRunning && session.pendingPermission == nil && session.pendingQuestion == nil {
                StatusLine(session: session)
            }
            // Interactive agent UI belongs to the input dock. Keeping it in
            // one clipped stack lets a new panel rise from behind the composer
            // instead of appearing as a detached card above it.
            VStack(spacing: 0) {
                if !session.queuedMessages.isEmpty {
                    QueuedMessagesPanel(items: session.queuedMessages)
                }
                let suggestedCommands = AgentComposerSyntax.suggestedShellCommands(in: session.conversation.items)
                if !session.conversation.isRunning, !suggestedCommands.isEmpty {
                    SuggestedCommandsPanel(session: session, commands: suggestedCommands)
                }
                if let question = session.pendingQuestion, session.pendingPermission == nil {
                    QuestionCard(session: session, question: question)
                        .id(question.id)
                        .zIndex(0)
                        .transition(motion.animates(.approvals)
                            ? .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
                            : .identity)
                }
                if let request = session.pendingPermission {
                    PermissionCard(session: session)
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
                Composer(session: session, dropdowns: dropdowns)
                    .zIndex(1)
            }
            .clipped()
        }
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
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            if id == "everything" { session.debugLoadEverything(); return }
            if id == "commands" { session.debugLoadSuggestedCommands(); return }
            if id == "queued" { session.debugLoadQueuedMessages(); return }
            if id == "monitor" || id == "monitor-detail" {
                session.debugLoadMonitor()
                window.ui.runtimePanelVisible = true
                if id == "monitor-detail" {
                    // Let the Runtime panel ingest the fixture entries before
                    // selecting one; an early selection is correctly cleared
                    // as stale while its list is still empty.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        window.ui.runtimeInspectorEntryID = "agent-agent-debug-call"
                    }
                }
                return
            }
            if id == "ultracode" { session.effort = "ultracode" }
            if id == "maxeffort" { session.effort = "max" }
            if id == "planmode" { session.permissionMode = .plan }
            let open = ["ultracode": "effort", "maxeffort": "effort", "planmode": "mode"][id] ?? id
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

    var body: some View {
        let conversation = session.conversation
        HStack(spacing: 10) {
            ProjectLocation(directory: session.cwd, branch: branch, worktree: workspace?.worktree)
            Spacer(minLength: 8)
            if let used = conversation.contextUsed {
                ContextMeter(used: used, window: conversation.contextWindow)
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
    static let tint = Color(hex: AgentStateColor.done)
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
                .foregroundStyle(Color(hex: AgentStateColor.done))
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    if changes.added > 0 {
                        Text("+\(changes.added)").foregroundStyle(Color(hex: AgentStateColor.done))
                    }
                    if changes.removed > 0 {
                        Text("-\(changes.removed)").foregroundStyle(Color(hex: AgentStateColor.blocked))
                    }
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
            return Color(hex: AgentStateColor.blocked)
        }
        if pullRequest.checks == .pending { return Theme.accent }
        return Color(hex: AgentStateColor.done)
    }
}

private struct ContextMeter: View {
    let used: Int
    let window: Int?

    var body: some View {
        let fraction = window.map { min(1, Double(used) / Double(max($0, 1))) }
        HStack(spacing: 6) {
            if let fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border).frame(width: 48, height: 4)
                    Capsule().fill(fraction > 0.85 ? Theme.danger : Theme.accent)
                        .frame(width: max(2, 48 * fraction), height: 4)
                }
            }
            Text(window.map { "\(Self.short(used)) / \(Self.short($0))" } ?? Self.short(used))
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .help("Context in use")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Self.short(used))\(window.map { " of \(Self.short($0))" } ?? "")")
    }

    static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        return tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }
}

// MARK: - Transcript

private struct Transcript: View {
    @ObservedObject var session: AgentSession
    @State private var atBottom = true

    var body: some View {
        let items = session.conversation.items
        let blocking = blockingState
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let blocking {
                        AgentBlockingState(session: session, state: blocking)
                    } else if items.isEmpty {
                        EmptyConversation(session: session)
                    }
                    if blocking == nil {
                        ForEach(items.filter(Self.isShown)) { item in
                            ItemRow(item: item, running: session.conversation.isRunning)
                                .equatable()
                                .padding(.leading, item.parent == nil ? 0 : 18)
                                .overlay(alignment: .leading) {
                                    if item.parent != nil {
                                        Rectangle().fill(Theme.border).frame(width: 2).padding(.leading, 6)
                                    }
                                }
                                .id(item.id)
                        }
                    }
                    // Visible only when scrolled to the end.
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .octetScrollIndicators()
            // Follow the stream only while at the end, so reading back isn't
            // yanked away; a button jumps to the latest instead.
            .onChange(of: items) { _, _ in
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            #if DEBUG
            .onAppear {
                guard let index = ConversationDebug.scrollToItem else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let shown = session.conversation.items.filter(Self.isShown)
                    guard !shown.isEmpty else { return }
                    proxy.scrollTo(shown[min(index, shown.count - 1)].id, anchor: .top)
                }
            }
            #endif
            .overlay(alignment: .bottom) {
                if !atBottom && !items.isEmpty {
                    OctetButton(title: "Jump to Latest", icon: "arrow.down", kind: .secondary, compact: true) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var blockingState: AgentBlockState? {
        let transcriptMessages = session.conversation.items.compactMap { item -> String? in
            switch item.kind {
            // A normal assistant answer can legitimately discuss resetting a
            // limit (retry code is a common example). Only lifecycle notices
            // and explicit errors are allowed to replace the transcript with
            // a blocking splash.
            case .notice(let text): return text
            default: return nil
            }
        }
        let messages = [session.startupError, session.conversation.lastError].compactMap { $0 }
            + Array(transcriptMessages.reversed())
        if let message = messages.first(where: { message in
            let lower = message.lowercased()
            return lower.contains("isn't installed") || lower.contains("not installed")
                || lower.contains("command not found") || lower.contains("no such file")
        }) {
            return AgentBlockState(title: "\(session.engine.displayName) isn’t installed", message: message)
        }
        guard let message = messages.first(where: { message in
            let lower = message.lowercased()
            return lower.contains("spend limit") || lower.contains("usage limit")
                || lower.contains("quota exceeded") || lower.contains("insufficient_quota")
                || (lower.contains("limit") && lower.contains("reset"))
        }) else { return nil }
        let parts = message.split(separator: "·").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines: [String] = []
        var actions: [AgentBlockAction] = []
        for part in parts {
            if let url = Self.link(in: part) {
                let lower = part.lowercased()
                let title = lower.contains("raise") ? "Raise limit"
                    : lower.contains("usage") || lower.contains("settings") ? "Manage usage" : "Open link"
                actions.append(AgentBlockAction(title: title, url: url))
            } else if !part.isEmpty {
                lines.append(Self.sentence(part))
            }
        }
        return AgentBlockState(title: "\(session.engine.displayName) usage limit reached",
                               message: lines.joined(separator: "\n"), actions: actions,
                               resetAt: Self.resetDate(in: message))
    }

    /// CLI notices sometimes omit the scheme (`claude.ai/settings/...`).
    /// Accept web-looking tokens, while leaving ordinary dotted prose alone.
    private static func link(in text: String) -> URL? {
        let token = text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "·,.;()")) }
            .first { value in
                value.hasPrefix("https://") || value.hasPrefix("http://")
                    || (value.contains(".") && value.contains("/"))
            }
        guard let token else { return nil }
        return URL(string: token.contains("://") ? token : "https://" + token)
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func resetDate(in message: String, now: Date = Date()) -> Date? {
        guard message.lowercased().contains("reset"),
              let expression = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#,
                                                        options: .caseInsensitive),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let hourRange = Range(match.range(at: 1), in: message),
              var hour = Int(message[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: message).flatMap { Int(message[$0]) } ?? 0
        let meridiem = Range(match.range(at: 3), in: message).map { message[$0].lowercased() } ?? "am"
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        let timezone = message.split(separator: "(").dropFirst().first
            .flatMap { $0.split(separator: ")").first }
            .flatMap { TimeZone(identifier: String($0)) }
            ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute),
                                 matchingPolicy: .nextTime)
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

private struct QueuedMessagesPanel: View {
    let items: [AgentItem]

    var body: some View {
        OctetPalettePanel {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    if case .user(let text) = item.kind {
                        HStack(alignment: .top, spacing: 8) {
                            OctetIcon("clock", size: 12).foregroundStyle(Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("QUEUED").font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                                Text(text).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(3).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if item.id != items.last?.id { Rectangle().fill(Theme.divider).frame(height: 1) }
                    }
                }
            }
        }
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
            message: "The commands will run through \(session.engine.displayName) in \(abbreviateHome(session.cwd)).",
            detail: commands.joined(separator: "\n"),
            confirmTitle: "Run"
        ) { _ in
            dismissed = true
            for command in commands { session.send("!" + command) }
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
                .font(.system(size: 15, weight: .semibold))
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
}

private struct AgentBlockAction: Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

private struct AgentBlockingState: View {
    @ObservedObject var session: AgentSession
    let state: AgentBlockState

    var body: some View {
        VStack(spacing: 12) {
            if let brand = AgentBrand.forAgent(session.engine.agent) {
                AgentLogo(brand: brand, size: 48)
            }
            Text(state.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(state.message)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let resetAt = state.resetAt {
                LimitCountdown(resetAt: resetAt)
            }
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
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item.queued ? Theme.accent.opacity(0.07) : Theme.card)
                .overlay {
                    if item.queued {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .text(let text):
            MarkdownView(text: text)
                .contextMenu { MessageCopyMenu(text: text) }
        case .thinking(let text):
            Disclosure(title: "Thinking", tint: Theme.textTertiary) {
                Text(text)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }
        case .tool(let call):
            ToolCard(call: call, running: running)
        case .notice(let text):
            if CompactionNotice.isCompaction(text) {
                CompactionNotice(text: text, running: running)
            } else if ErrorNotice.isError(text) {
                ErrorNotice(text: text)
            } else {
                Text(text)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Compaction is a conversation lifecycle event, not a low-priority log line.
/// Give it a stable place in the transcript while context is summarized.
private struct CompactionNotice: View {
    let text: String
    let running: Bool

    static func isCompaction(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("compact") && lower.contains("conversation")
    }

    private var complete: Bool { text.lowercased().contains("was compacted") }

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
                Circle().fill(Color(hex: AgentStateColor.blocked))
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
        .background(Color(hex: AgentStateColor.blocked).opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: AgentStateColor.blocked).opacity(0.38)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error. \(text)")
    }

    static func isError(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("couldn't") || lower.hasPrefix("could not")
            || lower.hasPrefix("failed") || lower.hasPrefix("error")
            || lower.hasPrefix("unable") || lower.contains(" answered 4")
            || lower.contains(" answered 5") || lower.contains(" exited (")
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

private struct ToolCard: View {
    let call: AgentToolCall
    let running: Bool
    @State private var startLine: Int?

    var body: some View {
        let diff = call.diff
        // Edits show their diff straight away; other calls stay one line.
        let todos = call.todos
        let subtitle = todos.map { list in "\(list.filter { $0.state == .completed }.count) of \(list.count) done" } ?? call.summary
        Disclosure(title: call.displayName, subtitle: subtitle, tint: call.isError ? Theme.danger : Theme.textSecondary,
                   icon: call.iconName, logo: LanguageLogo(path: call.filePath),
                   highlightsShell: call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
                   initiallyOpen: diff != nil || todos != nil || !call.resultImages.isEmpty, trailing: { status(diff) }) {
            VStack(alignment: .leading, spacing: 8) {
                if let todos {
                    TodoList(todos: todos)
                } else if let diff {
                    DiffView(lines: diff, path: call.filePath, startLine: startLine)
                        .task(id: call.inputData) { startLine = await call.fileStartLine() }
                } else if !call.input.isEmpty {
                    CodePanel(text: call.input, language: "input", tint: Theme.textSecondary, maxLines: 10, highlights: false)
                }
                if !call.resultImages.isEmpty {
                    ImageGallery(images: call.resultImages)
                }
                if let result = call.result, !result.isEmpty, todos == nil, diff == nil || call.isError {
                    CodePanel(text: result, language: call.isError ? "error" : "output",
                              tint: call.isError ? Theme.danger : Theme.textSecondary, maxLines: 14, highlights: false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.card.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            } else if call.isError {
                OctetIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(Theme.danger)
            } else if call.result != nil {
                OctetIcon("checkmark", size: 13).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// A one-line header that expands to show detail.
private struct Disclosure<Trailing: View, Content: View>: View {
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
                            Text(subtitle)
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
            rendered = rendered + Text(String(source[span.range])).foregroundStyle(color(for: span.role))
            cursor = span.range.upperBound
        }
        if cursor < source.endIndex {
            rendered = rendered + Text(String(source[cursor...])).foregroundStyle(Theme.textTertiary)
        }
        return rendered
    }

    private func color(for role: ShellSyntax.Role) -> Color {
        switch role {
        case .command: Theme.accent
        case .builtin: Theme.palette.color(\.syntaxBuiltin)
        case .flag: Theme.palette.color(\.syntaxFlag)
        case .string: Theme.palette.color(\.syntaxString)
        case .path: Theme.palette.color(\.syntaxPath)
        case .variable: Theme.palette.color(\.syntaxVariable)
        case .assignment: Theme.palette.color(\.syntaxVariable)
        case .reserved: Theme.palette.color(\.syntaxBuiltin)
        case .expansion: Theme.palette.color(\.syntaxVariable)
        case .glob: Theme.palette.color(\.syntaxPath)
        case .redirect, .separator: Theme.textSecondary
        case .comment, .argument: Theme.textTertiary
        }
    }
}

// MARK: - Permission

/// Questions OpenCode's agent is waiting on: pick an option (or several),
/// or type an answer of your own where it takes one. Skipping tells the agent
/// no answer is coming, which ends its turn.
private struct QuestionCard: View {
    @ObservedObject var session: AgentSession
    let question: OpenCodeQuestion
    @State private var picked: [Int: Set<String>] = [:]
    @State private var typed: [Int: String] = [:]

    var body: some View {
        OctetPalettePanel {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(question.items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        if !item.header.isEmpty {
                            Text(item.header.uppercased())
                                .font(Theme.headerFont)
                                .kerning(0.4)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(item.question)
                            .font(Theme.uiFontMedium)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(item.options, id: \.label) { option in
                            optionRow(option, item: item, index: index)
                        }
                        if item.custom {
                            OctetTextField(placeholder: item.options.isEmpty ? "Your answer" : "Or type your own answer",
                                          text: Binding(get: { typed[index] ?? item.initial }, set: { typed[index] = $0 }),
                                          secure: item.secret) {
                                if ready { answer() }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    OctetButton(title: "Skip", kind: .secondary) { session.rejectQuestion(question) }
                        .keyboardShortcut(.cancelAction)
                        .help("Tell the agent you won't answer; its turn ends")
                    OctetButton(title: "Answer", kind: .primary) { answer() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready)
                }
            }
            .padding(12)
        }
    }

    private func optionRow(_ option: OpenCodeQuestion.Item.Option, item: OpenCodeQuestion.Item, index: Int) -> some View {
        let selected = picked[index]?.contains(option.label) == true
        return Button {
            var set = picked[index] ?? []
            if item.multiple {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = selected ? [] : [option.label]
            }
            picked[index] = set
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: item.multiple ? 3 : 7)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: item.multiple ? 3 : 7).fill(selected ? Theme.accent.opacity(0.35) : .clear))
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    if !option.description.isEmpty {
                        Text(option.description).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One answer per question: the options picked, or what was typed.
    private var answers: [[String]] {
        question.items.indices.map { index in
            let text = (typed[index] ?? question.items[index].initial).trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = question.items[index].options.map(\.label).filter { picked[index]?.contains($0) == true }
            return text.isEmpty ? chosen : chosen + [text]
        }
    }

    private var ready: Bool { answers.allSatisfy { !$0.isEmpty } }

    private func answer() {
        guard ready else { return }
        session.answerQuestion(question, answers: answers)
    }
}

private struct PermissionCard: View {
    @ObservedObject var session: AgentSession
    @State private var note = ""
    @State private var showInput = false

    var body: some View {
        if let request = session.pendingPermission {
            OctetPalettePanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        OctetIcon("exclamationmark.triangle.fill", size: 15).foregroundStyle(Theme.accent)
                        Text("Allow \(request.toolName)?")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let path = request.inputObject["file_path"] as? String {
                            LanguageLogo(path: path)
                            Text((path as NSString).lastPathComponent)
                                .font(Theme.monoFont)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    if let diff = AgentToolCall.diff(tool: request.toolName, input: request.inputObject) {
                        DiffView(lines: diff, path: request.inputObject["file_path"] as? String,
                                 startLine: AgentToolCall.startLine(tool: request.toolName, input: request.inputObject, applied: false),
                                 maxLines: 14)
                    } else if !request.summary.isEmpty {
                        CodePanel(text: request.summary, language: request.toolName, maxLines: 8)
                    }
                    OctetButton(title: showInput ? "Hide details" : "Show details",
                               icon: showInput ? "chevron.down" : "chevron.right", kind: .ghost, compact: true) {
                        showInput.toggle()
                    }
                    if showInput { CodePanel(text: request.input, language: "input", tint: Theme.textSecondary, maxLines: 12, highlights: false) }
                    HStack(spacing: 8) {
                        // Claude Code carries a note back with a refusal; Codex's
                        // answer is only a decision, so a note there would vanish.
                        if session.engine != .codex {
                            OctetTextField(placeholder: session.engine == .opencode
                                            ? "Note for OpenCode when denying (optional; without one the turn stops)"
                                            : "Note for Claude when denying (optional)", text: $note) {
                                session.answerPermission(allow: false, note: note)
                                note = ""
                            }
                        } else {
                            Spacer()
                        }
                        OctetButton(title: "Deny", kind: .secondary) {
                            session.answerPermission(allow: false, note: note)
                            note = ""
                        }
                        .keyboardShortcut(.cancelAction)
                        OctetButton(title: AgentSession.sessionAllowTitle(request), kind: .secondary) {
                            session.answerPermission(allow: true, forSession: true)
                            note = ""
                        }
                        .help("Allow this now and stop asking about it until the conversation closes")
                        OctetButton(title: "Allow", kind: .primary) {
                            session.answerPermission(allow: true)
                            note = ""
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
            }
            .onAppear {
                AccessibilityNotification.Announcement("\(session.engine.displayName) asks to use \(request.toolName)").post()
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState
    @EnvironmentObject private var window: WindowContext
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    @State private var attachments: [AgentSession.Attachment] = []
    @State private var referenceSuggestions: [AgentComposerSyntax.Reference] = []
    @State private var referenceTask: Task<Void, Never>?
    @ObservedObject private var motion = MotionPreferences.shared
    /// The commands on show, changed inside an animation so the list, the
    /// composer card around it and the transcript above all move together.
    @State private var shownSuggestions: [SlashCommand] = []

    private func attach(_ images: [NSImage]) {
        attachments += images.compactMap(AgentSession.Attachment.init(image:))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attach(panel.urls.compactMap(NSImage.init(contentsOf:)))
    }

    /// Commands matching a `/` at the start of the message, until a space.
    private var suggestions: [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n"), dismissedFor != text else { return [] }
        return Array(SlashCommands.matching(String(text.dropFirst()), in: session.slashCommands).prefix(8))
    }

    private func refreshSuggestions() {
        let next = suggestions
        guard next.map(\.id) != shownSuggestions.map(\.id) else { return }
        motion.perform(.palette, .smooth(duration: 0.22)) { shownSuggestions = next }
    }

    private func refreshReferences() {
        referenceTask?.cancel()
        guard let mention = AgentComposerSyntax.mention(in: text) else {
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
            motion.perform(.palette, .smooth(duration: 0.22)) {
                referenceSuggestions = matches
                highlighted = min(highlighted, max(0, matches.count - 1))
            }
        }
    }

    private func accept(_ reference: AgentComposerSyntax.Reference) {
        guard let mention = AgentComposerSyntax.mention(in: text) else { return }
        text.replaceSubrange(mention.range, with: "@" + reference.path + " ")
        referenceSuggestions = []
        highlighted = 0
    }

    private func accept(_ command: SlashCommand) {
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
        case "effort": dropdowns.openId = "effort"
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
            return AgentSession.models.first { $0.id.lowercased() == needle || $0.family.lowercased() == needle }?.id
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
        VStack(spacing: 8) {
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
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message \(session.engine.displayName)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 22, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.tab) {
                        // Tab cycles OpenCode's agents, as in its own interface.
                        guard session.engine == .opencode, suggestions.isEmpty else { return .ignored }
                        let agents = OpenCodeCatalogStore.shared.catalog(for: session.cwd).agents
                        guard agents.count > 1 else { return .ignored }
                        let current = agents.firstIndex { $0.name == (session.agentName ?? agents[0].name) } ?? 0
                        let next = agents[(current + 1) % agents.count]
                        session.agentName = next.name == agents[0].name ? nil : next.name
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends (or takes the highlighted command); Shift-Return adds a line.
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        let matches = suggestions
                        if !references.isEmpty {
                            accept(references[min(highlighted, references.count - 1)])
                        } else if !matches.isEmpty {
                            accept(matches[min(highlighted, matches.count - 1)])
                        } else {
                            submit()
                        }
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { press in
                        // Shift-Tab cycles permission modes, as in Claude Code.
                        if press.modifiers.contains(.shift) {
                            let cycle = ModeStyle.cycle
                            let index = cycle.firstIndex(of: session.permissionMode) ?? -1
                            session.permissionMode = cycle[(index + 1) % cycle.count]
                            return .handled
                        }
                        let matches = suggestions
                        if !references.isEmpty {
                            accept(references[min(highlighted, references.count - 1)])
                        } else {
                            guard !matches.isEmpty else { return .ignored }
                            accept(matches[min(highlighted, matches.count - 1)])
                        }
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        // ← on an empty message opens the agents board and
                        // sends this conversation to the background.
                        guard text.isEmpty, attachments.isEmpty else { return .ignored }
                        AgentCenter.shared.sendToBackground(session)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        let count = referenceSuggestions.isEmpty ? suggestions.count : referenceSuggestions.count
                        guard count > 0 else { return .ignored }
                        highlighted = (min(highlighted, count - 1) - 1 + count) % count
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        let count = referenceSuggestions.isEmpty ? suggestions.count : referenceSuggestions.count
                        guard count > 0 else { return .ignored }
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
                        guard running else { return .ignored }
                        confirmInterrupt()
                        return .handled
                    }
                    .onChange(of: text) { _, _ in
                        highlighted = 0
                        refreshSuggestions()
                        refreshReferences()
                    }
                    .onChange(of: session.piEditorRequest?.id) { _, _ in
                        guard let request = session.piEditorRequest else { return }
                        text = request.text
                        focused = true
                    }
                    .accessibilityLabel("Message \(session.engine.displayName)")
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
                    searchPlaceholder: "Search models…"
                ), label: "Model", state: dropdowns)
                // Effort, in Claude Code's own colors and scale.
                EffortControl(session: session, dropdowns: dropdowns)
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
                } else if let brand = AgentBrand.forAgent(session.engine.agent) {
                    HStack(spacing: 5) {
                        AgentLogo(brand: brand, size: 12)
                        Text("Using \(session.engine.displayName) settings")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                OctetButton(title: "", icon: "paperclip", kind: .ghost, compact: true) { pickImages() }
                    .help("Attach images (or paste or drop them here)")
                    .accessibilityLabel("Attach images")
                Spacer()
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                if running {
                    OctetButton(title: "Stop", icon: "pause.circle", kind: .secondary, compact: true) { confirmInterrupt() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop this turn (Esc or ⌘.)")
                }
                if !running || !empty {
                    // While Claude works, a message queues for the next turn.
                    OctetButton(title: running ? "Queue" : "Send", icon: "arrow.up", kind: .primary, compact: true) { submit() }
                        .disabled(empty)
                        .help(running ? "Send when this turn ends (Return)" : "Send (Return)")
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .onAppear {
            #if DEBUG
            if ConversationDebug.openDropdown == "reference" {
                text = "@"
                refreshReferences()
            }
            #endif
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { referenceTask?.cancel() }
        .onPasteCommand(of: [.image, .fileURL]) { providers in load(providers) }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            load(providers)
            return true
        }
    }

    /// Images from a paste or drop: image data, or image files by URL.
    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { attach([image]) }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let image = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async { attach([image]) }
                }
            }
        }
    }

    static let modeDetail: [AgentSession.PermissionMode: String] = [
        .default: "Asks before tools that change things",
        .acceptEdits: "Edits files without asking",
        .plan: "Reads and plans, changes nothing",
        .auto: "Decides for itself what needs asking",
        .bypassPermissions: "Never asks. Use with care",
    ]

    private func submit() {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        if attachments.isEmpty,
           let (command, arguments) = SlashCommands.invoked(message.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             in: session.slashCommands),
           command.handling != .agent {
            text = ""
            return run(command, arguments: arguments)
        }
        text = ""
        let images = attachments
        attachments = []
        session.send(message, attachments: images)
    }

    private func confirmInterrupt() {
        ConfirmCenter.shared.ask(
            title: "Stop the current action?",
            message: "\(session.engine.displayName)'s current response and active tool work will be interrupted. Queued messages stay queued.",
            confirmTitle: "Stop",
            destructive: true
        ) { _ in session.interrupt() }
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

/// Slash commands matching what's typed, above the message field.
private struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (SlashCommand) -> Void

    var body: some View {
        OctetPalettePanel(divider: .bottom) {
            OctetAnimatedList(items: commands, highlighted: highlighted, highlight: highlight, choose: choose) { command, _ in
                HStack(spacing: 10) {
                    Text(command.insertion)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textPrimary)
                    if !command.summary.isEmpty {
                        Text(command.summary)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
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

/// What Claude is doing and for how long, while a turn runs.
private struct StatusLine: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            LoadingLine(width: 14)
            Text(session.activity)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let started = session.turnStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(started)))
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text("Esc to stop")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
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
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
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
private struct ImageGallery: View {
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
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
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
                        .foregroundStyle(todo.state == .completed ? Theme.accent
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
            searchPlaceholder: "Search models…"
        ), label: "Model", state: dropdowns)
        .disabled(catalog.models.isEmpty)

        // Codex names its efforts as Claude Code does, up to "ultra" where
        // Claude has "ultracode", so the same slider drives both.
        if let model, !model.efforts.isEmpty {
            let spec = OctetDropdownSpec(
                id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
                panel: { close in
                    AnyView(EffortSliderPanel(initial: session.effort, implicit: model.defaultEffort,
                                              levels: model.efforts, detail: model.effortDetail,
                                              apply: { session.effort = $0 }, close: close))
                }
            )
            OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
                EffortChip(level: session.effort, implicit: model.defaultEffort, open: open)
            }
            .help("How hard Codex thinks. Applies at once.")
            .accessibilityLabel("Effort")
            .accessibilityValue(session.effort ?? "default")
        }

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

/// The effort chip, opening Octet's slider panel above the composer.
private struct EffortControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState

    var body: some View {
        let spec = OctetDropdownSpec(
            id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
            panel: { close in
                AnyView(EffortSliderPanel(initial: session.effort, implicit: AgentSession.defaultEffort(model: session.model),
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
        .help(supported ? "How hard Claude thinks. Applies from the next message." : "This model has no effort setting.")
        .accessibilityLabel("Effort")
        .accessibilityValue(session.effort ?? "default")
    }
}
