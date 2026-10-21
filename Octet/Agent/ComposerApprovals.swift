import SwiftUI

// MARK: - Questions

/// The answers to the question on show, shared by its banner and the
/// composer: the composer's number keys pick options, and what's typed in
/// it is the free-text answer.
@MainActor
final class QuestionDraftModel: ObservableObject {
    @Published private(set) var draft: AgentQuestionDraft?
    /// A single-choice pick moves on after a beat, so the pick is seen.
    private var advanceTask: Task<Void, Never>?

    /// Follows the session's question: a new one starts a new draft.
    func sync(_ question: OpenCodeQuestion?) {
        guard draft?.question.id != question?.id else { return }
        advanceTask?.cancel()
        draft = question.map(AgentQuestionDraft.init)
    }

    func pick(_ label: String, session: AgentSession) {
        guard var draft else { return }
        let settled = draft.pick(label)
        self.draft = draft
        if settled { advanceSoon(session: session) }
    }

    /// The number keys: true when `number` was an option.
    func pick(number: Int, session: AgentSession) -> Bool {
        guard var draft, let settled = draft.pick(number: number) else { return false }
        self.draft = draft
        if settled { advanceSoon(session: session) }
        return true
    }

    func type(_ text: String) {
        draft?.type(text)
    }

    /// Return in the composer: `text` becomes the item's typed answer, and
    /// the draft moves on, or is sent from its last item.
    func submit(typed text: String?, session: AgentSession) {
        guard var draft else { return }
        if let text, draft.item.custom { draft.type(text) }
        self.draft = draft
        next(session: session)
    }

    /// On to the next item, or the answers go once the last one is done.
    func next(session: AgentSession) {
        advanceTask?.cancel()
        guard var draft, draft.canAdvance else { return }
        if draft.advance() {
            self.draft = draft
        } else if draft.isComplete {
            session.answerQuestion(draft.question, answers: draft.answers)
        }
    }

    func back() {
        advanceTask?.cancel()
        draft?.back()
    }

    private func advanceSoon(session: AgentSession) {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.next(session: session)
        }
    }
}

