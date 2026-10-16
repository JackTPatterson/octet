import Charts
import SwiftUI

/// Where usage went, after T3 Code's Usage page: what every Claude Code,
/// Codex and OpenCode session on this Mac spent over a period, by provider,
/// day, kind of token and model; or, in Limits, how much of each account's
/// allowance is left. A page over the content area, like the diff review,
/// opened from the account chips' "Where did it go?" and the palette.
struct UsagePage: View {
    let close: () -> Void
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var history = UsageHistoryStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var center = AgentCenter.shared
    @State private var mode: Mode = .cost
    @State private var period: UsagePeriod = .month
    @State private var provider: String?
    @State private var breakdown: Breakdown = .model
    @State private var account: String?
    @StateObject private var dropdowns = OctetDropdownState()
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var focused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case cost, tokens, limits
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var measure: UsageMeasure { self == .tokens ? .tokens : .cost }
    }

    enum Breakdown: String, CaseIterable, Identifiable {
        case model, day, conversation
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if mode == .limits {
                UsageLimitsView(accounts: accounts.accounts, provider: provider)
            } else if history.records.isEmpty {
                placeholder
            } else {
                report
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .octetDropdownHost(dropdowns)
        // A page over the terminal, not a sheet: it takes keyboard focus so
        // Esc reaches it rather than the shell underneath.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand {
            if dropdowns.openId != nil { dropdowns.openId = nil } else { close() }
        }
        .onAppear {
            focused = true
            history.refresh(profiles: settings.values.accountProfiles)
            #if DEBUG
            applyDebugOptions()
            #endif
        }
    }

    #if DEBUG
    /// Verification hook: OCTET_OPEN_WINDOW=usage:<mode>:<period>:<breakdown>.
    private func applyDebugOptions() {
        guard let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("usage") else { return }
        for part in open.split(separator: ":").dropFirst().map(String.init) {
            if let value = Mode(rawValue: part) { mode = value }
            if let value = UsagePeriod(rawValue: part) { period = value }
            if let value = Breakdown(rawValue: part) { breakdown = value }
            if UsagePalette.order(part) < 10 { provider = part }
            if part == "menu" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dropdowns.openId = "usage.provider" } }
            // Presses Esc through the window's normal key dispatch, to check
            // the page, not the terminal under it, takes it.
            if part == "esc" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return }
                    window.sendEvent(event)
                }
            }
        }
    }
    #endif

    // MARK: Header

    private var header: some View {
        PageHeader(crumbs: crumbs, dropdowns: dropdowns, close: close) {
            if history.scanning {
                ProgressView().controlSize(.small).help("Reading the agents' logs")
            }
            OctetSegmented(selection: $mode, items: Mode.allCases.map { ($0, $0.title) })
            if mode != .limits {
                OctetSegmented(selection: $period, items: UsagePeriod.allCases.map { ($0, $0.title) })
            }
            OctetIconButton(icon: "arrow.clockwise", help: "Refresh") {
                history.refresh(force: true, profiles: settings.values.accountProfiles)
                accounts.refresh(force: true)
            }
            .disabled(history.scanning)
        }
    }

    /// "Usage / All providers", with an account crumb between them once a
    /// second Claude or Codex account is set up (Settings › Accounts).
    private var crumbs: [Breadcrumb] {
        var crumbs: [Breadcrumb] = [.title("Usage")]
        let profiles = settings.values.accountProfiles
        if !profiles.isEmpty, mode != .limits {
            var options = [OctetDropdownOption(id: Self.all, title: "All accounts"),
                           OctetDropdownOption(id: Self.defaultAccount, title: "Default accounts")]
            options += profiles.map {
                OctetDropdownOption(id: $0.id, title: $0.name, detail: UsagePalette.name($0.agent))
            }
            let label = account.map { id in id == Self.defaultAccount ? "Default accounts"
                : profiles.first { $0.id == id }?.name ?? "All accounts" } ?? "All accounts"
            crumbs.append(.picker(spec: OctetDropdownSpec(id: "usage.account", options: options, selected: account ?? Self.all) { id in
                account = id == Self.all ? nil : id
            }, label: label))
        }
        let options = [OctetDropdownOption(id: Self.all, title: "All providers")]
            + providers.map { OctetDropdownOption(id: $0, title: UsagePalette.name($0)) }
        let mark = provider.flatMap(AgentBrand.forAgent).map { AnyView(AgentLogo(brand: $0, size: 13)) }
        crumbs.append(.picker(spec: OctetDropdownSpec(id: "usage.provider", options: options, selected: provider ?? Self.all) { id in
            provider = id == Self.all ? nil : id
        }, label: provider.map(UsagePalette.name) ?? "All providers", mark: mark))
        return crumbs
    }

    private static let all = "all"
    /// The agents' own config folders, as against a profile's.
    private static let defaultAccount = "default"

    /// Every provider Octet knows, Claude first as T3 orders them, plus any
    /// other with something recorded.
    private var providers: [String] {
        let present = Set(history.records.map(\.provider)).union(["claude", "codex", "opencode"])
        return present.sorted { UsagePalette.order($0) < UsagePalette.order($1) }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if history.scanning {
                ProgressView().controlSize(.small)
                Text("Reading Claude Code, Codex and OpenCode logs…")
            } else {
                OctetIcon("clock", size: 22)
                Text("No usage recorded in the last 90 days.")
            }
        }
        .font(Theme.uiFont)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Report

    private var report: some View {
        let now = Date()
        let measure = mode.measure
        let records = UsageSummary.filter(history.records, provider: provider, account: account.map { $0 == Self.defaultAccount ? "" : $0 },
                                          since: period.start(now: now), until: now)
        let totals = UsageSummary.totals(records)
        return ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .top, spacing: 40) {
                    summary(records, totals: totals, measure: measure)
                        .frame(width: 330, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle((period.hourly ? "Hourly " : "Daily ") + (measure == .cost ? "cost" : "tokens"))
                        UsageAreaChart(points: UsageSummary.series(records, period: period, measure: measure, now: now),
                                       providers: providers.filter { id in records.contains { $0.provider == id } },
                                       measure: measure, hourly: period.hourly)
                            .frame(height: 250)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                totalsRow(totals)
                byType(records, totals: totals, measure: measure)
                breakdownTable(records, measure: measure)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .scrollIndicators(.automatic)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }

    private func summary(_ records: [UsageRecord], totals: UsageSummary.Totals, measure: UsageMeasure) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(measure == .cost ? UsageFormat.money(totals.cost) : UsageFormat.tokens(totals.tokens.processed))
                    .font(Theme.interfaceFont(40, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 5) {
                    Text(Recap.count(totals.sessions, "session") + (measure == .cost ? " · API estimate" : " · processed tokens"))
                    if measure == .cost {
                        OctetIcon("info.circle.fill", size: 11)
                            .help("Costs are estimated at each model's API list price from the tokens in the agents' logs (OpenCode reports its own). On a subscription nothing is billed per token: read it as each session's weight, not money spent.")
                    }
                }
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(UsageSummary.providers(records, measure: measure)) { row in
                    providerRow(row, measure: measure)
                }
            }
        }
    }

    private func providerRow(_ row: UsageSummary.ProviderRow, measure: UsageMeasure) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(UsagePalette.color(row.provider)).frame(width: 7, height: 7)
                if let brand = AgentBrand.forAgent(row.provider) { AgentLogo(brand: brand, size: 13) }
                Text(UsagePalette.name(row.provider)).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Text(Recap.count(row.sessions, "session")).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Text(measure == .cost ? UsageFormat.money(row.cost) : UsageFormat.tokens(row.tokens))
                    .font(Theme.uiFontMedium.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            Text(measure == .cost
                 ? "\(UsageFormat.percent(row.share)) of cost · \(UsageFormat.tokens(row.tokens)) tokens"
                 : "\(UsageFormat.percent(row.share)) of tokens · \(UsageFormat.money(row.cost))")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 34)
        }
        .accessibilityElement(children: .combine)
    }

    private func totalsRow(_ totals: UsageSummary.Totals) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Totals")
            HStack(alignment: .top, spacing: 0) {
                stat("Processed tokens", UsageFormat.tokens(totals.tokens.processed),
                     help: "Everything the models read and wrote")
                stat("Cached input", UsageFormat.tokens(totals.tokens.cacheRead),
                     help: "Input read back from the prompt cache")
                stat("Uncached input", UsageFormat.tokens(totals.tokens.uncachedInput),
                     help: "Fresh input, including what was written to the cache")
                stat("Output", UsageFormat.tokens(totals.tokens.output), help: "Tokens the models wrote, reasoning included")
                stat("Cache savings", UsageFormat.money(totals.cacheSavings),
                     help: "What the cached input would have cost at the uncached input price, less what it did cost")
            }
        }
    }

    private func stat(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.interfaceFont(22, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    // MARK: By type

    private struct TypeSlice: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    private func slices(_ records: [UsageRecord], totals: UsageSummary.Totals, measure: UsageMeasure) -> [TypeSlice] {
        if measure == .cost {
            let cost = UsageSummary.costByType(records)
            return [TypeSlice(id: "Input", value: cost.input, color: UsagePalette.type(0)),
                    TypeSlice(id: "Cache read", value: cost.cacheRead, color: UsagePalette.type(1)),
                    TypeSlice(id: "Cache write", value: cost.cacheWrite, color: UsagePalette.type(2)),
                    TypeSlice(id: "Output", value: cost.output, color: UsagePalette.type(3)),
                    TypeSlice(id: "Other", value: cost.other, color: UsagePalette.type(4))]
        }
        let tokens = totals.tokens
        return [TypeSlice(id: "Input", value: Double(tokens.input), color: UsagePalette.type(0)),
                TypeSlice(id: "Cache read", value: Double(tokens.cacheRead), color: UsagePalette.type(1)),
                TypeSlice(id: "Cache write", value: Double(tokens.cacheWrite), color: UsagePalette.type(2)),
                TypeSlice(id: "Output", value: Double(tokens.output), color: UsagePalette.type(3))]
    }

    private func byType(_ records: [UsageRecord], totals: UsageSummary.Totals, measure: UsageMeasure) -> some View {
        let all = slices(records, totals: totals, measure: measure)
        let whole = all.reduce(0) { $0 + $1.value }
        let shown = all.filter { whole > 0 && $0.value / whole >= 0.002 }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(measure == .cost ? "Cost by type" : "Tokens by type")
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, shown.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shown) { slice in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(slice.color)
                            .frame(width: max(2, (proxy.size.width - gaps) * slice.value / max(whole, .leastNonzeroMagnitude)))
                            .help("\(slice.id): \(UsageFormat.value(slice.value, measure)) (\(UsageFormat.percent(slice.value / whole)))")
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 22) {
                ForEach(all) { slice in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(slice.color).frame(width: 9, height: 9)
                        Text(slice.id).foregroundStyle(Theme.textSecondary)
                        Text(UsageFormat.value(slice.value, measure)).foregroundStyle(Theme.textPrimary)
                        Text(whole > 0 ? UsageFormat.percent(slice.value / whole) : "–").foregroundStyle(Theme.textTertiary)
                    }
                    .font(Theme.uiFont.monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Breakdown

    private func breakdownTable(_ records: [UsageRecord], measure: UsageMeasure) -> some View {
        let rows: [UsageSummary.BreakdownRow] = switch breakdown {
        case .model: UsageSummary.byModel(records, measure: measure)
        case .day: UsageSummary.byDay(records, measure: measure)
        case .conversation: Array(UsageSummary.bySession(records, measure: measure).prefix(100))
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Breakdown")
                Spacer()
                OctetSegmented(selection: $breakdown, items: Breakdown.allCases.map { ($0, $0.title) })
            }
            VStack(spacing: 0) {
                tableRow(index: "#", title: Text(breakdown.title), cost: "Cost", share: "Share", tokens: "Tokens", header: true)
                    .padding(.vertical, 6)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    breakdownRow(index: index + 1, row: row)
                }
            }
        }
    }

    /// The underline's length is the row's share of the whole period.
    private func breakdownRow(index: Int, row: UsageSummary.BreakdownRow) -> some View {
        let session = breakdown == .conversation ? liveSession(row) : nil
        let title = session?.title ?? row.title
        return tableRow(
            index: String(index),
            title: VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if breakdown != .day, let id = row.provider, let brand = AgentBrand.forAgent(id) {
                        AgentLogo(brand: brand, size: 13)
                    }
                    if let session {
                        Button(title) { open(session) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textPrimary)
                            .help("Open this conversation")
                    } else {
                        Text(title).foregroundStyle(Theme.textPrimary)
                    }
                }
                .lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(row.provider.map(UsagePalette.color) ?? Theme.textSecondary)
                        .frame(width: max(2, proxy.size.width * min(1, row.share)))
                }
                .frame(height: 2)
            },
            cost: UsageFormat.money(row.cost), share: UsageFormat.percent(row.share),
            tokens: UsageFormat.tokens(row.tokens), header: false)
            .padding(.vertical, 9)
    }

    private func tableRow<Title: View>(index: String, title: Title, cost: String, share: String, tokens: String,
                                       header: Bool) -> some View {
        HStack(spacing: 16) {
            Text(index).frame(width: 28, alignment: .leading).foregroundStyle(Theme.textTertiary)
            title.frame(maxWidth: .infinity, alignment: .leading)
            Text(cost).frame(width: 110, alignment: .trailing)
            Text(share).frame(width: 70, alignment: .trailing)
            Text(tokens).frame(width: 80, alignment: .trailing)
        }
        .font(header ? Theme.captionFont : Theme.uiFont.monospacedDigit())
        .foregroundStyle(header ? Theme.textTertiary : Theme.textSecondary)
    }

    private func liveSession(_ row: UsageSummary.BreakdownRow) -> AgentSession? {
        guard let slash = row.id.firstIndex(of: "/") else { return nil }
        let id = String(row.id[row.id.index(after: slash)...])
        return center.sessions.first { $0.conversation.sessionId == id }
    }

    private func open(_ session: AgentSession) {
        window.focusWorkspace(session.workspaceId)
        AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        close()
    }
}

