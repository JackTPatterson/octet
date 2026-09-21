import SwiftUI

/// A native conversation with Claude Code or Codex, drawn in place of the
/// terminal: a streaming transcript, a permission sheet when the agent asks,
/// and a composer, with the model, effort and mode pickers Claude Code takes.
struct ConversationView: View {
    @ObservedObject var session: AgentSession
    let client: EngineClient
    @StateObject private var dropdowns = HerdDropdownState()
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var enlarged: Data?

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(session: session, client: client)
            Rectangle().fill(Theme.divider).frame(height: 1)
            Transcript(session: session)
            if session.conversation.isRunning && session.pendingPermission == nil {
                StatusLine(session: session)
            }
            if let request = session.pendingPermission {
                PermissionCard(session: session)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    // Keyed by request, so each one fades up in its own right,
                    // including the next queued one after an answer.
                    .id(request.id)
                    .transition(motion.animates(.approvals)
                        ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity)
                        : .identity)
            }
            Composer(session: session, dropdowns: dropdowns)
        }
        .animation(motion.animation(.approvals, .smooth(duration: 0.26)), value: session.pendingPermission?.id)
        .background(Theme.terminalBackground)
        .herdDropdownHost(dropdowns)
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
            if id == "sample" { session.debugLoadSample(); return }
            if id == "everything" { session.debugLoadEverything(); return }
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
    @ObservedObject var session: AgentSession
    let client: EngineClient
    @ObservedObject private var accounts = AccountStore.shared

    var body: some View {
        let conversation = session.conversation
        HStack(spacing: 10) {
            if let brand = AgentBrand.forAgent(session.engine.agent) { AgentLogo(brand: brand, size: 14) }
            Text(session.title)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(abbreviateHome(session.cwd))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
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
            HerdButton(title: "Open in Terminal", icon: "terminal", kind: .ghost, compact: true) {
                session.openInTerminal(client: client)
            }
            .disabled(conversation.items.isEmpty)
                .help("Continue this conversation in \(session.engine.displayName)'s own interface, in a new tab")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.chrome)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        EmptyConversation(session: session)
                    }
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
                    // Visible only when scrolled to the end.
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    HerdButton(title: "Jump to Latest", icon: "arrow.down", kind: .secondary, compact: true) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.bottom, 10)
                }
            }
        }
    }
}

extension Transcript {
    /// Thinking blocks arrive empty when the model keeps its reasoning to
    /// itself; there's nothing to expand.
    static func isShown(_ item: AgentItem) -> Bool {
        if case .thinking(let text) = item.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }
}

private struct EmptyConversation: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New conversation")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(session.engine == .codex
                 ? "Codex works in \(abbreviateHome(session.cwd)) with your usual config, and asks for what it needs inside its own sandbox."
                 : "Claude Code works in \(abbreviateHome(session.cwd)) with your usual settings, hooks and MCP servers. Tool calls that need permission ask you here.")
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

/// Equatable so rows that didn't change skip re-rendering while the last
/// one streams.
struct ItemRow: View, Equatable {
    let item: AgentItem
    let running: Bool

