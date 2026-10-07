import AppKit
import Combine
import SwiftUI

/// Recap: when you come back to Octet after a while, one card says what
/// every agent did meanwhile. What needs you, what's stuck, what finished
/// and what's still working, each with what it changed and said last.
///
/// You're away while Octet isn't the app in front, or the screen is locked
/// or asleep. Leaving marks where every conversation stood; agents in
/// terminals are followed snapshot by snapshot until you're back.
@MainActor
final class RecapCenter: ObservableObject {
    static let shared = RecapCenter()

    /// The recap on screen, if one is.
    @Published private(set) var shown: Recap?
    /// The latest recap, for Show Recap after it's dismissed.
    @Published private(set) var latest: Recap?
    /// The window it shows in: the one in front when it came up.
    private weak var target: WindowContext?

    func showsIn(_ window: WindowContext) -> Bool {
        (target ?? WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first) === window
    }

    private func show(_ recap: Recap) {
        target = WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first
        shown = recap
    }

    private var leftAt: Date?
    private var marks: [String: Recap.ConversationMark] = [:]
    private var terminals = Recap.TerminalLog()
    private var locked = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.leave() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.returned() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    RecapCenter.shared.locked = true
                    RecapCenter.shared.leave()
                }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecapCenter.shared.unlocked() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                RecapCenter.shared.locked = true
                RecapCenter.shared.leave()
            }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.unlocked() }
        })
    }

    // MARK: - Away and back

    private func leave() {
        guard leftAt == nil else { return }
        leftAt = Date()
        marks = Dictionary(AgentCenter.shared.sessions.map { session in
            (session.id, Recap.ConversationMark(itemIds: Set(session.conversation.items.map(\.id)),
                                                wasRunning: session.conversation.isRunning,
                                                lastError: session.conversation.lastError))
        }, uniquingKeysWith: { first, _ in first })
        terminals = Recap.TerminalLog()
        if let snapshot = WindowRegistry.shared.key?.store.snapshot ?? WindowRegistry.shared.windows.first?.store.snapshot {
            terminals.observe(snapshot)
        }
    }

    private func unlocked() {
        locked = false
        // Unlocked into Octet: that's coming back. Into another app, the
        // app's own activation says when.
        if NSApp.isActive { returned() }
    }

    private func returned() {
        guard !locked, let leftAt else { return }
        self.leftAt = nil
        let now = Date()
        let settings = SettingsStore.shared.values
        guard now.timeIntervalSince(leftAt) >= settings.recapAfterMinutes * 60 else { return }
        let recap = build(leftAt: leftAt, now: now)
        guard recap.isWorthShowing else { return }
        latest = recap
        if settings.recap { show(recap) }
    }

    /// Every snapshot while you're away.
    func observe(_ snapshot: EngineSnapshot) {
        guard leftAt != nil else { return }
        terminals.observe(snapshot)
    }

    private func build(leftAt: Date, now: Date) -> Recap {
        var runs = terminals.runs(now: now)
        for session in AgentCenter.shared.sessions {
            let mark = marks[session.id] ?? Recap.ConversationMark(itemIds: [], wasRunning: false, lastError: nil)
            let state = Recap.ConversationNow(
                id: session.id, agent: session.engine.rawValue, title: session.title, workspaceId: session.workspaceId,
                items: session.conversation.items, isRunning: session.conversation.isRunning,
                lastError: session.conversation.lastError, waitingOn: Self.waitingOn(session))
            if let run = Recap.run(state, since: mark) { runs.append(run) }
        }
        return Recap(leftAt: leftAt, cameBackAt: now, runs: Recap.ordered(runs))
    }

    private static func waitingOn(_ session: AgentSession) -> String? {
        if let permission = session.pendingPermission {
            let what = permission.summary.isEmpty ? permission.toolName : "\(permission.toolName): \(permission.summary)"
            return "Asks to run \(what)"
        }
        if let question = session.pendingQuestion {
            return question.items.first.map { $0.question.isEmpty ? $0.header : $0.question } ?? "Has a question"
        }
        return nil
    }

    // MARK: - Showing it

    func dismiss() { shown = nil }

    /// Show Recap: the latest one again, or a note that there's none yet.
    func showLatest() {
        if let latest { show(latest) } else {
            ToastCenter.shared.info("No recap yet", detail: "Octet writes one when you come back after being away, if any agent did something meanwhile.")
        }
    }

    /// Goes to a run: its conversation, or its terminal tab.
    func open(_ run: Recap.Run, in window: WindowContext) {
        switch run.source {
        case .conversation(let id):
            guard let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) else {
                return ToastCenter.shared.info("That conversation is closed")
            }
            window.focusWorkspace(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        case .terminal(let paneId, _):
            AgentCenter.shared.setActive(nil, in: run.workspaceId)
            window.focusAgent(paneId: paneId)
            OctetTerminalRuntime.focusTerminal()
        }
    }
}

