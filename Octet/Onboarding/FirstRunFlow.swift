import AppKit
import SwiftUI

/// The short welcome on Octet's first launch: how it looks, which agent it
/// starts, and whether it may notify. Every page can be skipped, the whole
/// thing too, and Help › Getting Started opens it again.
@MainActor
final class FirstRunCenter: ObservableObject {
    static let shared = FirstRunCenter()
    static let seenKey = "octet.firstRun.seen.v1"

    enum Page: Int, CaseIterable { case appearance, agent, notifications }

    @Published private(set) var presented = false
    @Published var page: Page = .appearance
    /// Where it was opened from, to draw in that window.
    private(set) weak var window: NSWindow?

    /// Shows it once per Mac. Someone who used Octet before this flow
    /// existed has settings and scans on record, and isn't new.
    func presentIfFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seenKey) else { return }
        defaults.set(true, forKey: Self.seenKey)
        let returning = [SettingsView.sectionKey, OnboardingChecklistStore.key, "octet.discovery.scannedAt.v1"]
            .contains { defaults.object(forKey: $0) != nil }
        // Never over a verification copy, the debug sample or a test run.
        guard !returning, CheckInCenter.shared.allowsSystemNotifications else { return }
        present()
    }

    func present() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        OnboardingChecklistStore.shared.setHidden(false)
        page = .appearance
        window = NSApp.keyWindow
        AgentDiscoveryStore.shared.scanIfStale(after: 60)
        NotificationPermission.shared.refresh()
        presented = true
    }

    func next() {
        if let following = Page(rawValue: page.rawValue + 1) { page = following } else { finish() }
    }

    func back() {
        if let previous = Page(rawValue: page.rawValue - 1) { page = previous }
    }

    func finish() {
        presented = false
    }

    /// The agents Octet can run a conversation with that this Mac has.
    static func installedAgents(_ agents: [DiscoveredAgent]) -> [AgentSession.Engine] {
        let found = Set(agents.filter { $0.executablePath != nil }.map(\.id))
        return AgentSession.Engine.offered.filter { found.contains($0.rawValue) }
    }

    /// The agent the Agent page shows as chosen: the default when it's
    /// installed, otherwise the first one that is.
    static func agentChoice(defaultAgent: String, installed: [AgentSession.Engine]) -> AgentSession.Engine? {
        let current = AgentSession.Engine(rawValue: defaultAgent) ?? .claude
        return installed.contains(current) ? current : installed.first
    }
}

struct FirstRunFlow: View {
    @ObservedObject var center: FirstRunCenter

    var body: some View {
        OctetModalShell(isPresented: center.presented, window: center.window, identity: center.presented,
                        overlayName: "first-run", onDismiss: { center.finish() }) {
            FirstRunCard(center: center)
        }
    }
}

private struct FirstRunCard: View {
    @ObservedObject var center: FirstRunCenter
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(FirstRunCenter.Page.allCases, id: \.self) { page in
                    Capsule()
                        .fill(page.rawValue <= center.page.rawValue ? Theme.accent : Theme.cardSelected)
                        .frame(width: page == center.page ? 18 : 6, height: 6)
                }
                Spacer()
                Text("\(center.page.rawValue + 1) of \(FirstRunCenter.Page.allCases.count)")
                    .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(center.page.rawValue + 1) of \(FirstRunCenter.Page.allCases.count)")
            Group {
                switch center.page {
                case .appearance: FirstRunAppearance(settings: settings)
                case .agent: FirstRunAgent(settings: settings)
                case .notifications: FirstRunNotifications()
                }
            }
            .frame(minHeight: 230, alignment: .top)
            .transition(motion.animates(.palette) ? .opacity : .identity)
            .id(center.page)
            HStack(spacing: Theme.Space.md) {
                OctetButton(title: "Skip Setup", kind: .ghost, compact: true) { center.finish() }
                    .help("Close this; Help › Getting Started opens it again")
                Spacer()
                if center.page != .appearance {
                    OctetButton(title: "Back", kind: .secondary) { center.back() }
                }
                OctetButton(title: center.page == .notifications ? "Done" : "Continue", kind: .primary) { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .octetModalCard(width: 520, padding: Theme.Space.xxl)
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.page)
    }

    /// Leaving a page counts as having made its choice.
    private func advance() {
        switch center.page {
        case .appearance: OnboardingChecklistStore.shared.set(.appearance, complete: true)
        case .agent:
            // The page only showed its pick; it becomes the default here,
            // from the list as it is now.
            let installed = FirstRunCenter.installedAgents(AgentDiscoveryStore.shared.agents)
            if let choice = FirstRunCenter.agentChoice(defaultAgent: settings.values.defaultAgent, installed: installed),
               choice.rawValue != settings.values.defaultAgent {
                settings.values.defaultAgent = choice.rawValue
            }
        case .notifications: OnboardingChecklistStore.shared.set(.notifications, complete: true)
        }
        center.next()
    }
}

private struct FirstRunHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Text.title2).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message).font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Appearance

private struct FirstRunAppearance: View {
    @ObservedObject var settings: SettingsStore
    @State private var ghostty: GhosttyFind?
    @State private var imported = false

