import AppKit
import SwiftUI
import UserNotifications

extension AgentSession.Engine {
    /// Every agent Octet runs conversations with, in the order it offers them.
    static let offered: [AgentSession.Engine] = [.claude, .codex, .opencode, .pi, .qwen]

    /// Settings › Agents › Default agent, for a new conversation that
    /// doesn't name one.
    @MainActor static var preferred: AgentSession.Engine {
        AgentSession.Engine(rawValue: SettingsStore.shared.values.defaultAgent) ?? .claude
    }
}

extension OctetSettings {
    /// The notices the person asked for, for whoever raises them.
    var noticeFilter: AgentNoticeFilter {
        AgentNoticeFilter(finished: notifyFinished, needsInput: notifyNeedsInput, failed: notifyFailed)
    }
}

/// Whether macOS lets Octet post notifications, and the ways to change
/// that: ask once, or open the page in System Settings where a "no" is
/// undone. Read fresh whenever the Notifications page appears or Octet comes
/// back to the front, since the answer changes outside Octet.
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()

    enum Status: Equatable {
        case unknown, notAsked, denied, allowed
        /// A bare process (a test host) has no notification center at all.
        case unavailable
    }

    @Published private(set) var status: Status = .unknown
    private var observer: NSObjectProtocol?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { NotificationPermission.shared.refresh() } }
        refresh()
    }

    func refresh() {
        guard let center else { status = .unavailable; return }
        center.getNotificationSettings { settings in
            let status: Status = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .denied: .denied
            case .notDetermined: .notAsked
            @unknown default: .unknown
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { NotificationPermission.shared.status = status } }
        }
    }

    /// The system's own question; `done` hears the answer.
    func request(_ done: @escaping (Bool) -> Void = { _ in }) {
        guard let center else { done(false); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotificationPermission.shared.refresh()
                    done(granted)
                }
            }
        }
    }

    /// System Settings › Notifications, on Octet's own entry where macOS
    /// supports going straight to it.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Posts a sample notification now, asking first if macOS never has.
    /// The result says what happened, for the row to show.
    func sendTest(_ done: @escaping (TestResult) -> Void) {
        guard let center, CheckInCenter.shared.allowsSystemNotifications else { done(.unavailable); return }
        center.getNotificationSettings { settings in
            let post = {
                let content = UNMutableNotificationContent()
                content.title = "Octet — test notification"
                content.body = "This is how Octet tells you an agent finished or needs you."
                if SettingsStore.shared.values.agentSounds { content.sound = .default }
                center.add(UNNotificationRequest(identifier: "octet.test", content: content, trigger: nil)) { error in
                    DispatchQueue.main.async { done(error == nil ? .sent : .failed(error?.localizedDescription ?? "")) }
                }
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        NotificationPermission.shared.request { granted in
                            if granted { post() } else { done(.denied) }
                        }
                    }
                }
            default:
                DispatchQueue.main.async { done(.denied) }
            }
        }
    }

    enum TestResult: Equatable {
        case sent, denied, unavailable
        case failed(String)
    }
}