// MARK: - Chart

/// One translucent area per provider over the period, in its colour, with a
/// crosshair that reads every provider's value at the hovered day or hour.
private struct UsageAreaChart: View {
    let points: [UsageSummary.SeriesPoint]
    let providers: [String]
    let measure: UsageMeasure
    let hourly: Bool
    @State private var hovered: Date?

    private var unit: Calendar.Component { hourly ? .hour : .day }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date, unit: unit), y: .value("Value", point.value), stacking: .unstacked)
                    .foregroundStyle(by: .value("Provider", point.provider))
                    .interpolationMethod(.monotone)
                    .opacity(0.22)
                LineMark(x: .value("Time", point.date, unit: unit), y: .value("Value", point.value),
                         series: .value("Provider", point.provider))
                    .foregroundStyle(by: .value("Provider", point.provider))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let bucket = snapped {
                RuleMark(x: .value("Time", bucket, unit: unit))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(bucket) }
            }
        }
        .chartForegroundStyleScale(domain: providers, range: providers.map(UsagePalette.color))
        .chartLegend(.hidden)
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.divider)
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(axis(amount)) }
                }
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: hourly ? 6 : 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(hourly ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                    }
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityLabel(hourly ? "Usage by hour" : "Usage by day")
    }

    /// The bucket under the pointer.
    private var snapped: Date? {
        guard let hovered else { return nil }
        let dates = Set(points.map(\.date))
        return dates.min { abs($0.timeIntervalSince(hovered) - bucketMiddle) < abs($1.timeIntervalSince(hovered) - bucketMiddle) }
    }

    /// Marks with a unit sit in the middle of their hour or day.
    private var bucketMiddle: TimeInterval { hourly ? -1800 : -43_200 }

    private func tooltip(_ bucket: Date) -> some View {
        let values = points.filter { $0.date == bucket }
        return VStack(alignment: .leading, spacing: 4) {
            Text(hourly ? bucket.formatted(.dateTime.weekday(.abbreviated).hour()) : bucket.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 6) {
                    Circle().fill(UsagePalette.color(provider)).frame(width: 6, height: 6)
                    Text(UsagePalette.name(provider)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 12)
                    Text(UsageFormat.value(values.first { $0.provider == provider }?.value ?? 0, measure))
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(Theme.captionFont.monospacedDigit())
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func axis(_ value: Double) -> String {
        guard measure == .cost else { return UsageFormat.tokens(Int(value)) }
        if value >= 1000 { return String(format: "$%.1fk", value / 1000).replacingOccurrences(of: ".0k", with: "k") }
        return value >= 10 || value == 0 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}

// MARK: - Limits

/// Each signed-in account's allowance windows as labelled bars with when
/// they reset, from the same readings as the title-bar chips.
private struct UsageLimitsView: View {
    let accounts: [String: AgentAccount]
    let provider: String?

    private var shown: [AgentAccount] {
        accounts.values
            .filter { ($0.agent == provider || provider == nil) && $0.kind != .unknown }
            .sorted { UsagePalette.order($0.agent) < UsagePalette.order($1.agent) }
    }

    var body: some View {
        ScrollView {
            if shown.isEmpty {
                Text("No signed-in agent has reported an allowance yet.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)], spacing: 20) {
                    ForEach(shown, id: \.agent) { card($0) }
                }
                .padding(28)
            }
        }
    }

    private func card(_ account: AgentAccount) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let brand = AgentBrand.forAgent(account.agent) { AgentLogo(brand: brand, size: 15) }
                Text(UsagePalette.name(account.agent)).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(label(account)).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(Theme.card))
            }
            if account.live.isEmpty {
                Text(note(account)).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(account.live, id: \.name) { window($0) }
                if let updatedAt = account.updatedAt {
                    Text("As of \(UsageMeter.relative(min(updatedAt, Date())))").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func label(_ account: AgentAccount) -> String {
        switch account.kind {
        case .apiKey: account.plan ?? "API key"
        case .subscription: account.plan ?? "Subscription"
        case .signedOut: "Signed out"
        case .unknown: "Available"
        }
    }

    private func note(_ account: AgentAccount) -> String {
        switch account.kind {
        case .apiKey: "Signed in with an API key: there is no allowance, every token is billed."
        case .signedOut: "Not signed in. Sign in with its CLI to see its allowance."
        default: "No allowance reported yet. It shows here once the agent reports one, which it does as it works."
        }
    }

    private func window(_ window: UsageWindow) -> some View {
        let percent = Int((window.used * 100).rounded())
        let now = Date()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.title(window.name)).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(percent)% used").font(Theme.uiFont.monospacedDigit()).foregroundStyle(UsageMeter.color(window.used))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(UsageMeter.color(window.used))
                        .frame(width: max(3, proxy.size.width * min(1, max(0, window.used))))
                    if let expected = UsageReport.expected(window, at: now) {
                        Rectangle().fill(Theme.textTertiary).frame(width: 1, height: 10)
                            .offset(x: proxy.size.width * expected)
                            .help("Where an even pace would be by now")
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                Text("\(100 - percent)% left")
                if let reset = window.resetsAt, let when = UsageReport.resetsIn(reset, now: now) {
                    Text("· resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())), \(when)")
                }
                if let pace = UsageReport.pace(window, at: now) { Text("· \(pace)") }
            }
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "5h" reads as "5-hour limit", "7d" as "Weekly limit".
    static func title(_ name: String) -> String {
        switch name {
        case "5h": "5-hour limit"
        case "7d": "Weekly limit"
        default: name.hasSuffix("d") || name.hasSuffix("h") ? "\(name) limit" : name
        }
    }
}

// MARK: - Palette

/// The page's colours. Providers keep their brand: Claude's orange, Codex's
/// ink and OpenCode's blue, each stepped for the light or dark theme and
/// checked for colour-blind separation. The kinds of cost are a separate
/// categorical set in a fixed order.
enum UsagePalette {
    static func color(_ provider: String) -> Color {
        let light = Theme.isLight
        switch provider {
        case "claude": return Color(hex: "#d97757")
        case "codex": return Color(hex: light ? "#3a3d42" : "#c9ccd1")
        case "opencode": return Color(hex: light ? "#2f6fe0" : "#4f8ff7")
        default: return Color(hex: AgentBrand.forAgent(provider)?.hueHex ?? "#c78a1f")
        }
    }

    /// Input, cache read, cache write, output, other.
    static func type(_ index: Int) -> Color {
        let hexes = Theme.isLight
            ? ["#2f6fe0", "#14907f", "#b87d12", "#c24a62", "#7a5bd6"]
            : ["#4f8ff7", "#1fa293", "#c08419", "#d9677d", "#9b7de8"]
        return Color(hex: hexes[min(max(0, index), hexes.count - 1)])
    }

    static func name(_ provider: String) -> String {
        AgentBrand.forAgent(provider)?.displayName ?? provider.capitalized
    }

    static func order(_ provider: String) -> Int {
        ["claude", "codex", "opencode"].firstIndex(of: provider) ?? 10
    }
}
