import Foundation

/// Where a notice about an agent goes: one place for each event, never two.
/// Octet's own decision, kept apart from AppKit so it can be tested.
enum AttentionRouting {
    enum Delivery: Equatable {
        /// You're looking at it, or notices are off.
        case none
        /// Octet's own banner, in the window in front.
        case banner
        /// A macOS notification, for when Octet isn't in front.
        case systemNotification
        /// The Notch's peek stands in for the notification.
        case notchPeek
        /// No notification allowed: the Dock icon bounces once.
        case dockBounce
    }

    /// How notices are delivered (Settings › Agents › Notifications).
    enum Setting: Equatable {
        case off
        /// Octet decides: a banner in front, a notification behind.
        case inOctet
        /// The session server posts system notifications for terminal agents
        /// itself; Octet only covers what it can't see.
        case system
    }

    struct Context: Equatable {
        var setting: Setting
        /// Octet is the active app.
        var appActive: Bool
        /// The agent's pane or conversation is on screen in the key window.
        var onScreen: Bool
        /// The event came from the session server's snapshot, which posts its
        /// own notification when the setting is `system`.
        var fromSessionServer: Bool
        /// The Notch is on, set to peek on agent events, and showing.
        var notchPeeks: Bool
        /// macOS lets Octet post notifications (and this isn't a test copy).
        var systemAllowed: Bool
    }

    static func delivery(_ context: Context) -> Delivery {
        if context.setting == .off { return .none }
        // The session server already told the system: don't say it twice.
        if context.setting == .system, context.fromSessionServer { return .none }
        if context.appActive {
            return context.onScreen ? .none : .banner
        }
        if context.notchPeeks { return .notchPeek }
        return context.systemAllowed ? .systemNotification : .dockBounce
    }

    /// The notification's title: "repo / workspace — Claude Code needs input".
    /// The workspace is left out when it's just the folder's name again.
    static func title(repo: String?, workspace: String?, agent: String, state: String) -> String {
        let place = [repo, workspace].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var unique: [String] = []
        for part in place where !unique.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            unique.append(part)
        }
        let what = "\(agent) \(state)"
        return unique.isEmpty ? what : "\(unique.joined(separator: " / ")) — \(what)"
    }

    /// One notification per agent: a newer one replaces the last.
    static func identifier(agentKey: String) -> String { "octet.agent." + agentKey }

    /// How many agents wait on you plus waits and check-ins ready, for the
    /// Dock; nothing at zero.
    static func dockBadge(agentsNeedingYou: Int, readyWork: Int) -> String? {
        let count = max(0, agentsNeedingYou) + max(0, readyWork)
        return count > 0 ? String(count) : nil
    }
}

/// Native conversations' state between looks, and the transitions worth a
/// notice, as `AgentActivityWatcher` does for the session server's agents.
struct ConversationActivityWatcher {
    struct Transition: Equatable {
        let id: String
        let kind: AgentEvent.Kind
        let state: AgentState
        /// How long it worked before this, when it was seen starting.
        let workedFor: TimeInterval?
    }

    private var states: [String: (state: AgentState, startedWorking: Date?)] = [:]
    private var primed = false

    init() {}

    /// What changed since the last call. The first call only records, so
    /// opening Octet doesn't announce every conversation.
    mutating func transitions(_ current: [String: AgentState], now: Date = Date()) -> [Transition] {
        var result: [Transition] = []
        var next: [String: (state: AgentState, startedWorking: Date?)] = [:]
        for (id, state) in current {
            let previous = states[id]
            let startedWorking = state == .working
                ? (previous?.state == .working ? previous?.startedWorking : now) ?? now
                : nil
            next[id] = (state, startedWorking)
            guard primed, let previous, previous.state != state else { continue }
            let workedFor = previous.state == .working ? previous.startedWorking.map { now.timeIntervalSince($0) } : nil
            if state.needsYou, !previous.state.needsYou {
                result.append(Transition(id: id, kind: .needsInput, state: state, workedFor: workedFor))
            } else if previous.state == .working, [.done, .idle, .failed, .planReady].contains(state) {
                result.append(Transition(id: id, kind: .finished, state: state, workedFor: workedFor))
            }
        }
        states = next
        primed = true
        return result.sorted { $0.id < $1.id }
    }
}
