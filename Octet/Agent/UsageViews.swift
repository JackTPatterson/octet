import AppKit
import SwiftUI

/// Allowance windows as small rings with what's gone: "◔ 38%". Amber from
/// 70%, red from 90%, provider-tinted below that, and dimmed once the
/// reading is an hour old. It sits in the title-bar chip group, whose card
/// carries the detail, so it carries no tooltip of its own.
struct UsageMeter: View {
    let windows: [UsageWindow]
    var updatedAt: Date?
    var agent = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(windows, id: \.name) { window in
                HStack(spacing: 4) {
                    UsageRing(used: window.used, size: 11, lineWidth: 2, tint: Self.tint(window.used, agent: agent))
                    Text("\(window.percentUsed)%")
                        .font(Theme.captionFont.weight(.medium).monospacedDigit())
                        .foregroundStyle(window.used >= 0.7 ? Self.color(window.used) : Theme.textSecondary)
                }
            }
        }
        .opacity(Self.isStale(updatedAt) ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// An hour old, or of unknown age (Claude Code's cache, undated).
    static func isStale(_ updatedAt: Date?) -> Bool {
        updatedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true
    }

    private var label: String {
        "Allowance used: " + windows.map { "\($0.title) \($0.percentUsed) percent" }.joined(separator: ", ")
    }

    /// The level colour: red from 90%, the theme's amber from 70%, the
    /// accent below.
    static func color(_ used: Double) -> Color {
        if used >= 0.9 { return Theme.danger }
        if used >= 0.7 { return amber }
        return Theme.accent
    }

    /// A bar's or ring's fill: the provider's own colour until the window
    /// gets tight, then the same amber and red as everywhere else.
    static func tint(_ used: Double, agent: String) -> Color {
        used >= 0.7 || agent.isEmpty ? color(used) : UsagePalette.color(agent)
    }

    static var amber: Color { Color(hex: TerminalTheme.named(SettingsStore.shared.values.themeName).ansi[3]) }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Every agent CLI's allowance in one quiet title-bar group, after T3 Code's
/// usage limits: each agent's mark with a ring and percentage for its
/// tightest window, "API" for pay-as-you-go keys. Hovering opens a card with
/// every window; clicking keeps it open.
struct AccountChips: View {
    let runningAgents: Set<String>
    /// Opens the in-window Usage page.
    var openUsage: () -> Void = {}
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var chipHovered = false
    @State private var cardHovered = false
    /// Clicked open, so leaving the chip doesn't close the card.
    @State private var pinned = false
    @State private var shown = false

    var body: some View {
        let accounts = availableAccounts
        if !accounts.isEmpty {
            Button {
                pinned.toggle()
                shown = pinned || chipHovered
                if pinned { refreshIfReadable(accounts) }
            } label: {
                HStack(spacing: 10) {
                    ForEach(accounts, id: \.agent) { segment($0) }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(chipHovered || shown ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(OctetPressStyle())
            .onHover { inside in
                chipHovered = inside
                if inside { refreshIfReadable(accounts) }
                settle(after: inside ? 0.12 : 0.3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent usage")
            .accessibilityValue(accounts.map(Self.summary).joined(separator: "; "))
            .accessibilityHint("Shows each allowance window and when it resets")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: cardBinding, arrowEdge: .bottom) {
                AccountCard(accounts: accounts, runningAgents: runningAgents) {
                    pinned = false
                    shown = false
                    openUsage()
                }
                .onHover { inside in
                    cardHovered = inside
                    if !inside { settle(after: 0.3) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.debugOpenCard)) { _ in
                pinned = true
                shown = true
            }
        }
    }

    /// Agents installed here with something to say: an allowance, a plan,
    /// an API key or being signed out. One that would only read "Ready"
    /// (Pi and OpenCode, whose usage Octet can't read) is left out.
    private var availableAccounts: [AgentAccount] {
        discovery.agents.compactMap { agent in
            guard agent.executablePath != nil else { return nil }
            let account = store.accounts[agent.id] ?? AgentAccount(agent: agent.id, kind: .unknown)
            let worthShowing = account.kind == .apiKey || account.kind == .signedOut
                || account.tightest != nil || account.plan != nil
            return worthShowing ? account : nil
        }
    }

    /// Opens or closes the card once the pointer has settled, so crossing
    /// from the chip into the card doesn't close it on the way.
    private func settle(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let wanted = chipHovered || cardHovered || pinned
            if wanted != shown { shown = wanted }
        }
    }

    /// Bound to the card, so dismissing it any other way (Esc, a click
    /// elsewhere) also forgets the click or hover that opened it.
    private var cardBinding: Binding<Bool> {
        Binding(get: { shown }, set: { show in
            if !show {
                shown = false
                pinned = false
                cardHovered = false
            }
        })
    }

    /// Read afresh while someone is looking.
    private func refreshIfReadable(_ accounts: [AgentAccount]) {
        if accounts.contains(where: { ["claude", "codex"].contains($0.agent) }) { store.refreshSoon() }
    }

    private func segment(_ account: AgentAccount) -> some View {
        HStack(spacing: 5) {
            if let brand = AgentBrand.forAgent(account.agent) { AgentLogo(brand: brand, size: 12) }
            if account.kind == .apiKey {
                Text("API").font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary)
            } else if let tightest = account.tightest {
                // Only the window closest to its limit, the one worth knowing
                // at a glance; the card has the rest.
                UsageMeter(windows: [tightest], updatedAt: account.updatedAt, agent: account.agent)
            } else if account.kind == .signedOut {
                Text("Signed out").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            } else {
                Text(account.plan ?? "Ready").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// "Claude, 5-hour limit 38 percent used", for the group's value.
    private static func summary(_ account: AgentAccount) -> String {
        let name = UsagePalette.name(account.agent)
        switch account.kind {
        case .apiKey: return "\(name), API key"
        case .signedOut: return "\(name), signed out"
        default:
            guard let tightest = account.tightest else { return "\(name), \(account.plan ?? "available")" }
            return "\(name), \(tightest.title) \(tightest.percentUsed) percent used"
        }
    }

    /// Verification hook: RootView posts this to open the card at launch.
    static let debugOpenCard = Notification.Name("octet.debug.openAccountCard")
}

/// The title-bar group's card: a section per agent with its plan and how
/// fresh the reading is, each allowance window as a labelled bar with its
/// pace and reset, and a way into the Usage page.
struct AccountCard: View {
    let accounts: [AgentAccount]
    let runningAgents: Set<String>
    let openUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.agent) { index, account in
                if index > 0 { hairline }
                AccountSection(account: account, isRunning: runningAgents.contains(account.agent))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            hairline
            footer
        }
        .frame(width: 300, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Theme.chrome.opacity(0.86))
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Spend by conversation")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            OctetButton(title: "Open Usage", icon: "arrow.up.right", kind: .secondary, compact: true, action: openUsage)
                .help("Open the Usage page in this window")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card.opacity(0.35))
    }
}

/// One agent in the card: its header, then its windows or why there are none.
private struct AccountSection: View {
    let account: AgentAccount
    let isRunning: Bool
    @ObservedObject private var store = AccountStore.shared

    private var brand: AgentBrand? { AgentBrand.forAgent(account.agent) }
    private var name: String { brand?.displayName ?? account.agent.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if account.kind == .apiKey {
                note("Signed in with an API key, so there is no allowance to spend. Conversations show what each one cost.")
            } else if account.kind == .signedOut {
                note("Installed but not signed in. Sign in with its CLI to see its allowance.")
            } else if account.kind == .unknown {
                note("Installed and available. Its CLI doesn't expose account usage to Octet.")
            } else if account.live.isEmpty {
                note(pending)
            } else {
                let now = Date()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(account.live, id: \.name) { window in
                        UsageWindowRow(window: window, agent: account.agent, isRunning: isRunning, now: now)
                    }
                }
                .opacity(UsageMeter.isStale(account.updatedAt) ? 0.6 : 1)
            }
            if account.agent == "claude", account.kind == .subscription { liveSource }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            if let brand { AgentLogo(brand: brand, size: 14) }
            Text(name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(planLabel)
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
            Spacer(minLength: 8)
            if let updated {
                Text(updated)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var planLabel: String {
        switch account.kind {
        case .apiKey: return account.plan ?? "API key"
        case .subscription: return account.plan ?? "Subscription"
        case .signedOut: return "Signed out"
        case .unknown: return "Available"
        }
    }

    /// "2 min. ago", or "Cached" for Claude Code's undated cache.
    private var updated: String? {
        guard account.kind == .subscription, !account.live.isEmpty else { return nil }
        guard let updatedAt = account.updatedAt else { return "Cached" }
        return UsageMeter.relative(min(updatedAt, Date()))
    }

    /// Both agents report an allowance only as they work, so there are two
    /// ways to have nothing to show: nothing reported yet, or a last report
    /// whose window has since reset.
    private var pending: String {
        if let expiredAt = account.expiredAt {
            return "The last allowance \(name) reported was for a window that reset \(UsageMeter.relative(expiredAt)). The one running now shows here after its next turn."
        }
        guard account.agent == "claude" else {
            return "No allowance reported yet. It shows here once \(name) reports one, which it does as it works."
        }
        return SettingsStore.shared.values.readClaudeAccountUsage
            ? "No allowance to show yet. Octet asks your Claude account, falls back to the usage Claude Code last cached, and takes live numbers from any conversation you run."
            : "No allowance to show yet. Octet reads the usage Claude Code last cached and live numbers from conversations you run here. For live numbers any time, turn on \u{201C}Read live usage from your Claude account\u{201D} in Settings."
    }

    /// Where Claude's numbers come from when they may be behind, and the
    /// one click that makes them live.
    @ViewBuilder
    private var liveSource: some View {
        let asking = SettingsStore.shared.values.readClaudeAccountUsage
        if !asking, account.updatedAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            VStack(alignment: .leading, spacing: 8) {
                note("This is what Claude Code last cached, which only changes when Claude Code checks. Sessions in terminal tabs don't report their usage to Octet.")
                OctetButton(title: "Read Live Usage", icon: "arrow.clockwise", kind: .secondary, compact: true) {
                    store.enableAccountUsage()
                }
            }
        } else if asking, let fallback = store.claudeFallback {
            VStack(alignment: .leading, spacing: 8) {
                switch fallback {
                case .needsKeychain:
                    note("macOS needs to ask again before Octet can read Claude Code's sign-in, so this may be behind.")
                    OctetButton(title: "Allow Again", icon: "arrow.clockwise", kind: .secondary, compact: true) {
                        store.accountUsageSettingChanged()
                    }
                case .problem(let reason):
                    note("\(reason) Showing the last numbers Octet has.")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One allowance window: its name and share used, a slim bar in the
/// provider's colour with a tick where an even pace would be, then what's
/// left, the pace and when it resets.
struct UsageWindowRow: View {
    let window: UsageWindow
    let agent: String
    var isRunning = false
    var now = Date()

    var body: some View {
        let pace = window.pace(at: now)
        let resets = window.resetsIn(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.title).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                // A mark as well as the colour, so the level never rests on
                // colour alone.
                if window.used >= 0.7 {
                    OctetIcon("exclamationmark.triangle.fill", size: 10)
                        .foregroundStyle(UsageMeter.color(window.used))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text("\(window.percentUsed)%")
                    .font(Theme.uiFontMedium.monospacedDigit())
                    .foregroundStyle(window.used >= 0.7 ? UsageMeter.color(window.used) : Theme.textPrimary)
                Text("used").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            UsageBar(used: window.used, tint: UsageMeter.tint(window.used, agent: agent),
                     expected: window.elapsedShare(at: now), isRunning: isRunning)
            HStack(spacing: 5) {
                if let pace {
                    OctetIcon("usage.pace.\(pace.rawValue)", size: 11)
                        .foregroundStyle(pace == .ahead ? Theme.textSecondary : Theme.textTertiary)
                        .help(pace.explanation)
                }
                Text("\(window.percentLeft)% left" + (pace.map { " · \($0.phrase)" } ?? ""))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let resets {
                    Text(resets)
                        .lineLimit(1)
                        .help(window.resetsAt.map { "Resets \(Self.reset($0))" } ?? "")
                }
            }
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            if pace == .ahead, let limit = window.limitBeforeReset(at: now) {
                Text("At this pace it runs out \(Self.reset(limit))")
                    .font(Theme.captionFont)
                    .foregroundStyle(UsageMeter.color(max(0.7, window.used)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(pace: pace, resets: resets))
    }

    private func accessibilityText(pace: UsagePace?, resets: String?) -> String {
        var parts = ["\(window.title): \(window.percentUsed) percent used", "\(window.percentLeft) percent left"]
        if let pace { parts.append(pace.phrase) }
        if let resets { parts.append(resets) }
        return parts.joined(separator: ", ")
    }

    /// Today's times read as a time; later ones carry their weekday.
    static func reset(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A slim allowance bar after T3 Code's: a quiet track, the used share
/// filled in `tint`, and an optional hairline tick where an even pace would
/// be by now. A light travels through it while the agent works.
struct UsageBar: View {
    let used: Double
    let tint: Color
    var expected: Double?
    var isRunning = false
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, used))
            let filled = fraction > 0 ? max(height, proxy.size.width * fraction) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border.opacity(0.7))
                Capsule()
                    .fill(tint)
                    .frame(width: filled)
                    .overlay(alignment: .leading) {
                        if isRunning, filled > 0 {
                            UsageBarBeam().frame(width: filled).clipShape(Capsule())
                        }
                    }
                if let expected, expected > 0, expected < 1 {
                    Rectangle()
                        .fill(Theme.textSecondary.opacity(0.8))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: proxy.size.width * expected - 0.75)
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A narrow highlight that travels through a live allowance bar. It is shown
/// only while that agent is actively working; Reduce Motion keeps the bar
/// static instead of substituting another animation.
private struct UsageBarBeam: View {
    var body: some View {
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let beam = max(10, width * 0.28)
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.35) / 1.35
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.6), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: beam)
                    .offset(x: -beam + (width + beam) * phase)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A ring that fills clockwise from the top with the fraction used.
struct UsageRing: View {
    let used: Double
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.5
    var tint: Color?

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, used)))
                .stroke(tint ?? UsageMeter.color(used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
