import SwiftUI

/// Lists agent sessions and busy terminals a shutdown or session server
/// restart took (or, opened from the palette, recent agent sessions that
/// aren't running), grouped by workspace, and brings back the chosen ones.
/// A floating glass card, after T3 Code's dialogs, that stays out of the
/// terminal's way: no Return/Esc shortcuts, since the panel isn't modal and
/// those keys belong to the terminal you keep typing in.
struct RecoveryPanel: View {
    @ObservedObject var center: RecoveryCenter
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if center.items.isEmpty {
                emptyState
            } else {
                if center.restorable.count > 1, !center.isFinished { selectionBar }
                Rectangle().fill(Theme.divider).frame(height: 1)
                list
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
        }
        .frame(width: 440)
        .octetGlass(cornerRadius: 14, fill: Theme.card)
        .environment(\.colorScheme, Theme.colorScheme)
        .onChange(of: center.items.map(\.id)) { _, ids in
            expanded.formIntersection(ids)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                OctetIcon(center.isFinished ? "checkmark" : "arrow.counterclockwise.circle", size: 15)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            OctetIconButton(icon: "xmark", help: center.mode == .lost ? "Close (the palette can bring this back)" : "Close") {
                MotionPreferences.shared.perform(.palette) { center.close() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var title: String {
        if center.items.isEmpty { return "Nothing to recover" }
        if center.isFinished {
            return center.items.allSatisfy { $0.status == .restored } ? "Everything's back" : "Done"
        }
        return center.mode == .history ? "Recent agent sessions" : "Recover sessions"
    }

    private var subtitle: String {
        let items = center.items
        if items.isEmpty {
            return "Octet records agent sessions and busy terminals while they run, and offers them back if the terminal server stops."
        }
        if let progress = RecoveryList.progress(items, batch: center.batch) {
            return "Restoring \(min(progress.done + 1, progress.total)) of \(progress.total)…"
        }
        if center.isFinished {
            let restored = items.filter { $0.status == .restored }
            let terminals = restored.contains { $0.terminalRecord != nil }
            let base = "Restored \(RecoveryList.countPhrase(restored))."
            return terminals ? base + " Commands are back on the prompt, not rerun." : base
        }
        if center.mode == .history {
            return "Not running now. Resume any of them in its workspace."
        }
        let lost = items.filter { $0.status != .restored }
        return "\(RecoveryList.countPhrase(lost)) stopped when the terminal server did."
    }

    // MARK: - Selection

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { center.allSelected }, set: { center.selectAll($0) })) {
                Text("Select all")
            }
            .toggleStyle(OctetCheckboxStyle())
            .disabled(center.isRestoring)
            Spacer()
            Text("\(center.chosen.count) of \(center.restorable.count) selected")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var list: some View {
        let groups = RecoveryList.groups(center.items)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    OctetCollapsible(
                        title: group.title,
                        open: Binding(get: { !collapsed.contains(group.id) },
                                      set: { open in if open { collapsed.remove(group.id) } else { collapsed.insert(group.id) } }),
                        trailing: {
                            Text("\(group.items.count)")
                                .font(Theme.captionFont.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    ) {
                        VStack(spacing: 2) {
                            ForEach(group.items) { item in
                                RecoveryItemRow(
                                    item: item,
                                    selected: center.selected.contains(item.id),
                                    expanded: expanded.contains(item.id),
                                    busy: center.isRestoring,
                                    toggle: { center.toggle(item.id) },
                                    toggleError: {
                                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                                    },
                                    restore: { center.restore([item.id]) },
                                    dismiss: { MotionPreferences.shared.perform(.palette) { center.dismiss(item.id) } },
                                    copy: { center.copyCommand(item) }
                                )
                                .transition(.opacity)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            OctetIcon("clock", size: 18).foregroundStyle(Theme.textTertiary)
            Text("No agent sessions or terminals are waiting to come back.")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.terminalBackground.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if let progress = RecoveryList.progress(center.items, batch: center.batch) {
                ProgressTrack(value: Double(progress.done) / Double(max(progress.total, 1)))
                    .frame(maxWidth: .infinity)
                Text("\(progress.done) of \(progress.total)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, alignment: .trailing)
            } else if center.items.isEmpty || center.isFinished {
                Spacer()
                OctetButton(title: center.items.isEmpty ? "Close" : "Done", kind: center.items.isEmpty ? .secondary : .primary) {
                    MotionPreferences.shared.perform(.palette) { center.close() }
                }
            } else {
                if center.mode == .history {
                    OctetButton(title: "Close", kind: .ghost) {
                        MotionPreferences.shared.perform(.palette) { center.close() }
                    }
                } else {
                    OctetButton(title: "Dismiss All", kind: .ghost) {
                        MotionPreferences.shared.perform(.palette) { center.dismissAll() }
                    }
                    .help("Set them aside. Recover Sessions in the palette or File menu brings them back.")
                }
                Spacer()
                OctetButton(
                    title: RecoveryList.restoreTitle(selected: center.chosen.count, restorable: center.restorable.count),
                    icon: "arrow.counterclockwise.circle",
                    kind: .primary
                ) { center.restoreChosen() }
                .disabled(center.chosen.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// One session or terminal: its mark, name, folder, when it was last seen,
/// what it last said, and how it stands.
private struct RecoveryItemRow: View {
    let item: RecoveryItem
    let selected: Bool
    let expanded: Bool
    let busy: Bool
    let toggle: () -> Void
    let toggleError: () -> Void
    let restore: () -> Void
    let dismiss: () -> Void
    let copy: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            checkbox
            mark
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(item.terminalRecord != nil ? Theme.monoFont : Theme.uiFontMedium)
                        .foregroundStyle(item.status.isUnavailable ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // The row's actions take the age's place while it's
                    // hovered, so they cost the text no room at rest.
                    if item.status.canRestore, hovered || item.status.isFailed, !busy {
                        actions
                    } else {
                        Text(WorkspaceActivity.ageLabel(since: item.lastSeen))
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .frame(height: 22)
                            .help(item.lastSeen.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Text(abbreviateHome(item.cwd))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.cwd)
                if let preview = item.preview, !item.status.isUnavailable {
                    Text(preview)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
                statusLine
            }
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(hovered && item.status.canRestore ? Theme.hover.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if item.status.canRestore, !busy { toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(abbreviateHome(item.cwd))")
    }

    @ViewBuilder
    private var checkbox: some View {
        if item.status.canRestore {
            Toggle(isOn: Binding(get: { selected }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(OctetCheckboxStyle())
                .disabled(busy)
                .padding(.top, 1)
                .accessibilityLabel("Include \(item.title)")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.hover)
            if let brand = item.agent.flatMap(AgentBrand.forAgent) {
                AgentLogo(brand: brand, size: 13)
            } else {
                OctetIcon("terminal", size: 12).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 20, height: 20)
        .opacity(item.status.isUnavailable ? 0.5 : 1)
        .help(item.agent.flatMap(AgentBrand.forAgent)?.displayName ?? "Terminal")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.status {
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Button(action: toggleError) {
                    HStack(spacing: 4) {
                        OctetIcon("exclamationmark.triangle.fill", size: 11)
                        Text("Couldn't restore")
                            .font(Theme.captionFont.weight(.medium))
                        OctetIcon("chevron.right", size: 9)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .foregroundStyle(Theme.danger)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Details shown" : "Details hidden")
                if expanded {
                    Text(error)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.terminalBackground.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1))
                }
            }
            .padding(.top, 2)
        case .unavailable(let reason):
            Text(reason)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 1)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        Group {
            switch item.status {
            case .restoring:
                RecoverySpinner().frame(width: 22, height: 22)
                    .accessibilityLabel("Restoring")
            case .restored:
                OctetIcon("checkmark.circle.fill", size: 15)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Restored")
            case .unavailable:
                HStack(spacing: 2) {
                    Text("Unavailable")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Theme.hover))
                    if hovered { OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss) }
                }
            case .ready, .failed:
                EmptyView()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if item.agentRecord != nil {
                OctetIconButton(icon: "doc.on.doc", help: item.command.map { "Copy \($0)" } ?? "Copy the resume command",
                                compact: true, action: copy)
            }
            OctetIconButton(icon: item.status.isFailed ? "arrow.clockwise" : "arrow.counterclockwise.circle",
                            help: item.status.isFailed ? "Try again" : "Restore", compact: true, action: restore)
            OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss)
        }
    }
}

/// A thin ring turning, for a row on its way back.
private struct RecoverySpinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// The update dialog's progress track: a quiet capsule filled with the accent.
private struct ProgressTrack: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hover)
                Capsule().fill(Theme.accent).frame(width: max(4, proxy.size.width * min(1, value)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}
