import AppKit
import SwiftUI

/// Allowance windows as small rings: "5h ◔ 6%  7d ◑ 55%". Amber from 70%,
/// red from 90%, and dimmed once the reading is an hour old. It sits in a
/// title-bar chip, whose hover card carries the detail, so it carries no
/// tooltip of its own.
struct UsageMeter: View {
    let windows: [UsageWindow]
    var updatedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(windows, id: \.name) { window in
                HStack(spacing: 5) {
                    Text(window.name)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                    UsageRing(used: window.used, size: 12)
                    Text("\(Int((window.used * 100).rounded()))%")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(window.used >= 0.9 ? Theme.danger : Theme.textSecondary)
                }
            }
        }
        .opacity(isStale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var isStale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 3600 } ?? false }

    private var label: String {
        let used = windows.map { "\($0.name) \(Int(($0.used * 100).rounded())) percent" }.joined(separator: ", ")
        return "Allowance used: " + used
    }

    static func color(_ used: Double) -> Color {
        if used >= 0.9 { return Theme.danger }
        if used >= 0.7 { return Color(hex: TerminalTheme.named(SettingsStore.shared.values.themeName).ansi[3]) }
        return Theme.accent
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One chip per agent CLI in the title bar: its mark and plan, then its
/// allowance for subscriptions or "API" for pay-as-you-go keys.
struct AccountChips: View {
    let runningAgents: Set<String>
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    /// The agent whose card is up. Hovering a chip opens it.
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(availableAgents) { agent in
                let account = store.accounts[agent.id] ?? AgentAccount(agent: agent.id, kind: .unknown)
                chip(account)
                    .onHover { inside in
                        if inside { hovered = account.agent }
                        else if hovered == account.agent { hovered = nil }
                    }
                    .popover(isPresented: card(account.agent), arrowEdge: .bottom) {
                        AccountCard(account: account, isRunning: runningAgents.contains(account.agent))
                    }
            }
        }
    }

    /// Usage support varies by CLI, but the title bar should still represent
    /// every agent that can actually be started on this machine.
    private var availableAgents: [DiscoveredAgent] {
        discovery.agents.filter { $0.executablePath != nil }
    }

    /// Bound to the card, so dismissing it any other way (Esc, a click
    /// elsewhere) also clears the hover that opened it.
    private func card(_ agent: String) -> Binding<Bool> {
        Binding(get: { hovered == agent }, set: { shown in if !shown, hovered == agent { hovered = nil } })
    }

    private func chip(_ account: AgentAccount) -> some View {
        let brand = AgentBrand.forAgent(account.agent)
        return HStack(spacing: 6) {
            if let brand { AgentLogo(brand: brand, size: 11) }
            if account.kind == .apiKey {
                Text("API").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            } else if let tightest = account.tightest {
                // Only the window closest to its limit, which is the one worth
                // knowing at a glance. The hover card has the rest.
                UsageMeter(windows: [tightest], updatedAt: account.updatedAt)
            } else if account.kind == .signedOut {
                Text("Signed out").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            } else {
                Text(account.plan ?? "Ready").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(brand?.displayName ?? account.agent) \(account.plan ?? (account.kind == .apiKey ? "API key" : ""))")
    }
}

/// What a title-bar chip shows when hovered: every allowance window with how
/// much of it is gone and when it comes back, or why there is nothing to show.
struct AccountCard: View {
    let account: AgentAccount
    let isRunning: Bool
    @ObservedObject private var store = AccountStore.shared

    private var brand: AgentBrand? { AgentBrand.forAgent(account.agent) }
    private var name: String { brand?.displayName ?? account.agent.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if account.kind == .apiKey {
                note("\(name) is signed in with an API key, so there is no allowance to spend. Conversations show what each one cost.")
            } else if account.kind == .signedOut {
                note("\(name) is installed, but it is not signed in. Sign in with its CLI to make account usage available.")
            } else if account.kind == .unknown {
                note("\(name) is installed and available. Its CLI does not currently expose account-level usage to Octet.")
            } else if account.live.isEmpty {
                note(pending)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(account.live, id: \.name) { window($0) }
                }
                if let updatedAt = account.updatedAt {
                    Text("As of \(UsageMeter.relative(updatedAt))")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if account.kind == .subscription {
                UsageRateGraph(samples: store.history[account.agent] ?? [],
                               window: graphWindow,
                               updatedAt: account.updatedAt)
            }
        }
        .padding(12)
        .frame(width: 256, alignment: .leading)
        .background(Theme.chrome)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let brand { AgentLogo(brand: brand, size: 13) }
            Text(name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(accountLabel)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Theme.card)
                .clipShape(Capsule())
        }
    }

    private var accountLabel: String {
        switch account.kind {
        case .apiKey: return account.plan ?? "API key"
        case .subscription: return account.plan ?? "Subscription"
        case .signedOut: return "Signed out"
        case .unknown: return "Available"
        }
    }

    /// The chart uses the broadest reported allowance (normally the weekly
    /// one); the compact chip still uses the tightest limit.
    private var graphWindow: UsageWindow? {
        account.live.max {
            (UsageRate.duration(named: $0.name) ?? 0) < (UsageRate.duration(named: $1.name) ?? 0)
        }
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func window(_ window: UsageWindow) -> some View {
        let percent = Int((window.used * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(window.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("\(percent)% used")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(UsageMeter.color(window.used))
            }
            bar(window.used)
            if let reset = window.resetsAt {
                Text("\(100 - percent)% left · resets \(Self.reset(reset)), \(UsageMeter.relative(reset))")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("\(100 - percent)% left").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ used: Double) -> some View {
        GeometryReader { proxy in
            let filledWidth = max(3, proxy.size.width * min(1, max(0, used)))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(UsageMeter.color(used))
                    .frame(width: filledWidth)
                    .overlay(alignment: .leading) {
                        if isRunning {
                            UsageBarBeam()
                                .frame(width: filledWidth)
                                .clipShape(Capsule())
                        }
                    }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    /// Today's resets read as a time; later ones carry their weekday.
    private static func reset(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
                        colors: [.clear, .white.opacity(0.75), .clear],
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

/// Consumption speed for the allowance currently closest to its limit.
/// Samples persist across launches, so the graph becomes useful without the
/// popover having to remain open.
private struct UsageRateGraph: View {
    let samples: [UsageHistorySample]
    let window: UsageWindow?
    let updatedAt: Date?

    private struct Point {
        let at: Date
        let used: Double
    }

    private var bounds: (start: Date, end: Date)? {
        guard let window, let end = window.resetsAt,
              let duration = UsageRate.duration(named: window.name) else { return nil }
        return (end.addingTimeInterval(-duration), end)
    }

    private var observed: [Point] {
        guard let window, let bounds else { return [] }
        var values = samples.compactMap { sample -> Point? in
            guard sample.at >= bounds.start, sample.at <= bounds.end,
                  let reading = sample.windows.first(where: { $0.name == window.name }) else { return nil }
            return Point(at: sample.at, used: reading.used)
        }
        let latestAt = updatedAt ?? Date()
        if latestAt >= bounds.start, latestAt <= bounds.end,
           values.last.map({ abs($0.at.timeIntervalSince(latestAt)) > 1 || $0.used != window.used }) ?? true {
            values.append(Point(at: latestAt, used: window.used))
        }
        values.sort { $0.at < $1.at }
        if values.first?.at != bounds.start { values.insert(Point(at: bounds.start, used: 0), at: 0) }
        return values
    }

    private var projection: Point? {
        guard let window, let bounds, let latest = observed.last,
              let rate = UsageRate.averagePercentPerHour(window: window, at: latest.at), rate > 0 else { return nil }
        let reaches = UsageRate.projectedLimitDate(window: window, at: latest.at)
        let end = min(reaches ?? bounds.end, bounds.end)
        let added = rate / 100 * end.timeIntervalSince(latest.at) / 3600
        return Point(at: end, used: min(1, latest.used + added))
    }

    private var projectionLabel: String? {
        guard let window, let bounds, let latest = observed.last,
              let reaches = UsageRate.projectedLimitDate(window: window, at: latest.at) else { return nil }
        if reaches <= bounds.end {
            return "Limit \(reaches.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return "No limit before reset"
    }

    private var projectedLimit: Date? {
        guard let window, let bounds, let latest = observed.last,
              let reaches = UsageRate.projectedLimitDate(window: window, at: latest.at),
              reaches >= bounds.start, reaches <= bounds.end else { return nil }
        return reaches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Text((window?.name == "7d" ? "WEEKLY PACE" : "USAGE PACE"))
                    .font(Theme.headerFont)
                    .kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let projectionLabel {
                    Text(projectionLabel)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            chart
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projectionLabel ?? "Usage pace history is being collected")
    }

    private var chart: some View {
        VStack(spacing: 3) {
            Canvas { context, size in
                let baseline = Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5))
                context.fill(baseline, with: .color(Theme.border))
                guard let bounds, !observed.isEmpty else { return }
                let first = bounds.start.timeIntervalSinceReferenceDate
                let span = max(1, bounds.end.timeIntervalSinceReferenceDate - first)
                func point(_ value: Point) -> CGPoint {
                    CGPoint(x: (value.at.timeIntervalSinceReferenceDate - first) / span * size.width,
                            y: size.height - min(1, value.used) * (size.height - 4) - 2)
                }
                var line = Path()
                line.move(to: point(observed[0]))
                for value in observed.dropFirst() { line.addLine(to: point(value)) }
                context.stroke(line, with: .color(Theme.accent),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                let latest = point(observed.last!)
                context.fill(Path(ellipseIn: CGRect(x: latest.x - 2, y: latest.y - 2, width: 4, height: 4)),
                             with: .color(Theme.accent))
                if let projection {
                    var forecast = Path()
                    forecast.move(to: latest)
                    forecast.addLine(to: point(projection))
                    context.stroke(forecast, with: .color(Theme.textTertiary),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let projectedLimit {
                    let x = (projectedLimit.timeIntervalSinceReferenceDate - first) / span * size.width
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(marker, with: .color(Theme.textSecondary.opacity(0.75)),
                                   style: StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
                }
            }
            .frame(height: 48)
            if let bounds {
                HStack {
                    Text(bounds.start.formatted(.dateTime.weekday(.abbreviated)))
                    Spacer()
                    Text("Reset \(bounds.end.formatted(.dateTime.month(.defaultDigits).day(.twoDigits)))")
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(6)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay {
            if observed.isEmpty {
                Text("Collecting history")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

}

/// A ring that fills clockwise from the top with the fraction used.
struct UsageRing: View {
    let used: Double
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, used)))
                .stroke(UsageMeter.color(used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
