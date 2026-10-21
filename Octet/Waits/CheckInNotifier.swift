import AppKit
import Foundation
import UserNotifications

/// macOS local notifications for upcoming check-ins, so the reminder comes
/// even when Octet isn't running. These are Octet's own notifications and
/// nothing else: no launchd agent, nothing outside Octet's data. Clicking
/// one opens Octet through `octet://checkin?id=`, which catches up and runs
/// that check-in.
///
/// Never used by a verification copy or the debug sample (see
/// `CheckInCenter.allowsSystemNotifications`).
@MainActor
final class CheckInNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckInNotifier()

    private static let prefix = CheckInNotificationPlan.identifierPrefix
    private static let askedKey = "octet.checkins.notificationsExplained"

    /// A summary of what's scheduled, so unchanged lists aren't rewritten.
    private var scheduledSignature = ""
    private var delegateSet = false

    private var center: UNUserNotificationCenter? {
        // A bare process (a test host without a bundle) has no center.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func attach() {
        guard !delegateSet, let center else { return }
        delegateSet = true
        center.delegate = self
    }

    // MARK: - Permission

    /// Asks once, after saying why: Octet needs permission to show a
    /// notification when it isn't open. The system's own question follows.
    func explainAndRequest() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.askedKey), let center else { return }
        defaults.set(true, forKey: Self.askedKey)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ConfirmCenter.shared.ask(
                        title: "Remind you when Octet is closed?",
                        message: "A check-in can come round days from now, when Octet may not be open. Octet can schedule a macOS notification for each one so you're reminded anyway; clicking it opens Octet and carries on. macOS will ask to allow notifications next. You can change this in Settings › Agents › Check-ins.",
                        confirmTitle: "Continue"
                    ) { _ in
                        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
            }
        }
    }

    // MARK: - Scheduling

    /// Makes the pending notifications match the check-ins: the next two
    /// occurrences of each active one, nothing for paused, finished or
    /// removed ones.
    func sync(_ waits: [Wait], enabled: Bool, now: Date = Date()) {
        guard let center else { return }
        let requests = enabled ? Self.requests(for: waits, now: now) : []
        let signature = requests.map { "\($0.identifier)@\(($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.description ?? "")" }
            .joined(separator: "|")
        guard signature != scheduledSignature else { return }
        scheduledSignature = signature
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for request in requests { center.add(request) { _ in } }
        }
    }

    /// Takes a fired check-in's notification off the screen, now that Octet
    /// has dealt with it itself.
    func clearDelivered(for id: String) {
        guard let center else { return }
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(Self.prefix + id + ".") }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// What to schedule for `waits`, as macOS requests.
    static func requests(for waits: [Wait], now: Date, calendar: Calendar = .current) -> [UNNotificationRequest] {
        CheckInNotificationPlan.plan(for: waits, now: now, calendar: calendar).map { item in
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = Self.prefix + item.waitId
            content.userInfo = ["checkin": item.waitId]
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.date)
            return UNNotificationRequest(identifier: item.identifier, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        }
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let id = userInfo["checkin"] as? String
        // Agent notifications share this delegate (only one is allowed); the
        // router knows where those go.
        let agentInfo = userInfo[AttentionRouter.userInfoKey] as? [String: Any]
        DispatchQueue.main.async {
            if let agentInfo {
                MainActor.assumeIsolated { _ = AttentionRouter.shared.openNotification([AttentionRouter.userInfoKey: agentInfo]) }
            } else if let id, let url = URL(string: OctetURL.checkin(id: id).url.absoluteString), let command = OctetURL(url) {
                MainActor.assumeIsolated { OctetURLHandler.handle(command) }
            }
        }
        completionHandler()
    }

    /// While Octet is in front it shows its own notice, so the system's isn't doubled.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
