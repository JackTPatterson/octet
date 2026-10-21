import Combine
import SwiftUI

@MainActor
final class OnboardingChecklistStore: ObservableObject {
    static let shared = OnboardingChecklistStore()
    private let defaults: UserDefaults
    static let key = "octet.onboarding.checklist.v1"
    static let hiddenKey = "octet.onboarding.checklist.hidden"
    /// Steps checked off by hand.
    @Published private(set) var completed: Set<String>
    /// Steps Octet can see are done (OnboardingSignals).
    @Published private(set) var detected: Set<String> = []
    /// Put away with Hide; Help › Getting Started brings it back.
    @Published private(set) var hidden: Bool
    /// An issue tracker is connected, as last checked off the main thread.
    @Published private(set) var trackerConnected = false
    private var trackerCheck: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = OnboardingChecklistStep.valid(defaults.stringArray(forKey: Self.key) ?? [])
        hidden = defaults.bool(forKey: Self.hiddenKey)
    }

    func set(_ step: OnboardingChecklistStep, complete: Bool) {
        if complete { completed.insert(step.rawValue) } else { completed.remove(step.rawValue) }
        defaults.set(completed.sorted(), forKey: Self.key)
    }

    func update(_ signals: OnboardingSignals) {
        let found = OnboardingChecklistStep.detected(signals)
        if found != detected { detected = found }
    }

    /// Done either way.
    var done: Set<String> { completed.union(detected) }
    func isDone(_ step: OnboardingChecklistStep) -> Bool { done.contains(step.rawValue) }
    var isComplete: Bool { done.count == OnboardingChecklistStep.allCases.count }
    var progress: Double { Double(done.count) / Double(OnboardingChecklistStep.allCases.count) }

    func setHidden(_ value: Bool) {
        hidden = value
        defaults.set(value, forKey: Self.hiddenKey)
    }

    /// Looks again for a connected tracker. That's a Keychain query and a
    /// file read, so it runs off the main thread and the last answer is kept.
    func refreshTrackers() {
        guard trackerCheck == nil else { return }
        trackerCheck = Task { [weak self] in
            let connected = await Task.detached(priority: .utility) { OnboardingSignalsReader.trackerConnected() }.value
            self?.trackerConnected = connected
            self?.trackerCheck = nil
        }
    }
}

/// Reads what Octet can see of the person's setup for the checklist.
@MainActor
enum OnboardingSignalsReader {
    static func read(store: SessionStore, trackerConnected: Bool) -> OnboardingSignals {
        let values = SettingsStore.shared.values
        let defaults = OctetSettings.defaults
        let home = NSHomeDirectory()
        return OnboardingSignals(
            openedProject: store.snapshot.workspaces.contains { workspace in
                store.snapshot.directory(ofWorkspace: workspace.workspaceId)
                    .map { OnboardingSignals.isProject($0, home: home) } ?? false
            },
            agentInstalled: AgentDiscoveryStore.shared.agents.contains { $0.executablePath != nil },
            appearanceChanged: values.themeName != defaults.themeName
                || values.matchSystemAppearance != defaults.matchSystemAppearance
                || values.importedTheme != nil
                || values.fontFamily != defaults.fontFamily
                || values.fontSize != defaults.fontSize,
            trackerConnected: trackerConnected,
            notificationsAllowed: NotificationPermission.shared.status == .allowed,
            notificationsChosen: values.notifications != defaults.notifications
                || values.notificationDelaySeconds != defaults.notificationDelaySeconds
                || values.agentSounds != defaults.agentSounds
                || values.notifyFinished != defaults.notifyFinished
                || values.notifyNeedsInput != defaults.notifyNeedsInput
                || values.notifyFailed != defaults.notifyFailed
        )
    }

    /// GitHub CLI signed in, or a Linear or Jira connection saved. Blocking:
    /// call it off the main thread.
    nonisolated static func trackerConnected() -> Bool {
        let hosts = OnboardingSignals.githubHostsPath(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
        if let text = try? String(contentsOfFile: hosts, encoding: .utf8), OnboardingSignals.githubSignedIn(hostsYAML: text) {
            return true
        }
        return [IssueTracker.linear, .jira].contains { IssueCredentialStore.hasConnection($0) }
    }
}

struct OnboardingChecklistRow: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var checklist: OnboardingChecklistStore = .shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permission = NotificationPermission.shared
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    let openProject: () -> Void
    @State private var showing = false
    @State private var hovered = false

    private var total: Int { OnboardingChecklistStep.allCases.count }

