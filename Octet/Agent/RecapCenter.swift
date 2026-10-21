import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Recap: when you come back after being away, a strip at the top of the
/// window says what every agent did meanwhile: what needs you, what's
/// stuck, what finished and what's still working, each with what it changed
/// and said last.
///
/// You're away while the screen is locked or asleep, while no Octet window
/// can be seen, or while you haven't touched the Mac for the set time
/// (`RecapPresence`). Another app in front with Octet still on screen isn't
/// away. Leaving marks where every conversation stood; agents in terminals
/// are followed snapshot by snapshot until you're back.
///
/// The strip stays out of the way: it opens itself only when something
/// needs you or is stuck, and otherwise sits as a chip that fades after a
/// while. Opening an entry takes you there and crosses it off; once
/// everything has been looked at, the strip goes.
@MainActor
final class RecapCenter: ObservableObject {
    static let shared = RecapCenter()

    /// What's still to look at, if anything.
    @Published private(set) var shown: Recap?
    /// Whether the strip's list is open.
    @Published var expanded = false
    /// The latest recap in full, for Show Recap after it's gone.
    @Published private(set) var latest: Recap?
    /// The window it shows in: the one in front when it came up.
    private weak var target: WindowContext?

    func showsIn(_ window: WindowContext) -> Bool {
        (target ?? WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first) === window
    }

    private var leftAt: Date?
    private var marks: [String: Recap.ConversationMark] = [:]
    private var terminals = Recap.TerminalLog()
    private var locked = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var fade: DispatchWorkItem?

