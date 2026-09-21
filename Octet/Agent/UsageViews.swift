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
    @ObservedObject private var store = AccountStore.shared
    /// The agent whose card is up. Hovering a chip opens it.
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(["claude", "codex"], id: \.self) { agent in
                if let account = store.accounts[agent], account.kind == .subscription || account.kind == .apiKey {
                    chip(account)
                        .onHover { inside in
                            if inside { hovered = account.agent }
                            else if hovered == account.agent { hovered = nil }
                        }
                        .popover(isPresented: card(account.agent), arrowEdge: .bottom) {
                            AccountCard(account: account)
                        }
                }
            }
        }
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
            } else {
                Text(account.plan ?? "Plan").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
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

    private var brand: AgentBrand? { AgentBrand.forAgent(account.agent) }
    private var name: String { brand?.displayName ?? account.agent.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if account.kind == .apiKey {
                note("\(name) is signed in with an API key, so there is no allowance to spend. Conversations show what each one cost.")
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
            Text(account.kind == .apiKey ? (account.plan ?? "API key") : (account.plan ?? "Subscription"))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Theme.card)
                .clipShape(Capsule())
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
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(UsageMeter.color(used))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, used))))
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