    /// What a Ghostty config on this Mac offers: colours, font, or both.
    struct GhosttyFind {
        var theme: TerminalTheme?
        var family: String?
        var size: Double?
        var summary: String {
            [theme.map { "the \($0.name == "Terminal" ? "Ghostty" : $0.name) colours" },
             family.map { "\($0)" + (size.map { " at \(Int($0))pt" } ?? "") }]
                .compactMap { $0 }.joined(separator: " and ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            FirstRunHeading(title: "Welcome to Octet",
                            message: "Pick how it looks. Everything here is in Settings › Appearance later.")
            ColorSchemeTiles(settings: settings)
            if let ghostty, !ghostty.summary.isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    OctetIcon("terminal", size: 16).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(imported ? "Using your Ghostty setup" : "Use your Ghostty setup?")
                            .font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                        Text("Found \(ghostty.summary) in your Ghostty config.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.md)
                    OctetButton(title: imported ? "Imported" : "Import", icon: imported ? "check" : nil, compact: true) {
                        apply(ghostty)
                    }
                    .disabled(imported)
                }
                .padding(Theme.Space.lg)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.terminalBackground.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border, lineWidth: 1))
            }
        }
        .task {
            // Once per page: the file reads happen off the main thread, and
            // only the installed-font check (AppKit) comes back to it.
            guard ghostty == nil else { return }
            guard var find = await Task.detached(operation: { Self.readGhostty() }).value else { return }
            find.family = find.family.flatMap { name in CustomFonts.allFamilies.contains(name) ? name : nil }
            ghostty = find.theme == nil && find.family == nil && find.size == nil ? nil : find
        }
    }

    /// The Ghostty config's colours and font, as written; the font isn't
    /// checked against what's installed yet.
    nonisolated static func readGhostty(home: String = NSHomeDirectory()) -> GhosttyFind? {
        let paths = TerminalThemeImport.searchPaths(home: home).filter { $0.localizedCaseInsensitiveContains("ghostty") }
        guard let text = paths.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else { return nil }
        let font = GhosttyFontConfig.parse(text)
        return GhosttyFind(theme: TerminalThemeImport.importFromConfig(home: home), family: font.family, size: font.size)
    }

    private func apply(_ find: GhosttyFind) {
        var values = settings.values
        if let theme = find.theme {
            values.importedTheme = theme
            values.matchSystemAppearance = false
            values.themeName = theme.name
        }
        if let family = find.family { values.fontFamily = family }
        if let size = find.size { values.fontSize = min(max(size, 8), 32) }
        settings.values = values
        imported = true
    }
}

// MARK: - Agent

private struct FirstRunAgent: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var discovery = AgentDiscoveryStore.shared

    /// The agents Octet can run a conversation with that this Mac has.
    private var installed: [AgentSession.Engine] { FirstRunCenter.installedAgents(discovery.agents) }

    /// Shown as chosen, but only saved on Continue (or a click).
    private var choice: AgentSession.Engine? {
        FirstRunCenter.agentChoice(defaultAgent: settings.values.defaultAgent, installed: installed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            FirstRunHeading(title: "Your agent",
                            message: "New conversations start with this one. Any other is a menu away.")
            if discovery.scanning && installed.isEmpty {
                HStack(spacing: Theme.Space.md) {
                    LoadingLine(width: 20)
                    Text("Looking for agents on this Mac…").font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                }
            } else if installed.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("No agent found on this Mac yet. Install one in a terminal, then scan again:")
                        .font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                    installLine("Claude Code", "npm install -g @anthropic-ai/claude-code")
                    installLine("Codex", "npm install -g @openai/codex")
                    OctetButton(title: "Scan Again", icon: "arrow.clockwise", compact: true) { discovery.scan() }
                }
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(installed, id: \.self) { engine in
                        agentRow(engine)
                    }
                }
            }
        }
    }

    private func installLine(_ name: String, _ command: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(name).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary).frame(width: 90, alignment: .leading)
            OctetCopyText(text: command)
            Spacer(minLength: 0)
        }
    }

    private func agentRow(_ engine: AgentSession.Engine) -> some View {
        let chosen = choice == engine
        let found = discovery.agents.first { $0.id == engine.rawValue }
        return Button { settings.values.defaultAgent = engine.rawValue } label: {
            HStack(spacing: Theme.Space.md) {
                OctetIcon(chosen ? "checkmark.circle.fill" : "circle", size: 15)
                    .foregroundStyle(chosen ? Theme.accent : Theme.textTertiary)
                Text(found?.displayName ?? engine.displayName).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                if let version = found?.version {
                    Text(version).font(Theme.Text.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(chosen ? Theme.cardSelected : Theme.hover.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Notifications

private struct FirstRunNotifications: View {
    @ObservedObject private var permission = NotificationPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            FirstRunHeading(title: "Know when an agent needs you",
                            message: "While Octet is in front, a banner says an agent finished or has a question. Behind other apps, that takes a macOS notification.")
            HStack(spacing: Theme.Space.md) {
                switch permission.status {
                case .allowed:
                    OctetIcon("checkmark.circle.fill", size: 15).foregroundStyle(Theme.success)
                    Text("Notifications are allowed.").font(Theme.Text.body).foregroundStyle(Theme.textPrimary)
                case .denied:
                    Text("Notifications for Octet are off in System Settings.")
                        .font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                    OctetButton(title: "Open System Settings", icon: "arrow.up.right", compact: true) {
                        permission.openSystemSettings()
                    }
                case .unavailable:
                    Text("This copy of Octet can't post notifications.")
                        .font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                case .notAsked, .unknown:
                    OctetButton(title: "Allow Notifications", icon: "bell", kind: .secondary) { permission.request() }
                    Text("macOS asks next.").font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Text("Which notices you get, and their sounds, are in Settings › Notifications.")
                .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}