    /// A chip with nothing urgent fades after this long back.
    static let fadeAfter: TimeInterval = 120

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [
            NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecapCenter.shared.evaluate() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecapCenter.shared.setLocked(true) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecapCenter.shared.setLocked(false) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.setLocked(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.setLocked(false) }
        })
        schedule()
    }

    // MARK: - Away and back

    private func setLocked(_ value: Bool) {
        locked = value
        evaluate()
    }

    /// Whether any Octet window can be seen right now.
    private var octetVisible: Bool {
        if NSApp.isActive { return true }
        guard !NSApp.isHidden else { return false }
        return WindowRegistry.shared.windows.contains { context in
            guard let window = context.nsWindow else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere.
    private var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private var threshold: TimeInterval { SettingsStore.shared.values.recapAfterMinutes * 60 }

    /// Works out whether you're here or away, and acts on a change.
    private func evaluate() {
        let signals = RecapPresence.Signals(locked: locked, octetVisible: octetVisible, idleSeconds: idleSeconds)
        let now = Date()
        if let since = RecapPresence.awaySince(signals, now: now, idleAfter: threshold) {
            if leftAt == nil { leave(at: since) }
        } else if leftAt != nil {
            returned(now: now)
        }
        schedule()
    }

    /// Checks again soon: often while away for being idle, so coming back
    /// to the keyboard is noticed at once; now and then otherwise, to
    /// notice when you've stepped away from it.
    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = leftAt != nil ? 1 : 15
        let next = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { RecapCenter.shared.evaluate() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func leave(at since: Date) {
        leftAt = since
        // Gone idle is noticed late: what happened after you last touched
        // the Mac is still news, so the mark is where things stood then.
        marks = Dictionary(AgentCenter.shared.sessions.map { session in
            let items = session.conversation.items
            let before = items.filter { $0.createdAt < since }
            return (session.id, Recap.ConversationMark(itemIds: Set(before.map(\.id)),
                                                       wasRunning: session.conversation.isRunning || before.count < items.count,
                                                       lastError: session.conversation.lastError))
        }, uniquingKeysWith: { first, _ in first })
        terminals = Recap.TerminalLog()
        if let snapshot = WindowRegistry.shared.key?.store.snapshot ?? WindowRegistry.shared.windows.first?.store.snapshot {
            terminals.observe(snapshot)
        }
    }

    private func returned(now: Date) {
        guard let leftAt else { return }
        self.leftAt = nil
        guard now.timeIntervalSince(leftAt) >= threshold else { return }
        let recap = build(leftAt: leftAt, now: now)
        guard recap.isWorthShowing else { return }
        latest = recap
        guard SettingsStore.shared.values.recap else { return }
        show(recap.merged(unread: shown), opening: recap.isUrgent)
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

    private func show(_ recap: Recap, opening: Bool) {
        target = WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first
        shown = recap
        expanded = opening
        fadeLater()
    }

    /// A chip with nothing urgent goes by itself after a while; an open
    /// list, or one with something waiting on you, stays until handled.
    private func fadeLater() {
        fade?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let center = RecapCenter.shared
                guard let shown = center.shown, !shown.isUrgent, !center.expanded else { return }
                center.dismiss()
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeAfter, execute: work)
    }

    func toggle() {
        expanded.toggle()
        if !expanded { fadeLater() }
    }

    func dismiss() {
        fade?.cancel()
        shown = nil
        expanded = false
    }

    /// Show Recap: the latest one again, or a note that there's none yet.
    func showLatest() {
        if let latest { show(latest, opening: true) } else {
            ToastCenter.shared.info("No recap yet", detail: "Octet writes one when you come back after being away, if any agent did something meanwhile.")
        }
    }

    /// Goes to a run, its conversation or its terminal tab, and crosses it
    /// off; the strip goes once nothing's left.
    func open(_ run: Recap.Run, in window: WindowContext) {
        if var recap = shown {
            recap.runs.removeAll { $0.id == run.id }
            if recap.runs.isEmpty { dismiss() } else { shown = recap }
        }
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

// MARK: - The strip

/// The recap at the top of the window: a chip saying how long you were
/// away and what happened, opening into the list of runs under what each
/// needs from you.
struct RecapStrip: View {
    let recap: Recap
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var center = RecapCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            chip
            if center.expanded {
                Rectangle().fill(Theme.divider).frame(height: 1)
                list
            }
        }
        .frame(width: center.expanded ? 520 : nil)
        .background(Theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: center.expanded ? 12 : 16))
        .overlay(RoundedRectangle(cornerRadius: center.expanded ? 12 : 16).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(center.expanded ? 0.3 : 0.18), radius: center.expanded ? 20 : 8, y: center.expanded ? 8 : 3)
        .onExitCommand { center.expanded ? center.toggle() : center.dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recap: \(recap.headline)")
    }

    /// "Away 42m · 2 finished · 1 needs you", with the outcomes as dots.
    private var chip: some View {
        HStack(spacing: 8) {
            Button(action: center.toggle) {
                HStack(spacing: 8) {
                    OctetIcon("clock", size: 12).foregroundStyle(Theme.textTertiary)
                    Text("Away \(AgentActivityWatcher.durationLabel(recap.away) ?? "a while")")
                        .font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                    ForEach(Recap.Outcome.allCases, id: \.self) { outcome in
                        let count = recap.runs(outcome).count
                        if count > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(RecapStrip.color(outcome)).frame(width: 6, height: 6)
                                Text("\(count) \(outcome.title.lowercased())")
                                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Image(systemName: center.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(center.expanded ? "Hide what happened" : "What every agent did while you were away")
            if center.expanded { Spacer(minLength: 4) }
            Button { center.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss. View › Show Recap brings it back.")
            .accessibilityLabel("Dismiss recap")
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 32)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func workspaceName(_ id: String?) -> String? {
        guard let id else { return nil }
        return window.store.snapshot.workspaces.first { $0.workspaceId == id }?.label
    }

    static func color(_ outcome: Recap.Outcome) -> Color {
        switch outcome {
        case .needsYou: Theme.warning
        case .stuck: Theme.danger
        case .finished: Theme.success
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
                if let verification = run.verification {
                    VerificationBadge(verification: verification)
                }
                if let reason = run.reason {
                    Text(reason).font(Theme.uiFont).foregroundStyle(RecapStrip.color(run.outcome)).lineLimit(3)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .onTapGesture(perform: open)
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

/// Whether what the agent edited was tested afterwards: a dot and a line,
/// green when tests passed, amber when nothing vouches for the last edit,
/// red when the check failed.
struct VerificationBadge: View {
    let verification: Verification
    var compact = false

    var body: some View {
        if let message = verification.message {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(compact ? short : message)
                    .font(Theme.captionFont)
                    .foregroundStyle(verification.needsLook ? color : Theme.textTertiary)
                    .lineLimit(1)
            }
            .help(message + (verification.needsLook ? ". Look at it before trusting it." : ""))
            .accessibilityElement(children: .combine)
        }
    }

    private var color: Color {
        switch verification {
        case .tested(let passed): passed ? Theme.success : Theme.danger
        case .checked(let passed): passed ? Theme.warning : Theme.danger
        case .unchecked: Theme.warning
        case .noEdits: Theme.textTertiary
        }
    }

    private var short: String {
        switch verification {
        case .tested(let passed): passed ? "Tests passed" : "Tests failed"
        case .checked(let passed): passed ? "Not tested" : "Build failed"
        case .unchecked: "Not tested"
        case .noEdits: ""
        }
    }
}
