import AppKit
import SwiftUI

/// Octet's own interface to an agent, drawn over the pane the agent is running
/// in. Everything here comes from the agent's own session file, and everything
/// you type goes back to the real agent — the twin is an interface, not a
/// second brain.
struct TwinView: View {
    @ObservedObject var twin: TwinSession
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = SettingsStore.shared

    private var rows: [TwinRow] { TwinRows.build(twin.conversation) }
    private var style: TwinStyle { TwinStyle.forAgent(twin.agent?.agent) }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            if let approval = twin.approval {
                TwinApprovalBar(approval: approval) { twin.answer($0) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            composer
        }
        // One surface, the terminal's own: the twin replaces the pane rather
        // than sitting in a panel on top of it.
        .background(Theme.terminalBackground)
    }

    // MARK: - Header

    private var header: some View {
        let agent = twin.agent
        let brand = AgentBrand.forAgent(agent?.agent)
        return HStack(spacing: 8) {
            if let brand { AgentLogo(brand: brand, size: 13) }
            Text(title)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let status = agent?.agentStatus {
                AgentStateGlyph(status: status, size: 9)
                Text(stateLabel(status))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if agent?.agentStatus == .working {
                Button("Stop") { twin.interrupt() }
                    .buttonStyle(.plain)
                    .help("Send Escape to the agent")
            }
            Button {
                twin.hide()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 10))
                    Text("Terminal")
                }
            }
            .buttonStyle(.plain)
            .help("Show the real terminal (⌘⇧V)")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var title: String {
        if let title = twin.conversation.title, !title.isEmpty { return title }
        let tab = store.snapshot.tabs.first { $0.tabId == twin.agent?.tabId }
        let label = tab?.label ?? ""
        if !TabAutoName.isUnnamed(label) { return label }
        return AgentBrand.forAgent(twin.agent?.agent)?.displayName ?? "Agent"
    }

