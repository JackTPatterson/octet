import SwiftUI

/// Lists agent sessions and busy terminals a shutdown or session server
/// restart took (or, opened from the palette, recent agent sessions that
/// aren't running), grouped by workspace, and brings back the chosen ones.
/// A floating glass card, after T3 Code's dialogs, that stays out of the
/// terminal's way: no Return/Esc shortcuts, since the panel isn't modal and
/// those keys belong to the terminal you keep typing in.
///
/// Rows are two lines, so a screenful fits: the name, then where it ran and
/// what it last said. What can't come back sits in its own folded section
/// at the end rather than among what can.
struct RecoveryPanel: View {
    @ObservedObject var center: RecoveryCenter
    @State private var collapsed: Set<String> = [RecoveryPanel.unavailableGroup]
    @State private var expanded: Set<String> = []

    private static let unavailableGroup = "unavailable"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if center.items.isEmpty {
                emptyState
            } else {
                Rectangle().fill(Theme.divider).frame(height: 1)
                list
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
        }
        .frame(width: 460)
        .octetGlass(cornerRadius: 14, fill: Theme.card)
        .environment(\.colorScheme, Theme.colorScheme)
        .onChange(of: center.items.map(\.id)) { _, ids in
            expanded.formIntersection(ids)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.interfaceFont(14, weight: .semibold))
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
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
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
        let lost = items.filter { $0.status != .restored && !$0.status.isUnavailable }
        return "\(RecoveryList.countPhrase(lost)) stopped when the terminal server did."
    }

    // MARK: - List

    private var list: some View {
        let open = center.items.filter { !$0.status.isUnavailable }
        let unavailable = center.items.filter(\.status.isUnavailable)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(RecoveryList.groups(open)) { group in
                    section(id: group.id, title: group.title, items: group.items, selectable: true)
                }
                if !unavailable.isEmpty {
                    section(id: Self.unavailableGroup, title: "Can't be restored", items: unavailable, selectable: false)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section(id: String, title: String, items: [RecoveryItem], selectable: Bool) -> some View {
        let isOpen = !collapsed.contains(id)
        let ids = items.filter(\.status.canRestore).map(\.id)
        return VStack(alignment: .leading, spacing: 1) {
            RecoverySectionHeader(
                title: title,
                count: items.count,
                open: isOpen,
                check: selectable && !ids.isEmpty && !center.isFinished ? checkState(ids) : nil,
                busy: center.isRestoring,
                toggleOpen: {
                    MotionPreferences.shared.perform(.palette) {
                        if isOpen { collapsed.insert(id) } else { collapsed.remove(id) }
                    }
                },
                toggleCheck: { select(ids, checkState(ids) != .on) }
            )
            if isOpen {
                ForEach(items) { item in
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
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func checkState(_ ids: [String]) -> RecoveryCheck.State {
        let chosen = ids.filter(center.selected.contains).count
        return chosen == 0 ? .off : chosen == ids.count ? .on : .mixed
    }

    private func select(_ ids: [String], _ on: Bool) {
        if on { center.selected.formUnion(ids) } else { center.selected.subtract(ids) }
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
        .background(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).fill(Theme.terminalBackground.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
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
                if center.restorable.count > 1 {
                    RecoveryCheck(state: checkState(center.restorable.map(\.id)), busy: center.isRestoring) {
                        center.selectAll(!center.allSelected)
                    }
                    .accessibilityLabel("Select all")
                    Text("\(center.chosen.count) of \(center.restorable.count)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
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
                OctetButton(
                    title: RecoveryList.restoreTitle(selected: center.chosen.count, restorable: center.restorable.count),
                    icon: "arrow.counterclockwise",
                    kind: .primary
                ) { center.restoreChosen() }
                .disabled(center.chosen.isEmpty)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
    }
}

/// A checkbox with a third state, for a group or the whole list when only
/// some of it is chosen.
private struct RecoveryCheck: View {
    enum State { case off, mixed, on }

    let state: State
    let busy: Bool
    let action: () -> Void
    @SwiftUI.State private var hovered = false

    var body: some View {
        let lit = state != .off
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm)
        Button(action: action) {
            ZStack {
                shape.fill(lit ? Theme.accent : Theme.terminalBackground.opacity(0.7))
                shape.strokeBorder(lit ? Theme.accent : hovered ? Theme.textTertiary : Theme.border, lineWidth: 1)
                switch state {
                case .on: OctetIcon("check", size: 11).foregroundStyle(Theme.onAccent)
                case .mixed: Capsule().fill(Theme.onAccent).frame(width: 8, height: 2)
                case .off: EmptyView()
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: state)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.64 : 1)
        .onHover { hovered = $0 && !busy }
        .accessibilityValue(state == .on ? "Checked" : state == .mixed ? "Some checked" : "Unchecked")
    }
}

/// A workspace's heading: its name and count, folding its rows away, with a
/// checkbox for all of them.
private struct RecoverySectionHeader: View {
    let title: String
    let count: Int
    let open: Bool
    let check: RecoveryCheck.State?
    let busy: Bool
    let toggleOpen: () -> Void
    let toggleCheck: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let check {
                RecoveryCheck(state: check, busy: busy, action: toggleCheck)
                    .accessibilityLabel("Select \(title)")
            }
            Button(action: toggleOpen) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(Theme.interfaceFont(11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Text("\(count)")
                        .font(Theme.interfaceFont(11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary.opacity(0.8))
                    Spacer(minLength: 4)
                    OctetIcon("chevron.right", size: 9)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// One session or terminal on two lines: its mark and name, then where it
/// ran and what it last said. The age gives way to its actions on hover.
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
            VStack(alignment: .leading, spacing: 2) {
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
                    trailing
                }
                .frame(height: 20)
                subline
                if expanded, case .failed(let error) = item.status { errorDetail(error) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(hovered && item.status.canRestore ? Theme.hover.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if item.status.canRestore, !busy { toggle() } }
        .help([item.cwd, item.preview].compactMap { $0 }.joined(separator: "\n\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(abbreviateHome(item.cwd))")
        // The row's buttons show on hover; these reach them without it.
        .accessibilityActions {
            if item.status.canRestore, !busy {
                Button(item.status.isFailed ? "Try Again" : "Restore", action: restore)
                if item.agentRecord != nil { Button("Copy Resume Command", action: copy) }
            }
            Button("Dismiss", action: dismiss)
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        if item.status.canRestore {
            Toggle(isOn: Binding(get: { selected }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(OctetCheckboxStyle())
                .disabled(busy)
                .padding(.top, 2)
                .accessibilityLabel("Include \(item.title)")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.hover)
            if let brand = item.agent.flatMap(AgentBrand.forAgent) {
                AgentLogo(brand: brand, size: 12)
            } else {
                OctetIcon("terminal", size: 11).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 20, height: 20)
        .opacity(item.status.isUnavailable ? 0.5 : 1)
        .help(item.agent.flatMap(AgentBrand.forAgent)?.displayName ?? "Terminal")
    }

    /// The folder's last two parts, so rows in one workspace tell apart.
    private var place: String {
        let parts = abbreviateHome(item.cwd).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : parts.joined(separator: "/")
    }

    @ViewBuilder
    private var subline: some View {
        switch item.status {
        case .failed:
            Button(action: toggleError) {
                HStack(spacing: 4) {
                    OctetIcon("exclamationmark.triangle.fill", size: 10)
                    Text("Couldn't restore")
                        .font(Theme.captionFont.weight(.medium))
                    Text(expanded ? "Hide details" : "Details")
                        .font(Theme.captionFont)
                        .underline()
                }
                .foregroundStyle(Theme.danger)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Details shown" : "Details hidden")
        case .unavailable(let reason):
            Text("\(place) · \(reason)")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        default:
            (Text(place).foregroundStyle(Theme.textTertiary)
                + Text(item.preview.map { "  " + Self.oneLine($0) } ?? "").foregroundStyle(Theme.textSecondary))
                .font(Theme.captionFont)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func errorDetail(_ error: String) -> some View {
        Text(error)
            .font(Theme.monoFont)
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.terminalBackground.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1))
            .padding(.top, 4)
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .restoring:
            RecoverySpinner().frame(width: 22, height: 22)
                .accessibilityLabel("Restoring")
        case .restored:
            OctetIcon("checkmark.circle.fill", size: 14)
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Restored")
        case .unavailable:
            if hovered {
                OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss)
            }
        case .ready, .failed:
            // Actions take the age's place while hovered (or failed), so
            // they cost the text no room at rest.
            if hovered || item.status.isFailed, !busy {
                actions
            } else {
                Text(WorkspaceActivity.ageLabel(since: item.lastSeen))
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help(item.lastSeen.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if item.agentRecord != nil {
                OctetIconButton(icon: "doc.on.doc", help: item.command.map { "Copy \($0)" } ?? "Copy the resume command",
                                compact: true, action: copy)
            }
            OctetIconButton(icon: item.status.isFailed ? "arrow.clockwise" : "arrow.counterclockwise",
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
