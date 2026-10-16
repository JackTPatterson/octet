import SwiftUI

/// The agent updates dialog, drawn over the whole window like Octet's other
/// dialogs and in the same glass card as Octet's own update dialog, so the
/// two read as one family: what's new for each installed agent tool, a
/// switch to leave any out, the commands that will run, then each one's
/// progress in its row.
struct AgentUpdateDialog: View {
    @ObservedObject var center: AgentUpdateCenter
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()

    var body: some View {
        ZStack {
            if center.presented, host.owns(center.window) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { if center.phase != .running { center.dismiss() } }
                AgentUpdateCard(center: center)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.96))
                        : .identity)
                    .onAppear { DebugSnapshot.overlay("agent-updates", true) }
                    .onDisappear { DebugSnapshot.overlay("agent-updates", false) }
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.presented)
        .background(HostWindowReader(host: host))
    }
}

private struct AgentUpdateCard: View {
    @ObservedObject var center: AgentUpdateCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            list
            if center.phase == .choosing { commands }
            buttons
        }
        .padding(20)
        .frame(width: 540)
        .octetGlass(cornerRadius: 16, fill: Theme.card)
        .environment(\.colorScheme, Theme.colorScheme)
        .animation(MotionPreferences.shared.animation(.sidebar), value: center.rows)
        .animation(MotionPreferences.shared.animation(.sidebar), value: center.phase)
        .animation(MotionPreferences.shared.animation(.sidebar), value: center.expandedError)
    }

    // MARK: Header

    private var title: String {
        switch center.phase {
        case .running: return center.ran.count == 1 ? "Updating \(center.ran[0].update.displayName)…" : "Updating agents…"
        case .finished: return failedCount == center.ran.count ? "The update didn't finish" : "Some updates didn't finish"
        case .choosing:
            if center.rows.count == 1, let row = center.rows.first {
                return "\(row.update.displayName) \(row.update.latest) is available"
            }
            return "Agent updates are available"
        }
    }

    private var subtitle: String {
        switch center.phase {
        case .running:
            let done = center.ran.filter { $0.state != .running && $0.state != .queued }.count
            return "\(done) of \(center.ran.count) done. Each tool's own update command runs in your login shell."
        case .finished:
            return failedCount == 1
                ? "One command failed. Read its error below, then try again or run it yourself in a terminal."
                : "\(failedCount) commands failed. Read their errors below, then try again or run them yourself."
        case .choosing:
            return center.rows.count == 1
                ? "A newer release of an agent tool you have installed. Octet runs its own update command in your login shell."
                : "Newer releases of \(center.rows.count) agent tools you have installed. Octet runs each one's own update command in your login shell."
        }
    }

    private var failedCount: Int {
        center.rows.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LogoTile(brands: center.rows.compactMap { AgentBrand.forAgent($0.update.id) })
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Rows

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(center.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(Theme.divider.opacity(0.8)).frame(height: 1) }
                AgentUpdateRow(center: center, row: row)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.terminalBackground.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Commands

    private var commands: some View {
        let included = center.included
        let script = included.map(\.update.command).joined(separator: "\n")
        return OctetCollapsible(title: center.showCommands ? "Hide commands" : "Show commands",
                                open: $center.showCommands) {
            if center.showCommands, !included.isEmpty {
                OctetCopyText(text: script, display: "Copy all", help: "Copy every command")
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if included.isEmpty {
                    Text("Nothing selected.")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
                ForEach(included) { row in
                    HStack(spacing: 6) {
                        Text("$")
                            .font(Theme.monoFont)
                            .foregroundStyle(Theme.textTertiary)
                        OctetCopyText(text: row.update.command)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.terminalBackground.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
        }
        .padding(.vertical, -10)
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch center.phase {
            case .choosing:
                OctetButton(title: center.rows.count == 1 ? "Skip This Version" : "Skip These Versions", kind: .ghost) {
                    center.skip()
                }
                Spacer()
                OctetButton(title: "Later", kind: .secondary) { center.dismiss() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: updateTitle, kind: .primary) { center.primary() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(center.included.isEmpty)
            case .running:
                Spacer()
                OctetButton(title: "Hide", kind: .secondary) { center.hide() }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep updating out of the way; a notification says how it went.")
                OctetButton(title: "Updating…", kind: .primary) {}
                    .disabled(true)
            case .finished:
                Spacer()
                OctetButton(title: "Close", kind: .secondary) { center.close() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Try Again", icon: "arrow.clockwise", kind: .primary) { center.primary() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var updateTitle: String {
        let count = center.included.count
        if center.rows.count == 1 { return "Update" }
        return count == center.rows.count ? "Update All" : count == 0 ? "Update" : "Update \(count)"
    }
}

/// One agent: its mark and name, installed → new as mono pills, and a
/// switch while choosing; its progress, tick or error once running.
private struct AgentUpdateRow: View {
    @ObservedObject var center: AgentUpdateCenter
    let row: AgentUpdateCenter.Row

    private var brand: AgentBrand? { AgentBrand.forAgent(row.update.id) }
    private var expanded: Bool { center.expandedError == row.id }
    /// Left out of this run: dimmed while the others go.
    private var sittingOut: Bool { center.phase != .choosing && row.state == .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.hover)
                    if let brand { AgentLogo(brand: brand, size: 18) }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.update.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    status
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    VersionTag(label: row.update.current, current: true)
                    OctetIcon("arrow.right", size: 11).foregroundStyle(Theme.textTertiary)
                    VersionTag(label: row.update.latest, current: false)
                }
                trailing
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .opacity(sittingOut || (center.phase == .choosing && !row.included) ? 0.5 : 1)
            if expanded, case .failed(let error) = row.state {
                errorBlock(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.update.displayName), \(row.update.current) to \(row.update.latest)")
    }

    @ViewBuilder
    private var status: some View {
        switch row.state {
        case .idle:
            Text(sittingOut ? "Not updating" : row.update.command)
                .font(sittingOut ? Theme.captionFont : Theme.captionFont.monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        case .queued:
            Text("Waiting…")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        case .running:
            Text("Updating…")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        case .done:
            Text("Updated to \(row.update.latest)")
                .font(Theme.captionFont)
                .foregroundStyle(Color(hex: AgentStateColor.done))
        case .failed:
            Button {
                MotionPreferences.shared.perform(.sidebar) {
                    center.expandedError = expanded ? nil : row.id
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Failed")
                        .foregroundStyle(Theme.danger)
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(expanded ? "Hide error" : "Show error")
                        .foregroundStyle(Theme.textSecondary)
                    OctetIcon("chevron.right", size: 10)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(Theme.captionFont)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .idle:
            if center.phase == .choosing {
                Toggle("Include \(row.update.displayName)", isOn: Binding(
                    get: { row.included },
                    set: { center.setIncluded(row.id, $0) }))
                    .toggleStyle(OctetSwitchStyle())
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        case .queued:
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1).frame(width: 9, height: 9)
                .accessibilityLabel("Waiting")
        case .running:
            LoadingLine(width: 18)
        case .done:
            OctetIcon("checkmark.circle.fill", size: 16)
                .foregroundStyle(Color(hex: AgentStateColor.done))
                .accessibilityLabel("Updated")
        case .failed:
            OctetIcon("exclamationmark.triangle.fill", size: 16)
                .foregroundStyle(Theme.danger)
                .accessibilityLabel("Failed")
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(error)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .octetScrollIndicators()
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.danger.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1))
            HStack(spacing: 4) {
                Text("Run it yourself:")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                OctetCopyText(text: row.update.command)
                Spacer(minLength: 0)
                OctetCopyText(text: error, display: "Copy error", help: "Copy the error")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .transition(.opacity)
    }
}

/// The header's mark: one agent's logo, or up to four in a grid.
private struct LogoTile: View {
    let brands: [AgentBrand]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover)
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
            if brands.count == 1, let brand = brands.first {
                AgentLogo(brand: brand, size: 26)
            } else {
                let shown = Array(brands.prefix(4))
                LazyVGrid(columns: [GridItem(.fixed(16), spacing: 6), GridItem(.fixed(16), spacing: 6)], spacing: 6) {
                    ForEach(shown, id: \.id) { AgentLogo(brand: $0, size: 16) }
                }
                .frame(width: 38)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }
}
