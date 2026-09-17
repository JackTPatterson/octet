import AppKit
import SwiftUI

/// Herd's own interface to an agent, drawn over the pane the agent is running
/// in. Everything here comes from the agent's own session file, and everything
/// you type goes back to the real agent — the twin is an interface, not a
/// second brain.
struct TwinView: View {
    @ObservedObject var twin: TwinSession
    @ObservedObject var store: HerdrStore
    @ObservedObject private var settings = SettingsStore.shared

    private var rows: [TwinRow] { TwinRows.build(twin.conversation) }

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
        let usage = store.usageTracker.usage(forTerminal: agent?.terminalId) ?? twin.conversation.usage
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
            if let model = twin.conversation.model {
                Text(shortModel(model))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let usage, !usage.label.isEmpty {
                Text("\(usage.label) context")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            if agent?.agentStatus == .working {
                Button("Stop") { twin.interrupt() }
                    .buttonStyle(HerdButtonStyle())
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
            .buttonStyle(HerdButtonStyle())
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

    private func shortModel(_ model: String) -> String {
        // `claude-opus-5-20260101` reads better as `opus-5`.
        var parts = model.split(separator: "-").map(String.init)
        parts.removeAll { part in part.count >= 4 && part.allSatisfy { $0.isNumber } }
        if parts.first == "claude" || parts.first == "gpt" { parts.removeFirst() }
        return parts.isEmpty ? model : parts.joined(separator: "-")
    }

    private func stateLabel(_ status: HerdrAgentStatus) -> String {
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
                        TwinRowView(row: row)
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
        HStack(alignment: .bottom, spacing: 10) {
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
            if twin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("⏎ send")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 3)
            } else {
                Button("Send") { twin.submit() }
                    .buttonStyle(HerdButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
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
        case .tool(let name, let summary, let result, let isError):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: name))
                        .font(.system(size: 10))
                        .foregroundStyle(isError ? Color(hex: AgentStateColor.blocked) : Theme.textTertiary)
                    Text(name)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                    Text(summary)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !result.isEmpty {
                        Button(expanded ? "Hide" : "Output") { expanded.toggle() }
                            .buttonStyle(HerdButtonStyle())
                    }
                }
                if expanded, !result.isEmpty {
                    Text(result)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func icon(for name: String) -> String {
        switch name.lowercased() {
        case let tool where tool.contains("bash") || tool.contains("shell") || tool.contains("exec"): "terminal"
        case let tool where tool.contains("read") || tool.contains("cat"): "doc.text"
        case let tool where tool.contains("write") || tool.contains("edit") || tool.contains("patch"): "square.and.pencil"
        case let tool where tool.contains("search") || tool.contains("grep") || tool.contains("glob"): "magnifyingglass"
        case let tool where tool.contains("web") || tool.contains("fetch"): "globe"
        case let tool where tool.contains("task") || tool.contains("agent"): "person.2"
        default: "wrench.and.screwdriver"
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
                        .buttonStyle(HerdButtonStyle(kind: option.isAffirmative ? .primary : .quiet))
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

/// Where the keyboard goes while the twin is open. Everything in Herd that
/// hands focus back to the terminal asks here first.
@MainActor
enum TwinComposerFocus {
    weak static var textView: NSTextView?

    /// Puts the caret back in the box; false when there is no box.
    @discardableResult
    static func request() -> Bool {
        guard let textView, let window = textView.window else { return false }
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
        TwinComposerFocus.textView = textView
        // The terminal surface grabs first responder back as the window
        // settles, so the box asks for focus again as that happens.
        for delay in [0.0, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard textView.window != nil else { return }
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