/// Settings › Notifications: what Octet tells you about, how, and whether
/// macOS will let it.
struct NotificationSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var permission = NotificationPermission.shared
    @State private var testResult: NotificationPermission.TestResult?
    @State private var bannerShown = false

    private var off: Bool { settings.values.notifications == .off }
    private var offReason: String? { off ? "Notices are off. Choose how they arrive above." : nil }

    var body: some View {
        SettingsGroup(title: "Delivery") {
            SettingsRow(title: "When an agent finishes or needs you",
                        detail: "In Octet shows a banner while Octet is in front and a macOS notification while it's behind. macOS notification lets the terminal server post them itself.",
                        setting: \.notifications) {
                OctetSelect(selection: $settings.values.notifications, options: [(OctetSettings.NotificationDelivery.banner, "In Octet"), (OctetSettings.NotificationDelivery.system, "macOS notification"), (OctetSettings.NotificationDelivery.off, "Off")], width: 190)
            }
            SettingsDivider()
            SettingsRow(title: "Wait before notifying", detail: "Skipped if you return to the agent first.",
                        setting: \.notificationDelaySeconds, unavailable: offReason) {
                OctetNumberField(label: "Wait before notifying", value: $settings.values.notificationDelaySeconds,
                                 range: 0...60, unit: "s", spokenValue: { "\(Int($0)) seconds" })
            }
            SettingsDivider()
            SettingsRow(
                title: "Quick answers",
                detail: "Open a small panel in the window corner when an agent needs a choice, answer, or permission.",
                setting: \.agentQuickAnswers
            ) {
                Toggle("Quick answers", isOn: $settings.values.agentQuickAnswers).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Tell me when") {
            SettingsRow(title: "Agent needs input", detail: "It asks a question, wants permission, or has a plan for you to approve.",
                        setting: \.notifyNeedsInput, unavailable: offReason) {
                Toggle("Agent needs input", isOn: $settings.values.notifyNeedsInput).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Agent finished", detail: "Its turn ended and it's waiting for what's next.",
                        setting: \.notifyFinished, unavailable: offReason) {
                Toggle("Agent finished", isOn: $settings.values.notifyFinished).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Agent failed", detail: "Its turn stopped on an error.",
                        setting: \.notifyFailed, unavailable: offReason) {
                Toggle("Agent failed", isOn: $settings.values.notifyFailed).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Suppress while the agent is on screen",
                        detail: "No notice for an agent whose tab or conversation you're looking at, with Octet in front.",
                        setting: \.notifySuppressWhileVisible, unavailable: offReason) {
                Toggle("Suppress while the agent is on screen", isOn: $settings.values.notifySuppressWhileVisible)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "Sounds") {
            SettingsRow(title: "Play sounds", detail: "When agents in other workspaces change state, and with macOS notifications.", setting: \.agentSounds) {
                Toggle("Play sounds", isOn: $settings.values.agentSounds).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Subagent finished sound",
                        detail: "Played by a subagent's tab when it finishes, so it sounds different from a main agent.",
                        setting: \.subagentFinishedSound,
                        unavailable: settings.values.agentSounds ? nil : "Turn on Play sounds to choose one.") {
                OctetSelect(selection: $settings.values.subagentFinishedSound,
                            options: [("", "None")] + SubagentWatch.sounds.map { ($0, $0) }, width: 140)
                .onChange(of: settings.values.subagentFinishedSound) { _, name in
                    if let path = SubagentWatch.soundPath(name), !name.isEmpty {
                        NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)?.play()
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: "Terminal bell",
                        detail: "A program in a pane rings the bell: a sound in the pane you're in, a notice for another, a Dock bounce while Octet is behind.",
                        setting: \.terminalBell) {
                Toggle("Terminal bell", isOn: $settings.values.terminalBell).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
        SettingsGroup(title: "macOS permission") {
            SettingsRow(title: "Notifications from Octet", detail: permissionDetail) {
                permissionControl
            }
            SettingsDivider()
            SettingsRow(title: "Send a test notification", detail: testDetail, unavailable: offReason) {
                OctetButton(title: "Send Test", icon: "play", compact: true) { sendTest() }
            }
        }
        SettingsGroup(title: "Recap") {
            SettingsRow(
                title: "Recap when you come back",
                detail: "When you come back after being away (the screen locked, Octet out of sight, or the Mac untouched), a strip at the top says what every agent did meanwhile. It opens by itself only when something needs you or is stuck. View › Show Recap brings it back.",
                setting: \.recap
            ) {
                Toggle("Recap when you come back", isOn: $settings.values.recap).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Away for at least", detail: "Shorter breaks don't get a recap. Not touching the Mac this long counts as away too.",
                        setting: \.recapAfterMinutes,
                        unavailable: settings.values.recap ? nil : "Turn on Recap when you come back first.") {
                OctetNumberField(label: "Away for at least", value: $settings.values.recapAfterMinutes,
                                 range: 1...120, unit: "min", spokenValue: { "\(Int($0)) minutes" })
            }
        }
        if PhonePush.offered {
            SettingsGroup(title: "Phone") {
                SettingsRow(
                    title: "Notices on your phone",
                    detail: "When an agent needs you or finishes while Octet isn't in front, a push goes to this ntfy topic. Install the ntfy app and subscribe to the same topic. Anyone who knows the topic can read it, so pick something hard to guess. Only the agent, the tab and what happened are sent.",
                    setting: \.phoneTopic
                ) {
                    CommittedTextField(label: "ntfy topic", placeholder: "topic, e.g. octet-7fq2k", value: $settings.values.phoneTopic, width: 220,
                                       validate: { value in
                                           value.isEmpty || value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                                               ? nil : "Letters, numbers, - and _ only" })
                }
                SettingsDivider()
                SettingsRow(title: "ntfy server", detail: "Leave empty for ntfy.sh, or your own server's address.", setting: \.phoneServer) {
                    CommittedTextField(label: "ntfy server", placeholder: "https://ntfy.sh", value: $settings.values.phoneServer, width: 220,
                                       validate: { _ in nil })
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear { permission.refresh() }
    }

    private var permissionDetail: String {
        switch permission.status {
        case .allowed: "Allowed. Octet can tell you about agents while it's behind other apps."
        case .notAsked: "macOS hasn't asked yet. Without it, a notice while Octet is behind is only a Dock bounce."
        case .denied: "Turned off in System Settings, so while Octet is behind other apps a notice is only a Dock bounce."
        case .unavailable: "This copy of Octet can't post notifications."
        case .unknown: "Checking…"
        }
    }

    @ViewBuilder private var permissionControl: some View {
        switch permission.status {
        case .allowed:
            Text("Allowed").font(Theme.uiFont).foregroundStyle(Theme.success)
        case .notAsked:
            OctetButton(title: "Allow…", compact: true) { permission.request() }
        case .denied:
            OctetButton(title: "Open System Settings", icon: "arrow.up.right", compact: true) { permission.openSystemSettings() }
        case .unavailable, .unknown:
            EmptyView()
        }
    }

    private var testDetail: String {
        switch testResult {
        case nil:
            settings.values.notifications == .banner
                ? "Shows the banner Octet uses in front, and posts the macOS notification it uses behind."
                : "Posts a macOS notification now."
        case .sent?:
            bannerShown ? "Sent: a banner at the top right, and a macOS notification." : "Sent. It should be in the top right of your screen."
        case .denied?:
            "macOS didn't show it: notifications for Octet are off. Turn them on with Open System Settings above."
        case .unavailable?:
            "This copy of Octet can't post notifications."
        case .failed(let reason)?:
            "macOS refused it: \(reason)"
        }
    }

    private func sendTest() {
        bannerShown = false
        if settings.values.notifications == .banner {
            AgentBannerCenter.shared.present(AgentEvent(
                id: "test-\(Int(Date().timeIntervalSince1970))", kind: .finished, agent: "claude", paneId: "",
                tabId: nil, workspaceId: nil, label: "Test notification", workedFor: nil, at: Date(),
                detail: "This is how Octet says an agent finished."))
            bannerShown = true
        }
        permission.sendTest { result in
            testResult = result
            permission.refresh()
        }
    }
}