// MARK: - The card

/// The recap, over the window's content: a heading with how long you were
/// away, then each run under what it needs from you.
struct RecapCard: View {
    let recap: Recap
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var center = RecapCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Recap.Outcome.allCases, id: \.self) { outcome in
                        let runs = recap.runs(outcome)
                        if !runs.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(outcome.title.uppercased())
                                    .font(Theme.headerFont).kerning(0.4)
                                    .foregroundStyle(Self.color(outcome))
                                ForEach(runs) { run in
                                    RecapRow(run: run, workspace: workspaceName(run.workspaceId)) {
                                        center.open(run, in: window)
                                        center.dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 560)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onExitCommand { center.dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recap: \(recap.headline)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("While you were away")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("\(AgentActivityWatcher.durationLabel(recap.away) ?? "A moment") away · \(recap.headline)")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            OctetButton(title: "Done", kind: .secondary, compact: true) { center.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func workspaceName(_ id: String?) -> String? {
        guard let id else { return nil }
        return window.store.snapshot.workspaces.first { $0.workspaceId == id }?.label
    }

    static func color(_ outcome: Recap.Outcome) -> Color {
        switch outcome {
        case .needsYou: Color.orange
        case .stuck: Theme.danger
        case .finished: Color.green
        case .working: Theme.accent
        }
    }
}

private struct RecapRow: View {
    let run: Recap.Run
    let workspace: String?
    let open: () -> Void
    @State private var hovered = false
    @State private var showingFiles = false

    var body: some View {
        let brand = AgentBrand.forAgent(run.agent)
        let tint = brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 24, height: 24)
                if let brand { AgentLogo(brand: brand, size: 13) } else { OctetIcon("sparkle", size: 14).foregroundStyle(tint) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let workspace, !workspace.isEmpty {
                        Text(workspace).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    OctetButton(title: run.outcome == .needsYou ? "Answer" : "Open", kind: run.outcome == .needsYou ? .primary : .ghost,
                                compact: true, action: open)
                }
                Text(run.summary).font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                if let reason = run.reason {
                    Text(reason).font(Theme.uiFont).foregroundStyle(RecapCard.color(run.outcome)).lineLimit(3)
                }
                if let message = run.lastMessage {
                    Text(message).font(Theme.uiFont).foregroundStyle(Theme.textSecondary).lineLimit(3)
                        .textSelection(.enabled)
                }
                if !run.files.isEmpty { files }
            }
        }
        .padding(10)
        .background(hovered ? Theme.hover : Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private var files: some View {
        let shown = showingFiles ? run.files : Array(run.files.prefix(3))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown, id: \.self) { path in
                HStack(spacing: 5) {
                    if let logo = LanguageLogo(path: path, size: 11) { logo } else { OctetIcon("doc", size: 11).foregroundStyle(Theme.textTertiary) }
                    Text((path as NSString).lastPathComponent).font(Theme.monoFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .help(path)
            }
            if run.files.count > 3 {
                Button(showingFiles ? "Show fewer" : "and \(run.files.count - 3) more") { showingFiles.toggle() }
                    .buttonStyle(.plain).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
