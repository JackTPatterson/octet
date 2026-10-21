import AppKit
import SwiftUI

/// A background session's transcript, kept live from its log for the hub:
/// Claude Code's own log, or Codex's rollout. Only what the agent wrote
/// since the last look is read and parsed, so a long or idle session costs
/// next to nothing to watch.
@MainActor
final class HubTranscriptModel: ObservableObject {
    enum Source {
        case claude(BackgroundAgent)
        case codex(BackgroundAgent)
    }

    @Published private(set) var conversation = AgentConversation()
    /// The first read has landed: before it, the transcript shows a skeleton.
    @Published private(set) var loaded = false
    /// Claude Code's log is gone; the job's timeline stands in.
    @Published private(set) var logMissing = false
    /// Only the latest part of a long log was read.
    @Published private(set) var startedMidway = false

    private let source: Source
    private let reader = Reader()
    private var timer: Timer?

    init(source: Source) {
        self.source = source
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let reader = self.reader
        let source = self.source
        let codexPath: String? = if case .codex(let agent) = source { CodexAgentsStore.shared.rolloutPaths[agent.id] } else { nil }
        reader.queue.async { [weak self] in
            let result = reader.read(source, codexPath: codexPath)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let result { self?.apply(result) } else { self?.markLoaded() }
                }
            }
        }
    }

    private func markLoaded() {
        if !loaded { loaded = true }
    }

    private func apply(_ result: Reader.Result) {
        if logMissing != result.missing { logMissing = result.missing }
        if startedMidway != result.midway { startedMidway = result.midway }
        if result.conversation.items != conversation.items || result.conversation.contextUsed != conversation.contextUsed {
            conversation = result.conversation
        }
        markLoaded()
    }

    /// Owns the tail and the parsed conversation, on its own queue, off the
    /// main thread.
    private final class Reader: @unchecked Sendable {
        struct Result {
            let conversation: AgentConversation
            let missing: Bool
            let midway: Bool
        }

        let queue = DispatchQueue(label: "octet.hub-transcript", qos: .userInitiated)
        private var lines = TranscriptLineTail()
        private var claude = AgentConversation()
        private var codex: TwinTail?
        private var claudePath: String?
        private var lookups = 0
        private var timelineShown = false

        /// What changed, or nil when nothing did.
        func read(_ source: Source, codexPath: String?) -> Result? {
            switch source {
            case .claude(let agent):
                // Finding the log means searching Claude Code's projects; do it
                // now and then until it turns up, not on every poll.
                if claudePath == nil, lookups % 5 == 0 { claudePath = AgentsStore.logPath(for: agent) }
                lookups += 1
                guard let path = claudePath else {
                    guard !timelineShown else { return nil }
                    timelineShown = true
                    var replayed = AgentConversation()
                    replayed.items = BackgroundJob.timeline(id: agent.id).enumerated().map { index, entry in
                        AgentItem(id: "timeline-\(index)", kind: .text(entry))
                    }
                    return Result(conversation: replayed, missing: true, midway: false)
                }
                switch lines.pull(path: path) {
                case .unchanged:
                    return timelineShown ? nil : first()
                case .appended(let new):
                    claude.replay(appending: new)
                case .restarted(let new):
                    claude = AgentConversation()
                    claude.replay(appending: new)
                }
                timelineShown = true
                return Result(conversation: claude, missing: false, midway: lines.startedMidway)
            case .codex:
                guard let codexPath else { return nil }
                if codex == nil { codex = TwinTail(format: "codex") }
                guard codex?.pull(path: codexPath) == true, let twin = codex?.conversation else {
                    return nil
                }
                return Result(conversation: AgentConversation(twin: twin), missing: false, midway: false)
            }
        }

        /// The log was there and empty on the first look.
        private func first() -> Result {
            timelineShown = true
            return Result(conversation: claude, missing: false, midway: lines.startedMidway)
        }
    }
}