    var body: some View {
        switch item.kind {
        case .user(let text):
            VStack(alignment: .leading, spacing: 8) {
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
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .text(let text):
            MarkdownView(text: text)
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
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
        }
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
                HerdIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(Theme.danger)
            } else if call.result != nil {
                HerdIcon("checkmark", size: 13).foregroundStyle(Theme.textTertiary)
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
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @State private var open: Bool

    init(title: String, subtitle: String = "", tint: Color, icon: String? = nil, logo: LanguageLogo? = nil,
         initiallyOpen: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.icon = icon
        self.logo = logo
        _open = State(initialValue: initiallyOpen)
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    HerdIcon("chevron.right", size: 11)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    if let icon { HerdIcon(icon, size: 14).foregroundStyle(Theme.textTertiary) }
                    Text(title).font(Theme.uiFontMedium).foregroundStyle(tint)
                    if let logo { logo }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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

// MARK: - Permission

private struct PermissionCard: View {
    @ObservedObject var session: AgentSession
    @State private var note = ""
    @State private var showInput = false

    var body: some View {
        if let request = session.pendingPermission {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    HerdIcon("exclamationmark.triangle.fill", size: 15).foregroundStyle(Theme.accent)
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
                HerdButton(title: showInput ? "Hide details" : "Show details",
                           icon: showInput ? "chevron.down" : "chevron.right", kind: .ghost, compact: true) {
                    showInput.toggle()
                }
                if showInput { CodePanel(text: request.input, language: "input", tint: Theme.textSecondary, maxLines: 12, highlights: false) }
                HStack(spacing: 8) {
                    // Claude Code carries a note back with a refusal; Codex's
                    // answer is only a decision, so a note there would vanish.
                    if session.engine == .claude {
                        HerdTextField(placeholder: "Note for Claude when denying (optional)", text: $note) {
                            session.answerPermission(allow: false, note: note)
                            note = ""
                        }
                    } else {
                        Spacer()
                    }
                    HerdButton(title: "Deny", kind: .secondary) {
                        session.answerPermission(allow: false, note: note)
                        note = ""
                    }
                    .keyboardShortcut(.cancelAction)
                    HerdButton(title: AgentSession.sessionAllowTitle(request), kind: .secondary) {
                        session.answerPermission(allow: true, forSession: true)
                        note = ""
                    }
                    .help("Allow this now and stop asking about it until the conversation closes")
                    HerdButton(title: "Allow", kind: .primary) {
                        session.answerPermission(allow: true)
                        note = ""
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                AccessibilityNotification.Announcement("\(session.engine.displayName) asks to use \(request.toolName)").post()
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: HerdDropdownState
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    @State private var attachments: [AgentSession.Attachment] = []

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

    private func accept(_ command: SlashCommand) {
        text = command.insertion + " "
        highlighted = 0
    }

    var body: some View {
        let running = session.conversation.isRunning
        let matches = suggestions
        VStack(spacing: 8) {
            if !matches.isEmpty {
                SlashSuggestions(commands: matches, highlighted: min(highlighted, matches.count - 1)) { accept($0) }
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
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends (or takes the highlighted command); Shift-Return adds a line.
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        let matches = suggestions
                        if !matches.isEmpty {
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
                        guard !matches.isEmpty else { return .ignored }
                        accept(matches[min(highlighted, matches.count - 1)])
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
                        let count = suggestions.count
                        guard count > 0 else { return .ignored }
                        highlighted = (min(highlighted, count - 1) - 1 + count) % count
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        let count = suggestions.count
                        guard count > 0 else { return .ignored }
                        highlighted = (min(highlighted, count - 1) + 1) % count
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !suggestions.isEmpty else { return .ignored }
                        dismissedFor = text
                        return .handled
                    }
                    .onChange(of: text) { _, _ in highlighted = 0 }
                    .accessibilityLabel("Message \(session.engine.displayName)")
            }
            HStack(spacing: 6) {
                // Model, effort and permission mode are Claude Code's own
                // settings, passed as flags when Herd starts it. Codex reads
                // its config and runs its own approvals, so it shows none.
                if session.engine == .claude {
                HerdDropdown(spec: HerdDropdownSpec(
                    id: "model",
                    options: AgentSession.models.map {
                        HerdDropdownOption(id: $0.id, title: $0.title, detail: $0.detail, section: $0.family)
                    },
                    selected: session.model,
                    select: { session.model = $0 }
                ), label: "Model", state: dropdowns)
                // Effort, in Claude Code's own colors and scale.
                EffortControl(session: session, dropdowns: dropdowns)
                HerdDropdownAnchor(spec: HerdDropdownSpec(
                    id: "mode",
                    options: AgentSession.PermissionMode.allCases.map {
                        HerdDropdownOption(id: $0.rawValue, title: $0.title, detail: Self.modeDetail[$0],
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
                } else {
                    CodexControls(session: session, dropdowns: dropdowns)
                }
                HerdButton(title: "", icon: "paperclip", kind: .ghost, compact: true) { pickImages() }
                    .help("Attach images (or paste or drop them here)")
                    .accessibilityLabel("Attach images")
                Spacer()
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                if running {
                    HerdButton(title: "Stop", icon: "pause.circle", kind: .secondary, compact: true) { session.interrupt() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop this turn (⌘.)")
                }
                if !running || !empty {
                    // While Claude works, a message queues for the next turn.
                    HerdButton(title: running ? "Queue" : "Send", icon: "arrow.up", kind: .primary, compact: true) { submit() }
                        .disabled(empty)
                        .help(running ? "Send when this turn ends (Return)" : "Send (Return)")
                }
            }
        }
        .padding(12)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .onAppear { DispatchQueue.main.async { focused = true } }
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
        text = ""
        let images = attachments
        attachments = []
        session.send(message, attachments: images)
    }
}

/// Slash commands matching what's typed, above the message field.
private struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let highlighted: Int
    let choose: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(index == highlighted ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
                .contentShape(Rectangle())
                .onTapGesture { choose(command) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == highlighted ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
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
            Text("⌘. to stop")
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
                                        HerdIcon("xmark", size: 13)
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
                    HerdIcon(icon(todo.state), size: 14)
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
    @ObservedObject var dropdowns: HerdDropdownState
    @ObservedObject private var catalog = CodexCatalogStore.shared

    var body: some View {
        let model = catalog.model(session.model)
        HerdDropdown(spec: HerdDropdownSpec(
            id: "model",
            options: catalog.models.map {
                HerdDropdownOption(id: $0.id, title: $0.displayName, detail: $0.description)
            },
            selected: model?.id ?? "",
            select: { session.model = $0 }
        ), label: "Model", state: dropdowns)
        .disabled(catalog.models.isEmpty)

        // Codex names its efforts as Claude Code does, up to "ultra" where
        // Claude has "ultracode", so the same slider drives both.
        if let model, !model.efforts.isEmpty {
            let spec = HerdDropdownSpec(
                id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
                panel: { close in
                    AnyView(EffortSliderPanel(initial: session.effort, implicit: model.defaultEffort,
                                              levels: model.efforts, detail: model.effortDetail,
                                              apply: { session.effort = $0 }, close: close))
                }
            )
            HerdDropdownAnchor(spec: spec, state: dropdowns) { open in
                EffortChip(level: session.effort, implicit: model.defaultEffort, open: open)
            }
            .help("How hard Codex thinks. Applies at once.")
            .accessibilityLabel("Effort")
            .accessibilityValue(session.effort ?? "default")
        }

        if !catalog.profiles.isEmpty {
            let options = [HerdDropdownOption(id: SandboxStyle.unset, title: "From your config",
                                              detail: "Whatever ~/.codex says, unchanged")]
                + catalog.profiles.map {
                    HerdDropdownOption(id: $0.id, title: $0.title, detail: $0.detail, dangerous: $0.isDangerous,
                                       tint: SandboxStyle.color($0.id), glyph: SandboxStyle.glyph($0.id))
                }
            HerdDropdownAnchor(spec: HerdDropdownSpec(
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

/// The effort chip, opening Herd's slider panel above the composer.
private struct EffortControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: HerdDropdownState

    var body: some View {
        let spec = HerdDropdownSpec(
            id: "effort", options: [], selected: session.effort ?? "", select: { _ in },
            panel: { close in
                AnyView(EffortSliderPanel(initial: session.effort, implicit: AgentSession.defaultEffort(model: session.model),
                                          apply: { session.effort = $0 }, close: close))
            }
        )
        let supported = AgentSession.supportsEffort(model: session.model)
        HerdDropdownAnchor(spec: spec, state: dropdowns) { open in
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
