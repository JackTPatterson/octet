#if DEBUG
import AppKit
import Foundation

/// Verification hooks for check-ins (OCTET_OPEN_WINDOW=checkin-sample or
/// checkin-composer). The sample is made up and lives in memory only: it
/// never schedules a macOS notification, never saves, and never touches a
/// real session.
@MainActor
enum CheckInDebug {
    /// Expand the first row, to see its record.
    static var expandFirst = false

    /// `checkin-sample[:expanded]`, `checkin-composer[:picker|:weekly|:edit]`.
    static func open(_ spec: String, window: WindowContext) {
        let parts = spec.split(separator: ":").map(String.init)
        switch parts.first {
        case "checkin-sample":
            expandFirst = parts.dropFirst().first == "expanded"
            loadSample(window: window)
        case "checkin-composer":
            if parts.dropFirst().first == "sample" { loadSample(window: window) }
            let variant = parts.last
            let center = CheckInCenter.shared
            if variant == "edit", let first = center.checkIns.first(where: { $0.checkIn?.recurrence != nil }) {
                return center.edit(first.id)
            }
            center.compose(workspaceId: window.focusedWorkspace?.workspaceId,
                           prompt: "Check the paper-trading results since last time, compare them with the benchmark, and report drift and anything unexpected.",
                           first: CheckInDraft.morning(daysAhead: 3), title: "Mean-reversion paper run", pickTime: variant == "picker")
            if variant == "weekly" {
                center.draft?.repeats = .weekly
                center.draft?.weekday = 2
            } else if variant == "every" {
                center.draft?.repeats = .every
                center.draft?.every = 2
                center.draft?.stop = .count
            }
        default:
            break
        }
    }

    static func loadSample(window: WindowContext) {
        let now = Date()
        let calendar = Calendar.current
        let cwd = NSHomeDirectory() + "/Developer/quant-paper-trader"
        func origin(session: String?) -> Wait.Origin {
            Wait.Origin(cwd: cwd, branch: "main", workspaceId: window.focusedWorkspace?.workspaceId,
                        workspaceLabel: "quant-paper-trader", agent: "claude", sessionId: session)
        }
        func entry(_ hoursAgo: Double, _ outcome: CheckInLogEntry.Outcome, alive: Bool?, missed: Int = 0, note: String? = nil,
                   manual: Bool = false) -> CheckInLogEntry {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            return CheckInLogEntry(at: at, due: at.addingTimeInterval(-30), sessionAlive: alive, outcome: outcome, missed: missed,
                                   note: note, manual: manual)
        }

        // A daily check on a paper-trading run: resumed its session when it had died.
        let dailyRule = CheckInRecurrence.daily(hour: 9, minute: 0, after: now, calendar: calendar)
        var daily = Wait.makeCheckIn(
            title: "Mean-reversion paper run",
            prompt: "Check the paper-trading results since last time, compare them with the benchmark, and report drift and anything unexpected.",
            mode: .wake, first: dailyRule.start, recurrence: dailyRule,
            origin: origin(session: "sample-session-1"), createdBy: "Claude", now: now.addingTimeInterval(-9 * 86_400))
        daily.checkIn?.fired = 9
        daily.checkIn?.log = [
            entry(72, .sentToConversation, alive: true),
            entry(48, .resumedSession, alive: false, note: "with Claude's own resume, in ~/Developer/quant-paper-trader"),
            entry(24, .resumedSession, alive: false, missed: 1, note: "Octet was closed"),
        ]

        // A weekly review that reminds and wakes, with a catch-up that collapsed missed ones.
        let weeklyRule = CheckInRecurrence.weekly(weekday: 2, hour: 8, minute: 30, after: now, calendar: calendar)
        var weekly = Wait.makeCheckIn(
            title: "Weekly strategy review", prompt: "Review this week's fills, slippage and drawdown against the backtest. Summarise in five bullets.",
            mode: .both, first: weeklyRule.start, recurrence: weeklyRule, origin: origin(session: "sample-session-2"),
            createdBy: "you", now: now.addingTimeInterval(-30 * 86_400))
        weekly.checkIn?.fired = 4
        weekly.checkIn?.log = [
            entry(24 * 14, .newConversation, alive: false, note: "its session file is gone"),
            entry(24 * 7, .sentToTerminal, alive: true),
        ]

        // One that fell due and is waiting for you.
        var overdue = Wait.makeCheckIn(
            title: "Walk-forward backtest 2018–2025", prompt: "The long backtest should be done. Read the results file and compare Sharpe with the live paper run.",
            mode: .remind, first: now.addingTimeInterval(-5 * 3600), recurrence: nil, origin: origin(session: nil),
            createdBy: "Claude", now: now.addingTimeInterval(-6 * 86_400))
        overdue.checkIn?.fired = 1
        overdue.checkIn?.dueSince = now.addingTimeInterval(-5 * 3600)
        overdue.checkIn?.finishedAt = now.addingTimeInterval(-5 * 3600)
        overdue.checkIn?.log = [entry(5, .reminded, alive: nil)]

        // One that is paused.
        let soakRule = CheckInRecurrence.every(6, .hours, startingAt: now.addingTimeInterval(2 * 3600))
        var paused = Wait.makeCheckIn(
            title: "Funding-rate soak test", prompt: "Look at the soak test log for errors and report uptime.", mode: .both,
            first: soakRule.start, recurrence: soakRule, origin: origin(session: "sample-session-3"), createdBy: "you",
            now: now.addingTimeInterval(-86_400))
        paused.checkIn?.paused = true
        paused.checkIn?.fired = 3
        paused.checkIn?.log = [entry(12, .sentToConversation, alive: true), entry(6, .sentToConversation, alive: true)]

        WaitCenter.shared.installSample([daily, weekly, overdue, paused])
        CheckInCenter.shared.showSampleStall()
        CheckInCenter.shared.updateBadge()
    }
}
#endif