    private func stateLabel(_ status: EngineAgentStatus) -> String {
        switch status {
        case .working: "working"
        case .blocked: "waiting on you"
        case .done: "done"
        case .idle: "idle"
        case .unknown: ""
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let notice = twin.notice {
                        Text(notice)
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(rows) { row in
                        TwinRowView(row: row, style: style)
                            .id(row.id)
                    }
                    ForEach(twin.pending) { message in
                        TwinPendingRow(text: message.text)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: rows.count + twin.pending.count) { _, _ in
                withAnimation(MotionPreferences.shared.animation(.palette, .smooth(duration: 0.2))) {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private static let bottomId = "twin-bottom"

    private var placeholder: String {
        let name = AgentBrand.forAgent(twin.agent?.agent)?.displayName ?? "the agent"
        return "Message \(name)…"
    }

    private var composerHeight: CGFloat {
        let lines = max(1, twin.draft.components(separatedBy: "\n").count)
        return min(132, CGFloat(lines) * 17 + 10)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputBox
            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var inputBox: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text(style.promptPrefix)
                .font(Theme.monoFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 3)
            // An NSTextView has no height of its own, so the box grows by the
            // lines in it, up to a few, and scrolls after that.
            TwinComposer(text: $twin.draft, onSubmit: { twin.submit() })
                .frame(height: composerHeight)
                .overlay(alignment: .leading) {
                    if twin.draft.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
            if !twin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Send") { twin.submit() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// What each agent keeps at the foot of its own screen: which model, how
    /// much context is left, and where it is working.
    private var statusLine: some View {
        let usage = store.usageTracker.usage(forTerminal: twin.agent?.terminalId) ?? twin.conversation.usage
        var parts: [String] = []
        if let model = twin.conversation.model { parts.append(TwinStyle.shortModel(model)) }
        if let usage, !usage.label.isEmpty { parts.append("\(usage.label) context") }
        if let cwd = twin.agent?.effectiveCwd ?? twin.conversation.cwd {
            parts.append(TwinStyle.shortPath(cwd))
        }
        if let workspace = twin.agent?.workspaceId, let branch = store.branches[workspace] {
            parts.append(branch)
        }
        return HStack(spacing: 8) {
            Text(parts.joined(separator: "  ·  "))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(hint)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var hint: String {
        twin.agent?.agentStatus == .working
            ? "\(style.interruptHint)  ·  ⌘⇧V terminal"
            : "⏎ send  ·  ⇧⏎ newline  ·  ⌘⇧V terminal"
    }
}

/// A message on its way to the agent: the same shape as a turn, held quiet
/// until the agent writes it down and it becomes one.
private struct TwinPendingRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("sending…")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// One line of the conversation.
private struct TwinRowView: View {
    let row: TwinRow
    let style: TwinStyle
    @State private var expanded = false

    var body: some View {
        switch row.kind {
        case .user(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.accent).frame(width: 2)
                TwinText(text: text)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.vertical, 2)
        case .assistant(let text):
            TwinText(text: text)
                .foregroundStyle(Theme.textMuted)
        case .thinking(let text):
            DisclosureGroup(isExpanded: $expanded) {
                Text(text)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Text("Thought for a moment")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .tint(Theme.textTertiary)
        case .command(let command, let output, let isError):
            step(title: style.toolTitle(style.id == "claude" ? "Bash" : "exec") + "(",
                 mono: command, trailing: ")",
                 tint: isError ? Color(hex: AgentStateColor.blocked) : Theme.textSecondary) {
                output
            }
        case .diff(let diff, let result):
            step(title: style.callLine(tool: "Edit", argument: (diff.path as NSString).lastPathComponent),
                 mono: diff.summary, tint: Theme.textSecondary) {
                result
            } extra: {
                TwinDiffView(diff: diff)
            }
        case .todos(let todos):
            TwinTodoList(todos: todos, title: style.planTitle)
                .padding(.vertical, 2)
        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "bell")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                Text(text)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 1)
        case .tool(let name, let summary, let result, let isError):
            step(title: style.toolTitle(name) + (summary.isEmpty ? "" : "("),
                 mono: summary, trailing: summary.isEmpty ? "" : ")",
                 tint: isError ? Color(hex: AgentStateColor.blocked) : Theme.textSecondary) {
                result
            }
        }
    }

    /// One step the agent took, drawn the way its own interface draws one:
    /// a bullet, what it did, and what came back under it.
    @ViewBuilder
    private func step<Extra: View>(
        title: String,
        mono: String,
        trailing: String = "",
        tint: Color,
        output: () -> String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        let result = output()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: trailing.isEmpty ? 6 : 2) {
                Text(style.bullet)
                    .padding(.trailing, trailing.isEmpty ? 0 : 4)
                    .font(Theme.captionFont)
                    .foregroundStyle(tint)
                Text(title)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                Text(mono + trailing)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if !result.isEmpty || hasExtra {
                    Button(expanded ? "Hide" : "Output") { expanded.toggle() }
                        .buttonStyle(.plain)
                }
            }
            extra()
            if !result.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(style.resultMarker)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textTertiary)
                    if expanded {
                        Text(result)
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textTertiary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(TwinStyle.resultLine(result))
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var hasExtra: Bool {
        if case .diff = row.kind { return true } else { return false }
    }
}

/// The lines an edit changed, with the gutters a diff is read by.
private struct TwinDiffView: View {
    let diff: TwinDiff
    @State private var expanded = false

    private var shown: [TwinDiff.Line] { expanded ? diff.lines : Array(diff.lines.prefix(14)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text(marker(line))
                        .font(Theme.monoFont)
                        .foregroundStyle(colour(line))
                        .frame(width: 8, alignment: .leading)
                    Text(text(line))
                        .font(Theme.monoFont)
                        .foregroundStyle(colour(line))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(background(line))
            }
            if diff.lines.count > shown.count {
                Button("\(diff.lines.count - shown.count) more lines") { expanded = true }
                    .buttonStyle(.plain)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func marker(_ line: TwinDiff.Line) -> String {
        switch line {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private func text(_ line: TwinDiff.Line) -> String {
        switch line {
        case .added(let value), .removed(let value), .context(let value): value
        }
    }

    private func colour(_ line: TwinDiff.Line) -> Color {
        switch line {
        case .added: Color(hex: AgentStateColor.done)
        case .removed: Color(hex: AgentStateColor.blocked)
        case .context: Theme.textTertiary
        }
    }

    private func background(_ line: TwinDiff.Line) -> Color {
        switch line {
        case .added: Color(hex: AgentStateColor.done).opacity(0.08)
        case .removed: Color(hex: AgentStateColor.blocked).opacity(0.08)
        case .context: Color.clear
        }
    }
}

/// The plan an agent keeps while it works, as a list you can read at a glance.
private struct TwinTodoList: View {
    let todos: [TwinTodo]
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.textTertiary)
                Text("\(todos.filter { $0.status == .completed }.count)/\(todos.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: glyph(todo.status))
                        .font(.system(size: 10))
                        .foregroundStyle(tint(todo.status))
                    Text(todo.text)
                        .font(Theme.uiFont)
                        .foregroundStyle(todo.status == .completed ? Theme.textTertiary : Theme.textMuted)
                        .strikethrough(todo.status == .completed, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func glyph(_ status: TwinTodo.Status) -> String {
        switch status {
        case .completed: "checkmark.square"
        case .inProgress: "square.dashed.inset.filled"
        case .pending: "square"
        }
    }

    private func tint(_ status: TwinTodo.Status) -> Color {
        switch status {
        case .completed: Color(hex: AgentStateColor.done)
        case .inProgress: Theme.accent
        case .pending: Theme.textTertiary
        }
    }
}

/// Prose as markdown, code as code.
private struct TwinText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(TwinMarkdown.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(attributed(prose))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let code):
                    Text(code)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown only: lists and headings keep their own line breaks.
    private func attributed(_ prose: String) -> AttributedString {
        (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prose)
    }
}

/// The question the agent is waiting on, as buttons.
private struct TwinApprovalBar: View {
    let approval: TwinApproval
    let answer: (TwinApproval.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.question)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                ForEach(approval.options) { option in
                    Button(option.label) { answer(option) }
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card.opacity(Theme.isLight ? 0.7 : 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}

/// Where the keyboard goes while the twin is open. Everything in Octet that
/// hands focus back to the terminal asks here first.
@MainActor
enum TwinComposerFocus {
    private static let textViews = NSHashTable<NSTextView>.weakObjects()

    static func register(_ textView: NSTextView) {
        textViews.add(textView)
    }

    /// Puts the caret back in the box; false when there is no box.
    @discardableResult
    static func request() -> Bool {
        guard let window = NSApp.keyWindow,
              let textView = textViews.allObjects.first(where: { $0.window === window }) else { return false }
        window.makeFirstResponder(textView)
        return true
    }
}

/// The input box. Return sends, Shift-Return starts a new line — the way
/// every agent's own prompt behaves, so muscle memory carries over.
private struct TwinComposer: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textColor = Theme.palette.nsColor(\.textPrimary)
        textView.insertionPointColor = Theme.palette.nsColor(\.accent)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        context.coordinator.textView = textView
        TwinComposerFocus.register(textView)
        // The terminal surface grabs first responder back as the window
        // settles, so the box asks for focus again as that happens.
        for delay in [0.0, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard textView.window?.isKeyWindow == true else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text { textView.string = text }
        textView.textColor = Theme.palette.nsColor(\.textPrimary)
        textView.insertionPointColor = Theme.palette.nsColor(\.accent)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TwinComposer
        weak var textView: NSTextView?

        init(_ parent: TwinComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return arrives as insertNewlineIgnoringFieldEditor.
                parent.onSubmit()
                textView.string = ""
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}
