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
    /// Put away with "Done — Hide"; Help › Getting Started brings it back.
    @Published private(set) var hidden: Bool

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
}

/// Reads what Octet can see of the person's setup for the checklist.
@MainActor
enum OnboardingSignalsReader {
    static func read(store: SessionStore, includeTrackers: Bool) -> OnboardingSignals {
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
            // A keychain read, so only when asked.
            trackerConnected: includeTrackers
                && [IssueTracker.linear, .jira].contains { !IssueCredentialStore.connections($0).isEmpty },
            notificationsAllowed: NotificationPermission.shared.status == .allowed
        )
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
    @State private var trackerConnected = false

    private var total: Int { OnboardingChecklistStep.allCases.count }

    var body: some View {
        if !checklist.hidden {
            row
                .onAppear { refresh(trackers: true) }
                .onReceive(window.store.$snapshot.map(\.workspaces.count).removeDuplicates()) { _ in refresh() }
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
            if checklist.isComplete {
                OctetButton(title: "Done — Hide", kind: .ghost, compact: true) { hide() }
                    .help("Put the checklist away. Help › Getting Started brings it back.")
            }
        }
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
                if checklist.isComplete {
                    OctetButton(title: "Done — Hide", kind: .primary, compact: true) { hide() }
                }
            }
        }
        .padding(18).frame(width: 360).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
    }

    private func stepRow(_ step: OnboardingChecklistStep) -> some View {
        let auto = checklist.detected.contains(step.rawValue)
        return HStack(alignment: .top, spacing: 10) {
            if auto {
                OctetIcon("checkmark.circle.fill", size: 16).foregroundStyle(Theme.success)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Done")
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
            Spacer(minLength: 4)
            OctetButton(title: "Open", kind: .ghost, compact: true) { open(step) }
        }
        .accessibilityElement(children: .contain)
    }

    private func refresh(trackers: Bool = false) {
        if trackers {
            trackerConnected = OnboardingSignalsReader.read(store: window.store, includeTrackers: true).trackerConnected
        }
        var signals = OnboardingSignalsReader.read(store: window.store, includeTrackers: false)
        signals.trackerConnected = trackerConnected
        checklist.update(signals)
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
