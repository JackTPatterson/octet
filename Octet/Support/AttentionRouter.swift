import AppKit
import Combine
import SwiftUI
import UserNotifications

/// The one place agent notices go through. It hears from the session
/// server's snapshots (through `AgentBannerCenter.show`) and from Octet's
/// own conversations (watched here), and for each event picks a single way
/// to say it (`AttentionRouting.delivery`): nothing when you're looking at
/// it, a banner when Octet is in front, a macOS notification (or the
/// Notch's peek) when it isn't. It also keeps the Dock badge: how many
/// agents wait on you, plus waits and check-ins that are ready.
@MainActor
final class AttentionRouter {
    static let shared = AttentionRouter()

    /// Conversations that finished while you were looking elsewhere: Done
    /// until seen, then Idle, as the session server does for its agents.
    private var unseenFinishes: Set<String> = []
    private var conversations = ConversationActivityWatcher()
    private var subscriptions: Set<AnyCancellable> = []
    private var storeSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var passScheduled = false
    private var badgeScheduled = false
    private var notificationsAllowed = false
    private var askedForNotifications = false

    private init() {
        AgentCenter.shared.objectWillChange
            .sink { [weak self] in self?.schedulePass() }
            .store(in: &subscriptions)
        WindowRegistry.shared.$windows
            .sink { [weak self] windows in self?.watch(windows) }
            .store(in: &subscriptions)
        AgentsStore.shared.$agents.sink { [weak self] _ in self?.scheduleBadge() }.store(in: &subscriptions)
        CodexAgentsStore.shared.$agents.sink { [weak self] _ in self?.scheduleBadge() }.store(in: &subscriptions)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in
                    self?.schedulePass()
                    self?.refreshAuthorization()
                }
                .store(in: &subscriptions)
        }
        refreshAuthorization()
    }

    private func watch(_ windows: [WindowContext]) {
        let live = Set(windows.map { ObjectIdentifier($0.store) })
        storeSubscriptions = storeSubscriptions.filter { live.contains($0.key) }
        for window in windows where storeSubscriptions[ObjectIdentifier(window.store)] == nil {
            storeSubscriptions[ObjectIdentifier(window.store)] = window.store.$snapshot
                .map { $0.agents.map(\.agentStatus) }
                .removeDuplicates()
                .sink { [weak self] _ in self?.scheduleBadge() }
        }
        scheduleBadge()
    }

    // MARK: - Events

    /// Notices for `events`, each one way only.
    func route(_ events: [AgentEvent]) {
        let settings = SettingsStore.shared.values
        // Settings › Notifications: the kinds of notice wanted, and whether
        // one about what you're looking at is still worth saying.
        let events = events.filter(settings.noticeFilter.allows)
        let suppressVisible = settings.notifySuppressWhileVisible
        let setting: AttentionRouting.Setting = switch settings.notifications {
        case .off: .off
        case .system: .system
        case .banner: .inOctet
        }
        let active = NSApp?.isActive == true
        var peeks: [AgentEvent] = []
        for event in events {
            let context = AttentionRouting.Context(
                setting: setting, appActive: active, onScreen: suppressVisible && isOnScreen(event),
                fromSessionServer: event.sessionId == nil,
                notchPeeks: NotchController.shared.peeksOnAgentEvents,
                systemAllowed: notificationsAllowed && CheckInCenter.shared.allowsSystemNotifications
            )
            let delivery = AttentionRouting.delivery(context)
            switch delivery {
            case .none: break
            case .banner: AgentBannerCenter.shared.present(event)
            case .systemNotification: post(event)
            case .notchPeek: peeks.append(event)
            case .dockBounce:
                NSApp.requestUserAttention(.informationalRequest)
                askForNotificationsOnce()
            }
            if delivery != .none, active { announce(event) }
        }
        if !peeks.isEmpty { NotchController.shared.agentEvents(peeks) }
        if !active { AgentBannerCenter.shared.pushToPhone(events) }
        scheduleBadge()
    }

    /// A conversation just asked for permission or a question: look now
    /// rather than at the next change, so the notice isn't late.
    func conversationNeedsAttention(_ session: AgentSession) {
        pass()
    }

    func hasUnseenFinish(_ sessionId: String) -> Bool { unseenFinishes.contains(sessionId) }

    private func schedulePass() {
        guard !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.passScheduled = false
            self.pass()
        }
    }

    /// Compares every conversation's state with the last pass, raises what
    /// changed, and clears Done from the ones now in view.
    private func pass() {
        let sessions = AgentCenter.shared.sessions
        var seenChanged = false
        for session in sessions where unseenFinishes.contains(session.id) && conversationOnScreen(session) {
            unseenFinishes.remove(session.id)
            seenChanged = true
            clearNotification(agentKey: "chat:" + session.id)
        }
        let live = Set(sessions.map(\.id))
        if !unseenFinishes.isSubset(of: live) {
            unseenFinishes.formIntersection(live)
            seenChanged = true
        }
        let states = Dictionary(sessions.map { ($0.id, $0.agentState) }, uniquingKeysWith: { first, _ in first })
        let transitions = conversations.transitions(states)
        var events: [AgentEvent] = []
        for transition in transitions {
            guard let session = sessions.first(where: { $0.id == transition.id }) else { continue }
            let onScreen = conversationOnScreen(session)
            if transition.kind == .finished, !onScreen {
                unseenFinishes.insert(session.id)
                seenChanged = true
            }
            guard !onScreen || !SettingsStore.shared.values.notifySuppressWhileVisible else { continue }
            events.append(event(for: session, transition: transition))
        }
        // The finish itself turned Done on: draw it.
        if seenChanged { DispatchQueue.main.async { AgentCenter.shared.objectWillChange.send() } }
        if !events.isEmpty { route(events) }
        scheduleBadge()
    }

    private func event(for session: AgentSession, transition: ConversationActivityWatcher.Transition) -> AgentEvent {
        var detail = session.lastReplyPreview
        if let permission = session.pendingPermission {
            detail = permission.toolName == "ExitPlanMode" ? "Wants to go ahead with its plan" : "Asks to use \(permission.toolName)"
        } else if session.pendingQuestion != nil {
            detail = "Has a question for you"
        }
        return AgentEvent(id: "chat:\(session.id)-\(transition.state.rawValue)-\(Int(Date().timeIntervalSince1970))",
                          kind: transition.kind, agent: session.engine.agent, paneId: "", tabId: nil,
                          workspaceId: session.workspaceId, label: session.title, workedFor: transition.workedFor,
                          at: Date(), state: transition.state, sessionId: session.id, detail: detail)
    }

    // MARK: - On screen

    private func isOnScreen(_ event: AgentEvent) -> Bool {
        guard NSApp?.isActive == true, let window = WindowRegistry.shared.key, window.isKey else { return false }
        if let id = event.sessionId {
            return AgentCenter.shared.sessions.first { $0.id == id }.map(conversationOnScreen) ?? false
        }
        guard let tab = event.tabId, window.displayedFocusedTabId == tab else { return false }
        // A conversation or the hub drawn over the workspace hides the tab.
        let workspace = window.focusedWorkspace?.workspaceId
        return AgentCenter.shared.active(in: workspace) == nil && AgentCenter.shared.board(in: workspace) == nil
    }

    /// The conversation is the one drawn in the key window, with Octet in front.
    private func conversationOnScreen(_ session: AgentSession) -> Bool {
        guard NSApp?.isActive == true, let window = WindowRegistry.shared.key, window.isKey,
              window.focusedWorkspace?.workspaceId == session.workspaceId else { return false }
        return AgentCenter.shared.active(in: session.workspaceId)?.id == session.id
            && AgentCenter.shared.board(in: session.workspaceId) == nil
    }

    // MARK: - Going to it

    /// Brings Octet forward on the agent an event is about.
    func open(_ event: AgentEvent) {
        if let id = event.sessionId, let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) {
            let window = WindowRegistry.shared.window(showing: session.workspaceId) ?? WindowRegistry.shared.key
            window?.bringForward()
            AgentCenter.shared.setBoard(nil, in: session.workspaceId)
            window?.focusWorkspace(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
            return
        }
        let window = WindowRegistry.shared.windows.first { $0.store.snapshot.agents.contains { $0.paneId == event.paneId } }
            ?? WindowRegistry.shared.key
        window?.bringForward()
        AgentCenter.shared.setBoard(nil, in: event.workspaceId)
        AgentCenter.shared.setActive(nil, in: event.workspaceId)
        window?.focus(event)
    }

    // MARK: - System notifications

    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private func refreshAuthorization() {
        notificationCenter?.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { MainActor.assumeIsolated { AttentionRouter.shared.notificationsAllowed = allowed } }
        }
    }

    /// The first time a notice can't be posted, ask macOS once; the Dock
    /// bounce covers this one.
    private func askForNotificationsOnce() {
        guard !askedForNotifications, CheckInCenter.shared.allowsSystemNotifications, let center = notificationCenter else { return }
        askedForNotifications = true
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { AttentionRouter.shared.refreshAuthorization() } }
            }
        }
    }

    /// "api / fix-login — Claude Code needs input", with what it last said.
    /// Same agent, same identifier: the newer one replaces the last.
    private func post(_ event: AgentEvent) {
        guard let center = notificationCenter else { return }
        let place = self.place(of: event)
        let content = UNMutableNotificationContent()
        content.title = AttentionRouting.title(repo: place.repo, workspace: place.workspace,
                                               agent: AgentBrand.forAgent(event.agent)?.displayName ?? event.agent ?? "An agent",
                                               state: event.phrase)
        content.body = [event.label, event.detail ?? place.lastLine].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ": ")
        if SettingsStore.shared.values.agentSounds { content.sound = .default }
        let identifier = AttentionRouting.identifier(agentKey: event.agentKey)
        content.threadIdentifier = identifier
        content.userInfo = Self.userInfo(for: event)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    private func clearNotification(agentKey: String) {
        notificationCenter?.removeDeliveredNotifications(withIdentifiers: [AttentionRouting.identifier(agentKey: agentKey)])
    }

    private func place(of event: AgentEvent) -> (repo: String?, workspace: String?, lastLine: String?) {
        let store = WindowRegistry.shared.windows.first { window in
            window.store.snapshot.workspaces.contains { $0.workspaceId == event.workspaceId }
        }?.store
        let workspace = store?.snapshot.workspaces.first { $0.workspaceId == event.workspaceId }?.label
        let directory = event.workspaceId.flatMap { store?.snapshot.directory(ofWorkspace: $0) }
            ?? event.sessionId.flatMap { id in AgentCenter.shared.sessions.first { $0.id == id }?.cwd }
        let terminal = store?.snapshot.agents.first { $0.paneId == event.paneId }?.terminalId
        let lastLine = terminal.flatMap { store?.usageTracker.lastActivity[$0] }
        return (directory.map { URL(fileURLWithPath: $0).lastPathComponent }, workspace, lastLine)
    }

    nonisolated static let userInfoKey = "octetAgent"

    private static func userInfo(for event: AgentEvent) -> [String: Any] {
        var info: [String: Any] = ["paneId": event.paneId, "kind": event.kind == .finished ? "finished" : "needsInput"]
        if let session = event.sessionId { info["sessionId"] = session }
        if let tab = event.tabId { info["tabId"] = tab }
        if let workspace = event.workspaceId { info["workspaceId"] = workspace }
        if let agent = event.agent { info["agent"] = agent }
        return [userInfoKey: info]
    }

    /// A click on one of Octet's agent notifications (from the notification
    /// centre's delegate). False when it isn't one.
    @discardableResult
    func openNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let info = userInfo[Self.userInfoKey] as? [String: Any] else { return false }
        let event = AgentEvent(id: "notification", kind: info["kind"] as? String == "finished" ? .finished : .needsInput,
                               agent: info["agent"] as? String, paneId: info["paneId"] as? String ?? "",
                               tabId: info["tabId"] as? String, workspaceId: info["workspaceId"] as? String,
                               label: "", workedFor: nil, at: Date(), sessionId: info["sessionId"] as? String)
        NSApp.activate(ignoringOtherApps: true)
        open(event)
        return true
    }

    // MARK: - VoiceOver

    /// Says it to VoiceOver too: a banner alone is easy to miss.
    private func announce(_ event: AgentEvent) {
        let name = AgentBrand.forAgent(event.agent)?.displayName ?? "Agent"
        Self.announce("\(name) \(event.phrase): \(event.label)")
    }

    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Dock badge

    private func scheduleBadge() {
        guard !badgeScheduled else { return }
        badgeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.badgeScheduled = false
            self.refreshDockBadge()
        }
    }

    /// Agents waiting on you, in every window and the background, plus
    /// waits ready and check-ins due: one count, set in one place.
    func refreshDockBadge() {
        var seen = Set<String>()
        var needing = 0
        for window in WindowRegistry.shared.windows where !window.closing {
            for agent in AgentsHubList.agents(store: window.store) where seen.insert(agent.id).inserted {
                if agent.status.needsYou { needing += 1 }
            }
        }
        let ready = WaitCenter.shared.ready.count + CheckInCenter.shared.dueCount
        let label = AttentionRouting.dockBadge(agentsNeedingYou: needing, readyWork: ready)
        if NSApp?.dockTile.badgeLabel != label { NSApp?.dockTile.badgeLabel = label }
    }
}