    var body: some View {
        if !checklist.hidden {
            row
                .onAppear { refresh(trackers: true) }
                // Each workspace's folder, so moving one into a project counts.
                .onReceive(window.store.$snapshot.map { snapshot in
                    snapshot.workspaces.map { snapshot.directory(ofWorkspace: $0.workspaceId) }
                }.removeDuplicates()) { _ in refresh() }
                .onReceive(checklist.$trackerConnected) { _ in refresh() }
                .onReceive(discovery.$agents) { _ in refresh() }
                .onReceive(permission.$status) { _ in refresh() }
                .onChange(of: settings.values) { _, _ in refresh() }
                .onChange(of: showing) { _, open in if open { refresh(trackers: true) } }
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            Button { showing.toggle() } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Theme.textTertiary.opacity(0.3), lineWidth: 2)
                        Circle().trim(from: 0, to: checklist.progress)
                            .stroke(checklist.isComplete ? Theme.success : Theme.textSecondary,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 14, height: 14).frame(width: 18)
                    Text(checklist.isComplete ? "All set up" : "Onboarding checklist").font(Theme.uiFont).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Onboarding checklist")
            .accessibilityValue("\(checklist.done.count) of \(total) complete")
            .accessibilityAction(named: "Hide Checklist") { hide() }
            if checklist.isComplete {
                OctetButton(title: "Done — Hide", kind: .ghost, compact: true) { hide() }
                    .help("Put the checklist away. Help › Getting Started brings it back.")
            }
        }
        // Not everyone wants every step: it can go away before it's done.
        .contextMenu { Button("Hide Checklist") { hide() } }
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered || showing ? Theme.hover : Color.clear))
        .onHover { hovered = $0 }
        .help("Getting started · \(checklist.done.count) of \(total) complete")
        .popover(isPresented: $showing, arrowEdge: .trailing) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Getting started").font(Theme.uiFontMedium)
                Spacer()
                Text("\(checklist.done.count) of \(total)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            Text("Steps tick themselves as Octet sees them done. Check off the rest when you're ready.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(OnboardingChecklistStep.allCases) { step in
                stepRow(step)
            }
            HStack(spacing: Theme.Space.md) {
                OctetButton(title: "Take the Tour", icon: "sparkles", kind: .ghost, compact: true) {
                    showing = false
                    FirstRunCenter.shared.present()
                }
                Spacer()
                // Always offered: some steps may never apply to you.
                OctetButton(title: checklist.isComplete ? "Done — Hide" : "Hide",
                            kind: checklist.isComplete ? .primary : .ghost, compact: true) { hide() }
                    .help("Put the checklist away. Help › Getting Started brings it back.")
            }
        }
        .padding(18).frame(width: 360).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
    }

    private func stepRow(_ step: OnboardingChecklistStep) -> some View {
        let auto = checklist.detected.contains(step.rawValue)
        return HStack(alignment: .top, spacing: 10) {
            if auto {
                // The step's value says Done; the tick is only for the eye.
                OctetIcon("checkmark.circle.fill", size: 16).foregroundStyle(Theme.success)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            } else {
                Toggle(step.title, isOn: Binding(get: { checklist.completed.contains(step.rawValue) },
                                                 set: { checklist.set(step, complete: $0) }))
                    .toggleStyle(OctetCheckboxStyle()).labelsHidden()
                    .accessibilityLabel("Completed: " + step.title)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(Theme.uiFontMedium)
                    .foregroundStyle(checklist.isDone(step) ? Theme.textSecondary : Theme.textPrimary)
                Text(auto ? "Done. Octet noticed." : step.detail)
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(checklist.isDone(step) ? "Done" : "Not done")
            Spacer(minLength: 4)
            OctetButton(title: "Open", kind: .ghost, compact: true) { open(step) }
                .accessibilityLabel("Open: " + step.title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.title)
    }

    private func refresh(trackers: Bool = false) {
        if trackers { checklist.refreshTrackers() }
        checklist.update(OnboardingSignalsReader.read(store: window.store, trackerConnected: checklist.trackerConnected))
    }

    private func hide() {
        showing = false
        MotionPreferences.shared.perform(.sidebar) { checklist.setHidden(true) }
        ToastCenter.shared.info("Checklist hidden", detail: "Help › Getting Started brings it back")
    }

    private func open(_ step: OnboardingChecklistStep) {
        showing = false
        switch step {
        case .project: openProject()
        case .agent: SettingsOpener.open(.agents)
        case .notifications: SettingsOpener.open(.notifications)
        case .appearance: SettingsOpener.open(.appearance)
        case .issues: window.ui.showPlane(.tickets)
        }
    }
}