/// A question the agent is waiting on, docked on the composer's top edge:
/// one item at a time with its numbered options, "2/5" when there are
/// several. Number keys pick, a single pick moves on, and the composer
/// below takes a typed answer. Skipping tells the agent no answer is
/// coming, which ends its turn.
struct QuestionBanner: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var model: QuestionDraftModel
    let question: OpenCodeQuestion

    var body: some View {
        if let draft = model.draft, draft.question.id == question.id {
            let item = draft.item
            OctetPalettePanel {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack(spacing: Theme.Space.sm) {
                        OctetIcon("questionmark.circle", size: 13).foregroundStyle(Theme.accent)
                        Text(item.header.isEmpty ? "\(session.engine.displayName) asks" : item.header)
                            .font(Theme.Text.captionMedium)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Space.md)
                        if let progress = draft.progress {
                            Text(progress)
                                .font(Theme.Text.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityLabel("Question \(progress.replacingOccurrences(of: "/", with: " of "))")
                        }
                    }
                    Text(item.question)
                        .font(Theme.Text.transcriptMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.options.enumerated()), id: \.offset) { offset, option in
                            optionRow(option, number: offset + 1, item: item, draft: draft)
                        }
                    }
                    if item.custom, item.secret {
                        OctetTextField(placeholder: "Your answer",
                                       text: Binding(get: { model.draft?.typedAnswer() ?? "" }, set: { model.type($0) }),
                                       secure: true) {
                            model.next(session: session)
                        }
                    } else if item.custom {
                        Text(item.options.isEmpty ? "Type your answer below and press Return."
                                                  : "Or type your own answer below.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    HStack(spacing: Theme.Space.md) {
                        if !item.options.isEmpty {
                            Text(item.multiple ? "1–\(min(item.options.count, 9)) toggle" : "1–\(min(item.options.count, 9)) to pick")
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        OctetButton(title: "Skip", kind: .ghost, compact: true) { session.rejectQuestion(question) }
                            .help("Tell the agent you won't answer; its turn ends (Esc)")
                        if draft.index > 0 {
                            OctetButton(title: "Back", kind: .secondary, compact: true) { model.back() }
                        }
                        OctetButton(title: draft.isLast ? "Answer" : "Next", kind: .primary, compact: true) {
                            model.next(session: session)
                        }
                        .disabled(draft.isLast ? !draft.isComplete : !draft.canAdvance)
                    }
                }
                .padding(Theme.Space.lg)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(session.engine.displayName) asks: \(item.question)")
            .onAppear {
                AccessibilityNotification.Announcement("\(session.engine.displayName) asks: \(item.question)").post()
            }
        }
    }

    private func optionRow(_ option: OpenCodeQuestion.Item.Option, number: Int,
                           item: OpenCodeQuestion.Item, draft: AgentQuestionDraft) -> some View {
        let selected = draft.isPicked(option.label)
        return Button { model.pick(option.label, session: session) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text(number <= 9 ? "\(number)" : " ")
                    .font(Theme.Text.mono(10.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: item.multiple ? Theme.Radius.xs : 9)
                        .fill(selected ? Theme.accent : Theme.hover))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(Theme.Text.transcript).foregroundStyle(Theme.textPrimary)
                    if !option.description.isEmpty {
                        Text(option.description).font(Theme.Text.body).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected { OctetIcon("checkmark", size: 11).foregroundStyle(Theme.accent) }
            }
            .padding(.vertical, Theme.Space.xs)
            .padding(.horizontal, Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(selected ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number). \(option.label)")
        .accessibilityHint(option.description)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Approvals

/// What kind of approval a request is, in the words T3 Code uses for them.
enum ApprovalKind {
    case command, fileChange, fileRead, web, tool

    init(_ request: AgentPermissionRequest) {
        switch request.toolName {
        case "Bash", "BashOutput", "KillShell", "KillBash", "Monitor": self = .command
        case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .fileChange
        case "Read", "Grep", "Glob", "LS", "NotebookRead": self = .fileRead
        case "WebFetch", "WebSearch": self = .web
        default: self = .tool
        }
    }

    var title: String {
        switch self {
        case .command: "Command approval"
        case .fileChange: "File change approval"
        case .fileRead: "File read approval"
        case .web: "Web access approval"
        case .tool: "Tool approval"
        }
    }

    var icon: String {
        switch self {
        case .command: "tool.run"
        case .fileChange: "tool.edit"
        case .fileRead: "tool.read"
        case .web: "tool.web"
        case .tool: "tool.mcp"
        }
    }
}

/// A permission request docked on the composer's top edge: what kind it
/// is, which of several waiting, the command or the change itself, and
/// Approve and Deny in reach, with the broader allows in a menu.
struct PermissionBanner: View {
    @ObservedObject var session: AgentSession
    let request: AgentPermissionRequest
    @State private var note = ""
    @State private var showInput = false

    var body: some View {
        if request.toolName == "ExitPlanMode" {
            PlanApprovalBanner(session: session, request: request)
        } else {
            let kind = ApprovalKind(request)
            let name = AgentPermissionRules.displayName(request.toolName)
            OctetPalettePanel {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack(spacing: Theme.Space.sm) {
                        OctetIcon(kind.icon, size: 13).foregroundStyle(Theme.warning)
                        Text(kind.title)
                            .font(Theme.Text.captionMedium)
                            .foregroundStyle(Theme.warning)
                        Text(name)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let path = request.inputObject["file_path"] as? String {
                            LanguageLogo(path: path)
                            Text((path as NSString).lastPathComponent)
                                .font(Theme.monoFont)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.md)
                        let count = session.pendingPermissionCount
                        if count > 1 {
                            Text("1/\(count)")
                                .font(Theme.Text.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityLabel("1 of \(count) waiting")
                        }
                    }
                    detail(kind)
                    if showInput {
                        CodePanel(text: request.input, language: "input", tint: Theme.textSecondary, maxLines: 12, highlights: false)
                    }
                    HStack(spacing: Theme.Space.md) {
                        // Claude Code carries a note back with a refusal; Codex's
                        // answer is only a decision, so a note there would vanish.
                        if session.engine != .codex {
                            OctetTextField(placeholder: session.engine == .opencode
                                            ? "Note for OpenCode when denying (optional; without one the turn stops)"
                                            : "Note for \(session.engine.displayName) when denying (optional)", text: $note) {
                                deny()
                            }
                        } else {
                            Spacer()
                        }
                        OctetIconButton(icon: showInput ? "chevron.down" : "chevron.right",
                                        help: showInput ? "Hide the request's details" : "Show the request's details") {
                            showInput.toggle()
                        }
                        OctetButton(title: "Deny", kind: .secondary, compact: true) { deny() }
                            .help("Refuse this (Esc in the message box)")
                        allowMenu
                        OctetButton(title: "Approve", kind: .primary, compact: true) {
                            session.answerPermission(allow: true)
                            note = ""
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Allow this once (⌘Return)")
                    }
                }
                .padding(Theme.Space.lg)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(kind.title): \(name)")
            .onAppear {
                AccessibilityNotification.Announcement("\(session.engine.displayName) asks to use \(name)").post()
            }
        }
    }

    @ViewBuilder private func detail(_ kind: ApprovalKind) -> some View {
        if let diff = AgentToolCall.diff(tool: request.toolName, input: request.inputObject) {
            DiffView(lines: diff, path: request.inputObject["file_path"] as? String,
                     startLine: AgentToolCall.startLine(tool: request.toolName, input: request.inputObject, applied: false),
                     maxLines: 14)
        } else if kind == .command, let command = request.inputObject["command"] as? String {
            CodePanel(text: command, language: "shell", maxLines: 8)
        } else if !request.summary.isEmpty {
            CodePanel(text: request.summary, language: request.toolName, maxLines: 8)
        }
    }

    /// The allows that reach past this one request.
    private var allowMenu: some View {
        Menu {
            Button(AgentSession.sessionAllowTitle(request)) {
                session.answerPermission(allow: true, forSession: true)
                note = ""
            }
            .help("Allow this now and stop asking about it until the conversation closes")
            if let rule = session.alwaysRule(for: request) {
                Button(rule.title + " in This Project") {
                    session.answerPermission(allow: true, always: true)
                    note = ""
                }
                .help("Saved to .claude/settings.local.json, where it can be removed")
            }
        } label: {
            OctetIcon("chevron.down", size: 11)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Always allow for this session, or in this project")
        .accessibilityLabel("More ways to allow")
    }

    private func deny() {
        session.answerPermission(allow: false, note: note)
        note = ""
    }
}

/// The agent's plan, asking to start work: the plan itself, and the choices
/// Claude Code's own interface gives. Approving picks how edits are then
/// handled; keeping on planning sends what should change.
struct PlanApprovalBanner: View {
    @ObservedObject var session: AgentSession
    let request: AgentPermissionRequest
    @State private var feedback = ""

    var body: some View {
        let plan = request.inputObject["plan"] as? String ?? ""
        let name = session.engine.displayName
        OctetPalettePanel {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    OctetIcon("tool.todo", size: 13).foregroundStyle(Theme.accent)
                    Text("Ready to code?")
                        .font(Theme.Text.title3)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                if plan.isEmpty {
                    Text("\(name) has finished planning.").font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        MarkdownView(text: plan)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
                HStack(spacing: Theme.Space.md) {
                    OctetTextField(placeholder: "What should change in the plan?", text: $feedback) {
                        keepPlanning()
                    }
                    OctetButton(title: "Keep Planning", kind: .secondary, compact: true) { keepPlanning() }
                        .help("Stay in plan mode and tell \(name) what to change")
                    OctetButton(title: "Approve", kind: .secondary, compact: true) { approve(.default) }
                        .help("Start work, asking before each edit")
                    OctetButton(title: "Approve & Auto-Accept Edits", kind: .primary, compact: true) { approve(.acceptEdits) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Start work, accepting file edits without asking (⌘Return)")
                }
            }
            .padding(Theme.Space.lg)
        }
        .onAppear {
            AccessibilityNotification.Announcement("\(name)'s plan is ready for review").post()
        }
    }

    private func approve(_ mode: AgentSession.PermissionMode) {
        session.answerPermission(allow: true)
        // Out of plan mode, into the one picked; sent live.
        session.permissionMode = mode
    }

    private func keepPlanning() {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        session.answerPermission(allow: false, note: note.isEmpty ? "Keep planning. The plan isn't approved yet." : note)
        feedback = ""
    }
}
