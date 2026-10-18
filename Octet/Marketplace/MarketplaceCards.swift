import AppKit
import SwiftUI

// MARK: - Card slots

/// Where a row sits in its card. Rows are separate views so a long list can
/// be lazy, and each draws its share of the card: rounded corners at the
/// ends, the side borders, and a hairline above every row but the first.
enum CardSlot {
    case only, first, middle, last

    static func at(_ index: Int, of count: Int) -> CardSlot {
        if count <= 1 { return .only }
        if index == 0 { return .first }
        return index == count - 1 ? .last : .middle
    }

    var isTop: Bool { self == .only || self == .first }
    var isBottom: Bool { self == .only || self == .last }
}

extension View {
    /// Draws a row as its part of a Settings-style card.
    func cardSlot(_ slot: CardSlot) -> some View {
        modifier(CardSlotModifier(slot: slot))
    }
}

private struct CardSlotModifier: ViewModifier {
    let slot: CardSlot
    func body(content: Content) -> some View {
        // Flat: a hairline above every row, and one below the last.
        content
            .overlay(alignment: .top) { Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1) }
            .overlay(alignment: .bottom) {
                if slot.isBottom { Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1) }
            }
    }
}

// MARK: - Group header

/// A group's title above its card, as SettingsGroup's: 14pt at 70%, with a
/// count after it and the group's own control at the far end.
struct MarketplaceGroupHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.interfaceFont(14))
                .foregroundStyle(Theme.textPrimary.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
            Text(count.formatted())
                .font(Theme.interfaceFont(12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 28)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }
}