/// The transcript itself: what it adds up to, then every step, following
/// the end only while you're at the end, and with the transcript's actions
/// (quote, open a file or a turn's diff, open a command's whole output).
struct HubTranscript<Notes: View>: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var model: HubTranscriptModel
    let cwd: String
    /// The session is mid-turn, so its last steps are still moving.
    let running: Bool
    /// Where a quote goes; without one it's copied.
    var quote: ((String) -> Void)? = nil
    @ViewBuilder var notes: () -> Notes
    @State private var atEnd = true
    @State private var output: AgentToolCall?

    private var shown: [AgentItem] {
        model.conversation.items.filter { item in
            if case .thinking(let text) = item.kind { return !text.isEmpty }
            return true
        }
    }

    var body: some View {
        let items = shown
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HubTranscriptSummary(conversation: model.conversation, cwd: cwd)
                    notes()
                    if model.startedMidway {
                        Text("A long session: showing its latest part.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !model.loaded {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            ForEach(0..<4, id: \.self) { index in
                                SkeletonBlock(width: index.isMultiple(of: 2) ? 320 : 220, height: 12)
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Loading the transcript")
                    } else if items.isEmpty, !model.logMissing {
                        Text("Nothing written yet.")
                            .font(Theme.Text.body)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(items) { item in
                        ItemRow(item: item, running: running)
                            .padding(.leading, item.parent == nil ? 0 : 18)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { atEnd = true }
                        .onDisappear { atEnd = false }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .octetScrollIndicators()
            // New steps pull the view down only for someone already at the end.
            .onChange(of: items.count) { old, _ in
                if atEnd || old == 0 { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !atEnd, !items.isEmpty {
                    OctetButton(title: "Jump to Latest", icon: "arrow.down", kind: .secondary, compact: true) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .environment(\.transcriptActions, actions)
        .overlay {
            if let output {
                HubOutputPanel(call: output) { self.output = nil }
            }
        }
    }

    private var actions: TranscriptActions {
        let window = window
        let cwd = cwd
        let quote = quote
        let items = model.conversation.items
        let leave = { AgentCenter.shared.setBoard(nil, in: window.focusedWorkspace?.workspaceId) }
        return TranscriptActions(
            cwd: cwd,
            quote: { passage, _ in
                if let quote {
                    quote(passage)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(passage, forType: .string)
                    ToastCenter.shared.info("Copied")
                }
            },
            openTurnDiff: { turn, path in
                leave()
                window.ui.openTurnDiff(directory: cwd, promptAt: turn.promptAt, nextPromptAt: turn.nextPromptAt, path: path)
            },
            openFile: { path in
                leave()
                window.openFile(URL(fileURLWithPath: path))
            },
            openOutput: { id in
                guard let item = items.first(where: { $0.id == id }), case .tool(let call) = item.kind else { return }
                output = call
            }
        )
    }
}

extension HubTranscript where Notes == EmptyView {
    init(model: HubTranscriptModel, cwd: String, running: Bool, quote: ((String) -> Void)? = nil) {
        self.init(model: model, cwd: cwd, running: running, quote: quote, notes: { EmptyView() })
    }
}

/// A command's whole output over a hub transcript: selectable, copyable.
private struct HubOutputPanel: View {
    let call: AgentToolCall
    let close: () -> Void

    var body: some View {
        let text = CommandOutputSearch.plain(call.result ?? call.liveOutput ?? "")
        ZStack {
            Theme.scrim
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.md) {
                    OctetIcon(call.iconName, size: 14).foregroundStyle(Theme.textTertiary)
                    Text(call.displayName).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Space.md)
                    OctetIconButton(icon: "doc.on.doc", help: "Copy output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    OctetIconButton(icon: "xmark", help: "Close (Esc)", action: close)
                }
                .padding(.horizontal, Theme.Space.lg)
                .frame(height: 40)
                Rectangle().fill(Theme.divider).frame(height: 1)
                ScrollView {
                    Text(text)
                        .font(Theme.Text.mono())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.lg)
                }
                .octetScrollIndicators()
            }
            .frame(maxWidth: 860, maxHeight: 620)
            .octetGlass(cornerRadius: Theme.Radius.card, fill: Theme.terminalBackground)
            .padding(28)
        }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command output")
    }
}