/// The last row of a long group: how much shows, and a page more.
struct ShowMoreRow: View {
    let shown: Int
    let total: Int
    let more: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Showing \(shown.formatted()) of \(total.formatted())")
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            OctetButton(title: "Show \(min(MarketplaceStore.pageSize, total - shown).formatted()) More", kind: .ghost, compact: true, action: more)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Nav

/// What leads a row: a symbol, an agent's logo, or an initial.
enum MarketplaceMark {
    case symbol(String)
    case agent(String)
    case monogram(String)
}

/// A section or an agent in the Marketplace's list, as SettingsNavRow: a
/// 32pt row, the icon dim until hovered or chosen, with a count at the end.
struct MarketplaceNavRow: View {
    let mark: MarketplaceMark
    let title: String
    let count: String?
    let loading: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    switch mark {
                    case .agent(let id):
                        if let brand = AgentBrand.forAgent(id) {
                            AgentLogo(brand: brand, size: 14)
                                .opacity(selected || hovered ? 1 : 0.75)
                        } else {
                            OctetIcon("terminal", size: 15)
                        }
                    case .symbol(let name):
                        OctetIcon(name, size: 15)
                    case .monogram(let text):
                        Text(text.prefix(1).uppercased()).font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if loading {
                    LoadingLine(width: 14)
                } else if let count {
                    Text(count)
                        .font(Theme.interfaceFont(11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(loading ? "Loading" : count ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The agent the page is filtered to, in the breadcrumb; click to show
/// every agent again.
struct AgentCrumb: View {
    let host: AgentHost
    let clear: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                if let brand = AgentBrand.forAgent(host.id) { AgentLogo(brand: brand, size: 13) }
                Text(host.displayName).foregroundStyle(Theme.textPrimary)
                OctetIcon("xmark", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show every agent")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Plugin source tabs

/// All, agents' plugins, or Octet's own, in Octet's tab style: square
/// edges, the tab in front on the page's background with a line along its
/// top, and dividers between.
struct PluginSourceTabs: View {
    @ObservedObject var store: MarketplaceStore
    let agentCount: Int
    let terminalCount: Int
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MarketplaceStore.PluginFilter.allCases) { filter in
                SourceTab(title: filter.title, count: count(filter), active: store.pluginFilter == filter,
                          selection: selection) {
                    MotionPreferences.shared.perform(.tabs) { store.pluginFilter = filter }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.tabBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plugin sources")
    }

    private func count(_ filter: MarketplaceStore.PluginFilter) -> Int {
        switch filter {
        case .all: agentCount + terminalCount
        case .agents: agentCount
        case .terminal: terminalCount
        }
    }

    private struct SourceTab: View {
        let title: String
        let count: Int
        let active: Bool
        let selection: Namespace.ID
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.uiFont)
                        .fontWeight(active ? .medium : .regular)
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    Text(count.formatted())
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .background {
                    ZStack {
                        if hovered && !active { Theme.hover }
                        if active {
                            ZStack(alignment: .top) {
                                Theme.terminalBackground
                                Rectangle().fill(Theme.textPrimary.opacity(0.9)).frame(height: 2)
                            }
                            .matchedGeometryEffect(id: "pluginSource", in: selection)
                        }
                    }
                }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(title)
            .accessibilityValue("\(count)")
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Banners and states

/// A notice above a section's groups: a failed refresh, updates waiting.
struct MarketplaceBanner<Trailing: View>: View {
    enum Tone { case danger, accent }
    let tone: Tone
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let tint = tone == .danger ? Theme.danger : Theme.accent
        HStack(alignment: .top, spacing: 12) {
            OctetIcon(icon, size: 16)
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.interfaceFont(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if !message.isEmpty {
                    Text(message)
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08))
        .overlay(alignment: .top) { Rectangle().fill(tint.opacity(0.4)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.4)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// Stands in for a section with nothing to list: empty, failed, no
/// matches, or no agent to manage it.
struct MarketplaceEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            OctetIcon(symbol, size: 28)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 52, height: 52)
            Text(title)
                .font(Theme.interfaceFont(14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)
            Text(message)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                OctetButton(title: actionTitle, compact: true, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.bottom, 30)
        .accessibilityElement(children: .contain)
    }
}

/// Grey rows in the shape of the list that's on its way.
struct MarketplaceSkeleton: View {
    let title: String
    let detail: String
    var body: some View {
        // Each block breathes in a wave down the list (SkeletonBlock).
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.interfaceFont(14))
                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                LoadingLine(width: 18)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 4)
            Text(detail)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    SkeletonRow(seed: index).cardSlot(.at(index, of: 6))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private struct SkeletonRow: View {
        let seed: Int

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                SkeletonBlock(width: 32, height: 32, radius: Theme.controlRadius)
                VStack(alignment: .leading, spacing: 8) {
                    bar(width: [140, 180, 110, 160, 130, 150][seed % 6], height: 11)
                    bar(width: [360, 300, 420, 260, 340, 390][seed % 6], height: 8)
                    HStack(spacing: 6) {
                        bar(width: 64, height: 16)
                        bar(width: 56, height: 16)
                    }
                }
                Spacer(minLength: 0)
                bar(width: 60, height: 22)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        private func bar(width: CGFloat, height: CGFloat) -> some View {
            SkeletonBlock(width: width, height: height, radius: height / 2)
        }
    }
}

// MARK: - Row parts

/// A row's mark: its icon on a small tile, lit when installed.
struct MarkTile: View {
    let mark: MarketplaceMark
    let active: Bool

    var body: some View {
        Group {
            switch mark {
            case .symbol(let name):
                OctetIcon(name, size: 16)
            case .agent(let id):
                if let brand = AgentBrand.forAgent(id) { AgentLogo(brand: brand, size: 16) } else { OctetIcon("terminal", size: 16) }
            case .monogram(let text):
                Text(text.prefix(1).uppercased()).font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(active ? Theme.cardSelected : Theme.card.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border.opacity(active ? 0.9 : 0.5), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if active {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Theme.terminalBackground, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small outlined label: where something comes from, "Built in".
struct SourceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Which agents have an item: a chip with each agent's logo, filled where
/// it's installed, dashed where it could be.
struct AgentChips: View {
    let hosts: [AgentHost]
    let installedIn: Set<String>
    var disabledIn: Set<String> = []
    var warningIn: Set<String> = []

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(hosts) { host in
                MarketplaceAgentChip(host: host, installed: installedIn.contains(host.id),
                          disabled: disabledIn.contains(host.id), warning: warningIn.contains(host.id))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MarketplaceAgentChip: View {
    let host: AgentHost
    let installed: Bool
    var disabled = false
    var warning = false

    var body: some View {
        let tint = AgentBrand.forAgent(host.id)?.hueHex.map { Color(hex: $0) } ?? Theme.accent
        HStack(spacing: 4) {
            if let brand = AgentBrand.forAgent(host.id) {
                AgentLogo(brand: brand, size: 10).saturation(installed ? 1 : 0)
            } else {
                OctetIcon("terminal", size: 11)
            }
            Text(host.displayName).font(Theme.captionFont).lineLimit(1)
            if warning {
                OctetIcon("exclamationmark.triangle.fill", size: 10).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(installed ? Theme.textPrimary : Theme.textTertiary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(installed ? tint.opacity(disabled ? 0.08 : 0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(installed ? tint.opacity(0.45) : Theme.border.opacity(0.8),
                          style: StrokeStyle(lineWidth: 1, dash: installed ? [] : [3, 2])))
        .fixedSize()
        .help(warning ? "\(host.displayName) reports a problem" : installed ? (disabled ? "Disabled in \(host.displayName)" : "In \(host.displayName)")
              : "Not in \(host.displayName)")
        .accessibilityLabel("\(host.displayName): \(installed ? (disabled ? "installed, disabled" : "installed") : "not installed")")
    }
}

/// The frame every Marketplace row shares: the mark, the name line, a
/// description that opens out, the agents that have it, and the row's
/// actions; click anywhere else to see its details beneath.
struct MarketplaceCard<Actions: View, Detail: View>: View {
    let mark: MarketplaceMark
    let name: String
    var version = ""
    var badges: [String] = []
    var installs: Int?
    var summary = ""
    var active = false
    var hosts: [AgentHost] = []
    var installedIn: Set<String> = []
    var disabledIn: Set<String> = []
    var warningIn: Set<String> = []
    @Binding var expanded: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var detail: () -> Detail
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MarkTile(mark: mark, active: active)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(Theme.interfaceFont(13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if !version.isEmpty {
                            Text(version)
                                .font(Theme.interfaceFont(11).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        ForEach(badges.filter { !$0.isEmpty }, id: \.self) { SourceBadge(text: $0) }
                        if let installs, installs > 0 {
                            Text("\(installs.formatted(.number.notation(.compactName))) installs")
                                .font(Theme.interfaceFont(11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(Theme.interfaceFont(12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !hosts.isEmpty {
                        AgentChips(hosts: hosts, installedIn: installedIn, disabledIn: disabledIn, warningIn: warningIn)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    actions()
                    OctetIconButton(icon: "chevron.down", help: expanded ? "Hide details" : "Show details") { expanded.toggle() }
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
                VStack(alignment: .leading, spacing: 14) { detail() }
                    .padding(.leading, 60)
                    .padding(.trailing, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground.opacity(0.35))
            }
        }
        .background(hovered && !expanded ? Theme.hover.opacity(0.45) : .clear)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// A labelled value in a row's details.
struct DetailField<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 92, alignment: .leading)
            value()
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A heading inside a row's details.
struct DetailHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.interfaceFont(11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One agent's line in a row's details: its logo and name, how the item
/// stands there, and what can be done about it.
struct AgentStateRow<Controls: View>: View {
    let host: AgentHost
    let state: String
    var warning = false
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let brand = AgentBrand.forAgent(host.id) { AgentLogo(brand: brand, size: 14) } else { OctetIcon("terminal", size: 14) }
            }
            .frame(width: 16)
            Text(host.displayName)
                .font(Theme.interfaceFont(12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(state)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(warning ? Color.orange : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            controls()
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
    }
}

/// A spinner and a word, where a button was while its command runs.
struct BusyLabel: View {
    var title = "Working…"

    var body: some View {
        HStack(spacing: 6) {
            LoadingLine(width: 14)
            Text(title).font(Theme.interfaceFont(12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// A plugin or MCP server.
struct EntryRow: View {
    @ObservedObject var store: MarketplaceStore
    let entry: MarketplaceEntry
    @Binding var expanded: Bool

    private var section: MarketplaceStore.Section { entry.kind == .mcp ? .mcp : .plugins }
    private var capable: [AgentHost] { store.capableHosts(for: section) }
    private var scope: [AgentHost] { store.scopeHosts(for: section) }
    private var warnings: Set<String> {
        Set(entry.status.filter { $0.value.contains("✘") || $0.value.localizedCaseInsensitiveContains("failed") }.keys)
    }

    var body: some View {
        MarketplaceCard(
            mark: entry.kind == .mcp ? .symbol(MarketplaceStore.Section.mcp.symbol) : .monogram(entry.name),
            name: entry.name,
            version: entry.version,
            badges: [entry.kind == .mcp ? (MarketplaceCatalog.serverTarget(entry.detail).isURL ? "HTTP" : "stdio") : entry.marketplace],
            installs: entry.installCount,
            summary: entry.summary.isEmpty ? (entry.kind == .mcp ? entry.detail : "") : entry.summary,
            active: entry.isInstalled,
            hosts: capable,
            installedIn: entry.installedIn,
            disabledIn: entry.installedIn.subtracting(entry.enabledIn),
            warningIn: warnings,
            expanded: $expanded
        ) {
            primary
        } detail: {
            detail
        }
    }

    @ViewBuilder private var primary: some View {
        let missing = scope.filter { !entry.installedIn.contains($0.id) }
        let present = scope.filter { entry.installedIn.contains($0.id) }
        if store.isBusy(entry) {
            BusyLabel()
        } else if present.isEmpty, !missing.isEmpty {
            OctetButton(title: entry.kind == .mcp && entry.isInstalled ? "Add to \(missing.count == 1 ? missing[0].displayName : "All")" : "Install",
                        kind: .primary, compact: true) {
                store.add(entry, to: missing)
            }
            .help("Install in \(missing.map(\.displayName).joined(separator: ", "))")
        } else if !present.isEmpty {
            OctetButton(title: "Remove", kind: .ghost, compact: true) { confirmRemove(from: present) }
                .help("Remove from \(present.map(\.displayName).joined(separator: ", "))")
        }
    }

    private func confirmRemove(from hosts: [AgentHost]) {
        ConfirmCenter.shared.ask(
            title: "Remove \(entry.name)?",
            message: "Removes it from \(hosts.map(\.displayName).joined(separator: ", ")).",
            confirmTitle: "Remove",
            destructive: true
        ) { _ in store.remove(entry, from: hosts) }
    }

    @ViewBuilder private var detail: some View {
        if !entry.summary.isEmpty {
            Text(entry.summary)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 6) {
            if entry.kind == .mcp {
                let target = MarketplaceCatalog.serverTarget(entry.detail)
                DetailField(label: target.isURL ? "URL" : "Command") { OctetCopyText(text: target.value) }
                DetailField(label: "Transport") { Text(target.isURL ? target.transport.uppercased() : "stdio") }
            } else {
                DetailField(label: "Identifier") { OctetCopyText(text: entry.identifier) }
                if !entry.marketplace.isEmpty { DetailField(label: "Marketplace") { Text(entry.marketplace) } }
                if !entry.version.isEmpty { DetailField(label: "Version") { Text(entry.version) } }
                if let installs = entry.installCount { DetailField(label: "Installs") { Text(installs.formatted()) } }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            DetailHeading(title: "Agents")
            ForEach(capable) { host in
                AgentStateRow(host: host, state: state(in: host), warning: warnings.contains(host.id)) {
                    hostControls(host)
                }
            }
        }
    }

    private func state(in host: AgentHost) -> String {
        if let status = entry.status[host.id], !status.isEmpty { return status }
        guard entry.installedIn.contains(host.id) else { return "Not installed" }
        return entry.enabledIn.contains(host.id) ? "Installed" : "Installed, disabled"
    }

    @ViewBuilder private func hostControls(_ host: AgentHost) -> some View {
        let installed = entry.installedIn.contains(host.id)
        if store.isBusy(entry, host) {
            BusyLabel()
        } else if installed {
            if entry.kind == .plugin {
                Toggle("Enable \(entry.name) in \(host.displayName)", isOn: Binding(
                    get: { entry.enabledIn.contains(host.id) },
                    set: { store.setPluginEnabled(entry, in: host, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(OctetSwitchStyle())
                .help(entry.enabledIn.contains(host.id) ? "Disable in \(host.displayName)" : "Enable in \(host.displayName)")
            }
            OctetButton(title: "Remove", kind: .ghost, compact: true) { confirmRemove(from: [host]) }
        } else {
            OctetButton(title: entry.kind == .mcp ? "Add" : "Install", compact: true) { store.add(entry, to: [host]) }
                .disabled(entry.kind == .mcp && entry.detail.isEmpty)
        }
    }
}

/// One of Octet's own plugins: on or off when it's here, Install when it's
/// only in the registry, Update when the registry has newer, Remove when
/// the person installed it.
struct TerminalPluginRow: View {
    let plugin: MarketplaceStore.TerminalPlugin
    @Binding var expanded: Bool
    @ObservedObject private var host = OctetPluginHost.shared

    var body: some View {
        let installed = plugin.installed
        MarketplaceCard(
            mark: .symbol("terminal"),
            name: plugin.name,
            version: plugin.version,
            badges: ["Terminal", installed?.isBundled == true ? "Built in" : ""],
            summary: plugin.summary,
            active: installed.map(host.isEnabled) == true,
            expanded: $expanded
        ) {
            if host.installing.contains(plugin.id) {
                BusyLabel(title: "Installing…")
            } else if let installed {
                if let update = host.update(for: installed) {
                    OctetButton(title: "Update", kind: .primary, compact: true) { host.install(update) }
                        .help("Update to \(update.version)")
                }
                Toggle("Enable \(plugin.name)", isOn: Binding(get: { host.isEnabled(installed) },
                                                              set: { host.setEnabled(installed, $0) }))
                    .labelsHidden()
                    .toggleStyle(OctetSwitchStyle())
                    .help(host.isEnabled(installed) ? "Turn off" : "Turn on")
            } else if let entry = plugin.entry {
                OctetButton(title: "Install", kind: .primary, compact: true) { host.install(entry) }
            }
        } detail: {
            if !plugin.summary.isEmpty {
                Text(plugin.summary)
                    .font(Theme.interfaceFont(12))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                DetailField(label: "Identifier") { OctetCopyText(text: plugin.id) }
                if !plugin.author.isEmpty { DetailField(label: "Author") { Text(plugin.author) } }
                DetailField(label: "Version") {
                    if let installed, let update = host.update(for: installed) {
                        Text("\(plugin.version), \(update.version) available")
                    } else {
                        Text(plugin.version)
                    }
                }
                if let entry = plugin.entry { DetailField(label: "Source") { OctetCopyText(text: "github.com/\(entry.repo)") } }
                if !plugin.keywords.isEmpty { DetailField(label: "Keywords") { Text(plugin.keywords.joined(separator: ", ")) } }
                if let installed { DetailField(label: "Folder") { OctetCopyText(text: installed.directory) } }
            }
            if let installed {
                HStack(spacing: 6) {
                    if installed.manifest.settings?.isEmpty == false {
                        OctetButton(title: "Settings", icon: "gearshape", compact: true) { PluginSettingsOpener.show(pluginId: installed.id) }
                            .disabled(!host.isEnabled(installed))
                            .help(host.isEnabled(installed) ? "Open its settings" : "Turn it on to change its settings")
                    }
                    if !installed.isBundled {
                        OctetButton(title: "Remove", kind: .ghost, compact: true) {
                            ConfirmCenter.shared.ask(title: "Remove \(plugin.name)?", message: "Deletes it from your plugin folder.",
                                                     confirmTitle: "Remove", destructive: true) { _ in host.uninstall(installed) }
                        }
                    }
                }
            }
        }
    }
}

/// A skill or prompt in the library.
struct LibraryRow: View {
    @ObservedObject var store: MarketplaceStore
    let item: AgentLibrary.Item
    @Binding var expanded: Bool
    let edit: () -> Void

    private var section: MarketplaceStore.Section { item.kind == .skill ? .skills : .prompts }

    var body: some View {
        MarketplaceCard(
            mark: .symbol(section.symbol),
            name: item.name,
            badges: [item.name == item.slug ? "" : item.slug, "Library"],
            summary: item.summary,
            active: !item.installedIn.isEmpty,
            hosts: store.hosts,
            installedIn: item.installedIn,
            expanded: $expanded
        ) {
            primary
        } detail: {
            detail
        }
    }

    @ViewBuilder private var primary: some View {
        let scope = store.scopeHosts(for: section)
        let missing = scope.filter { !item.installedIn.contains($0.id) }
        if item.kind == .prompt, let agent = store.promptTarget, !item.installedIn.isEmpty {
            OctetButton(title: "Run", icon: "arrow.right", compact: true) { store.runPrompt(item) }
                .help("Send this prompt to \(AgentBrand.forAgent(agent.agent)?.displayName ?? "the focused agent")")
        }
        if !missing.isEmpty, missing.count == scope.count {
            OctetButton(title: "Install", kind: .primary, compact: true) {
                for host in missing { store.setLibraryInstalled(item, host: host, installed: true) }
            }
            .help("Install in \(missing.map(\.displayName).joined(separator: ", "))")
        } else {
            OctetButton(title: "Edit", kind: .ghost, compact: true, action: edit)
        }
    }

    @ViewBuilder private var detail: some View {
        if !item.summary.isEmpty {
            Text(item.summary)
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 6) {
            DetailField(label: "Name") { OctetCopyText(text: item.slug) }
            DetailField(label: "File") { OctetCopyText(text: item.contentPath) }
        }
        let preview = AgentLibrary.promptBody(store.text(of: item))
        if !preview.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DetailHeading(title: "Contents")
                Text(preview.count > 600 ? String(preview.prefix(600)) + "…" : preview)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.terminalBackground.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            DetailHeading(title: "Agents")
            ForEach(store.hosts) { host in
                let installed = item.installedIn.contains(host.id)
                AgentStateRow(host: host, state: installed ? "Installed" : "Not installed") {
                    OctetButton(title: installed ? "Remove" : "Install", kind: installed ? .ghost : .secondary, compact: true) {
                        store.setLibraryInstalled(item, host: host, installed: !installed)
                    }
                }
            }
        }
        HStack(spacing: 6) {
            OctetButton(title: "Edit", icon: "pencil", compact: true, action: edit)
            OctetButton(title: "Show in Finder", icon: "folder", kind: .ghost, compact: true) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.contentPath)])
            }
            Spacer(minLength: 0)
            OctetButton(title: "Delete", icon: "trash", kind: .ghost, compact: true) {
                ConfirmCenter.shared.ask(
                    title: "Delete \(item.name)?",
                    message: "Deletes it from the library and uninstalls it from every agent that has it. This can't be undone.",
                    confirmTitle: "Delete",
                    destructive: true
                ) { _ in store.deleteLibraryItem(item) }
            }
        }
    }
}

/// A skill or prompt an agent has on its own, which the library can take
/// over and share.
struct UnmanagedRow: View {
    @ObservedObject var store: MarketplaceStore
    let kind: AgentLibrary.Kind
    let item: UnmanagedItem

    var body: some View {
        HStack(spacing: 12) {
            MarkTile(mark: .agent(item.host.id), active: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.slug)
                    .font(Theme.interfaceFont(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Only in \(item.host.displayName)")
                    .font(Theme.interfaceFont(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OctetButton(title: "Add to Library", compact: true) { store.adopt(kind: kind, slug: item.slug, from: item.host) }
                .help("Move it into the library so your other agents can have it too")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Keeps every agent chip readable and wraps complete chips onto another
/// line when the page is narrow.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = positions(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: result.width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(for: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func positions(for subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, max(0, x - spacing))
        }
        return (points, min(usedWidth, width), y + rowHeight)
    }
}
