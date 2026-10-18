import AppKit
import SwiftUI

/// The snooze choices, for a menu: out of the way until a time, until the
/// workspace is used, or until something happens (a wait with no step,
/// that only brings it back).
struct SnoozeMenuItems: View {
    @ObservedObject var store: SessionStore
    let workspaceId: String

    var body: some View {
        // Read when the menu is built, so "This Evening" drops out once
        // the evening is close.
        ForEach(SnoozeChoice.offered().filter { $0 != .untilUsed }) { choice in
            Button(choice.title) { store.snooze(workspaceId, choice) }
        }
        Button("Pick a Time…") { SnoozePickerCenter.shared.ask(store: store, workspaceId: workspaceId) }
        Divider()
        Button(SnoozeChoice.untilUsed.title) { store.snooze(workspaceId, .untilUsed) }
        Button("Until Something Happens…") { WaitCenter.shared.compose(workspaceId: workspaceId, snooze: true) }
    }
}

/// Bottom dock of workspaces out of the way, as T3 Code's sidebar shelves:
/// Snoozed (back by themselves at a time, or when a wait is met) and Idle
/// (unused a while, moved there by hand, or asleep). Each shelf folds
/// under its header; rows are slim, with their actions on hover.
struct IdleDock: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var idle = IdleCenter.shared
    @ObservedObject private var waits = WaitCenter.shared
    @EnvironmentObject private var window: WindowContext
    @AppStorage("octet.idleDock.snoozedCollapsed") private var snoozedCollapsed = false
    /// The old dock's key, so a dock folded before stays folded.
    @AppStorage("octet.idleDock.collapsed") private var idleCollapsed = false

    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 36
    /// Eight rows; past that the dock scrolls, so the active list keeps
    /// the sidebar.
    private static let maxHeight: CGFloat = 8 * 36

    /// Shelves folding and rows moving between them: settled, no overshoot.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        let shelves = self.shelves
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !shelves.snoozed.isEmpty {
                        ShelfHeader(title: "Snoozed", count: shelves.snoozed.count, tone: .info,
                                    help: "Moved out of the way until a time, or until something happens. Each comes back by itself.",
                                    collapsed: $snoozedCollapsed) { _ in EmptyView() }
                        if !snoozedCollapsed {
                            ForEach(shelves.snoozed) { workspace in
                                IdleRow(store: store, workspace: workspace, snoozed: true)
                                    .transition(rowTransition)
                            }
                        }
                    }
                    if !shelves.idle.isEmpty || !idle.sleeping.isEmpty {
                        ShelfHeader(title: "Idle", count: shelves.idle.count + idle.sleeping.count, tone: .muted,
                                    help: "Unused for \(Self.thresholdLabel(store.idleAfter)) or more, or moved here by hand. "
                                        + "Using one brings it back.",
                                    collapsed: $idleCollapsed) { hovered in
                            idleAccessory(hovered: hovered)
                        }
                        if !idleCollapsed {
                            ForEach(shelves.idle) { workspace in
                                IdleRow(store: store, workspace: workspace, snoozed: false)
                                    .transition(rowTransition)
                            }
                            ForEach(idle.sleeping) { record in
                                SleepingRow(record: record).transition(rowTransition)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: min(contentHeight(shelves), Self.maxHeight))
        }
        // On the whole dock, so its height follows the rows: a workspace
        // arriving from the list, waking back to it, or a shelf folding
        // opens or closes the gap together with the row.
        .animation(motion.animation(.sidebar, Self.spring), value: shelves.snoozed.map(\.workspaceId))
        .animation(motion.animation(.sidebar, Self.spring), value: shelves.idle.map(\.workspaceId))
        .animation(motion.animation(.sidebar, Self.spring), value: idle.sleeping.map(\.id))
        .background(Theme.sidebar)
        .clipped()
        .onAppear { idle.refresh() }
    }

    /// Rows come in from above, where the main list is, and leave the same
    /// way, fading as they go; without motion they simply appear.
    private var rowTransition: AnyTransition {
        motion.animates(.sidebar) ? .move(edge: .top).combined(with: .opacity) : .identity
    }

    private var shelves: (snoozed: [EngineWorkspace], idle: [EngineWorkspace]) {
        let all = window.idleWorkspaces
        let held = Set(all.map(\.workspaceId).filter { waits.snooze(of: $0) != nil })
        return IdleShelves.partition(all, wakeTimes: store.snoozedUntil, heldByWait: held)
    }

    private func contentHeight(_ shelves: (snoozed: [EngineWorkspace], idle: [EngineWorkspace])) -> CGFloat {
        var height: CGFloat = 8
        if !shelves.snoozed.isEmpty {
            height += Self.headerHeight + (snoozedCollapsed ? 0 : CGFloat(shelves.snoozed.count) * Self.rowHeight)
        }
        let idleRows = shelves.idle.count + idle.sleeping.count
        if idleRows > 0 {
            height += Self.headerHeight + (idleCollapsed ? 0 : CGFloat(idleRows) * Self.rowHeight)
        }
        return height
    }

    /// How many rows are picked, and the menu for all of Idle; the menu
    /// shows with the pointer on the header, or while rows are picked.
    @ViewBuilder private func idleAccessory(hovered: Bool) -> some View {
        if !idle.selection.isEmpty {
            Text("\(idle.selection.count) picked").font(Theme.captionFont).foregroundStyle(Theme.accent)
        }
        Menu {
            actions
        } label: {
            OctetIcon("ellipsis", size: 12).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.textTertiary)
        .opacity(hovered || !idle.selection.isEmpty ? 1 : 0)
        .help("Close, sleep or stop idle workspaces")
        .accessibilityLabel("Idle actions")
    }

    @ViewBuilder private var actions: some View {
        let all = window.idleWorkspaces
        let picked = all.filter { idle.selection.contains($0.workspaceId) }
        if !picked.isEmpty {
            Button("Close \(picked.count) Picked…") { idle.close(picked) }
            Button("Sleep \(picked.count) Picked") { idle.sleep(picked) }
            Button("Clear Picks") { idle.selection = [] }
            Divider()
        }
        Button("Close All Idle…") { idle.close(all) }
            .disabled(all.isEmpty)
        Button("Sleep All Idle") { idle.sleep(all) }
            .disabled(all.isEmpty)
        let ports = idle.idlePorts
        if !ports.isEmpty {
            Button("Stop \(ports.count == 1 ? "the Server" : "\(ports.count) Servers") in Idle…") { idle.stopIdleServers() }
        }
        if !idle.sleeping.isEmpty {
            Divider()
            Button("Forget \(Recap.count(idle.sleeping.count, "Sleeping Workspace"))…") { idle.confirmForget(idle.sleeping) }
        }
        Divider()
        Text("⌘-click rows to pick several")
    }

    static func thresholdLabel(_ seconds: TimeInterval) -> String {
        seconds >= 86_400 ? "\(Int(seconds / 86_400))d"
            : seconds >= 3600 ? "\(Int(seconds / 3600))h"
            : "\(Int(seconds / 60))m"
    }
}

/// A shelf's header, after T3 Code's: the name and count, a hairline to
/// the edge, and a chevron that turns over when the shelf is folded.
private struct ShelfHeader<Accessory: View>: View {
    enum Tone {
        /// Idle: quiet, like the rest of the sidebar's labels.
        case muted
        /// Snoozed: T3's info blue, since these come back by themselves.
        case info
    }

    let title: String
    let count: Int
    let tone: Tone
    let help: String
    @Binding var collapsed: Bool
    @ViewBuilder var accessory: (_ hovered: Bool) -> Accessory
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    /// T3 dims its muted label to 60%; Octet's tertiary text is already
    /// that quiet and still meets the theme's contrast floor.
    private var label: Color { tone == .info ? Theme.info : Theme.textTertiary }
    private var line: Color { tone == .info ? Theme.info.opacity(0.15) : Theme.border.opacity(0.6) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(Theme.uiFontMedium)
                Text("\(count)").font(Theme.uiFont.monospacedDigit()).opacity(0.7)
            }
            .foregroundStyle(label)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            Rectangle().fill(line).frame(height: 1).frame(maxWidth: .infinity)
            accessory(hovered)
            OctetIcon("chevron.down", size: 12)
                .foregroundStyle(label)
                .rotationEffect(.degrees(collapsed ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: IdleDock.headerHeight)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: toggle)
        .help(help)
    }

    private func toggle() {
        // The rows fold under the header; the header itself, its hairline
        // and count, stay where they are and only the chevron turns.
        motion.perform(.sidebar, IdleDock.spring) { collapsed.toggle() }
    }
}

/// A row's mark, after T3 Code's favicons: grey and faint until the row is
/// under the pointer, so the shelf reads as set aside.
private struct IdleMark: View {
    var image: NSImage?
    var brand: AgentBrand?
    var icon = "terminal"
    let lit: Bool
    /// How faint at rest; a sleeper's moon stays a little clearer.
    var restOpacity = 0.4

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if let brand {
                AgentLogo(brand: brand, size: 12)
            } else {
                OctetIcon(icon, size: 13).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .saturation(lit ? 1 : 0)
        .opacity(lit ? 1 : restOpacity)
        .animation(MotionPreferences.shared.animation(.sidebar, .easeOut(duration: 0.15)), value: lit)
    }
}

/// A word-button in a row's hover actions, like T3's "Wake".
private struct RowTextButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.uiFontMedium)
                .fixedSize()
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.cardSelected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The clock: a menu of how long to snooze for.
private struct SnoozeButton: View {
    @ObservedObject var store: SessionStore
    let workspaceId: String
    let snoozed: Bool

    var body: some View {
        Menu {
            SnoozeMenuItems(store: store, workspaceId: workspaceId)
        } label: {
            OctetIcon("clock", size: 13).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.textSecondary)
        .help(snoozed ? "Snooze for a different time" : "Snooze: back by itself at a time")
        .accessibilityLabel("Snooze")
    }
}

/// An idle or snoozed workspace: its mark, its name, and how long since it
/// was used (or until it comes back), which give way to its actions under
/// the pointer. Click opens it; ⌘-click picks it; double-click renames.
private struct IdleRow: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    let snoozed: Bool
    @ObservedObject private var idle = IdleCenter.shared
    @ObservedObject private var waits = WaitCenter.shared
    @ObservedObject private var icons = WorkspaceIconStore.shared
    @State private var hovered = false
    @State private var renaming = false
    @StateObject private var peek = HoverIntent()

    var body: some View {
        let id = workspace.workspaceId
        let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: id))
        let picked = idle.selection.contains(id)
        let lit = hovered || picked
        HStack(spacing: 10) {
            IdleMark(image: icons.image(for: store.snapshot.directory(ofWorkspace: id)),
                     brand: AgentBrand.forAgent(agent?.agent), lit: lit)
            if renaming {
                InlineRenameField(initial: workspace.label, placeholder: "Workspace name") { label in
                    renaming = false
                    store.renameWorkspace(id, to: label, from: workspace.label)
                }
            } else {
                HStack(spacing: 6) {
                    Text(workspace.label)
                        .font(.system(size: 13))
                        .foregroundStyle(lit ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    if let project = store.projectName(of: id),
                       project.caseInsensitiveCompare(workspace.label) != .orderedSame {
                        Text(project)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                Spacer(minLength: 4)
                // The time and the actions share the row's end and cross-fade.
                ZStack(alignment: .trailing) {
                    if hovered {
                        actions.transition(.opacity)
                    } else {
                        trailing.transition(.opacity)
                    }
                }
                .animation(MotionPreferences.shared.animation(.sidebar, .easeOut(duration: 0.15)), value: hovered)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: IdleDock.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(picked ? Theme.cardSelected : hovered ? Theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(picked ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering
            peek.source(hovering && !renaming)
        }
        #if DEBUG
        // Verification hook: OCTET_IDLE_HOVER="<label>,<label>" draws those
        // rows as though under the pointer, so captures show the actions
        // without moving anyone's mouse.
        .onAppear {
            let labels = (ProcessInfo.processInfo.environment["OCTET_IDLE_HOVER"] ?? "").split(separator: ",").map(String.init)
            if labels.contains(workspace.label) { hovered = true }
        }
        #endif
        .onTapGesture {
            peek.close()
            if NSEvent.modifierFlags.contains(.command) {
                if picked { idle.selection.remove(id) } else { idle.selection.insert(id) }
            } else {
                idle.selection = []
                window.focusWorkspace(id)
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
        .onDrag {
            TabDrag.shared.begin(workspace: id, from: window)
            return NSItemProvider(object: id as NSString)
        }
        .popover(isPresented: $peek.isShown, arrowEdge: .trailing) {
            IdleHoverCard(store: store, workspace: workspace) { peek.close() }
                .onHover { peek.card($0) }
        }
        .octetContextMenu { WorkspaceMenu.items(store: store, workspace: workspace, window: window) { renaming = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    /// At rest: what it still holds, then the time.
    @ViewBuilder private var trailing: some View {
        let id = workspace.workspaceId
        let work = idle.work[id]
        HStack(spacing: 6) {
            if work?.mergedWorktree == true {
                Text("merged").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4).frame(height: 14)
                    .background(Capsule().fill(Theme.cardSelected))
                    .help("A worktree whose branch is merged; its menu can remove it")
            }
            if let port = work?.ports.first {
                Text(":\(String(port))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .help("A server is still listening here")
            }
            if let work, work.uncommitted > 0 || work.unpushed > 0 {
                Circle().fill(Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                    .help(work.risks.map { "Not saved anywhere else: " + $0 } ?? "")
            }
            // Ticks over by the minute, not only when something else changes.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                time(now: context.date)
            }
        }
    }

    @ViewBuilder private func time(now: Date) -> some View {
        let id = workspace.workspaceId
        if let wake = store.snoozedUntil[id] {
            Text(IdleShelves.wakeLabel(wake, now: now))
                .font(Theme.interfaceFont(11.5).monospacedDigit())
                .foregroundStyle(Theme.info)
                .help("Back " + IdleShelves.wakeDescription(wake, now: now))
        } else if let wait = waits.snooze(of: id) {
            OctetIcon("clock", size: 12).foregroundStyle(Theme.info)
                .help("Back when " + (wait.title.isEmpty ? wait.condition.description : wait.title))
        } else {
            Text(WorkspaceActivity.ageLabel(since: store.activity.lastActive(id), now: now))
                .font(Theme.interfaceFont(11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .help("Last used")
        }
    }

    private var actions: some View {
        let id = workspace.workspaceId
        return HStack(spacing: 2) {
            SnoozeButton(store: store, workspaceId: id, snoozed: snoozed)
            if !snoozed {
                OctetIconButton(icon: "moon.zzz", help: "Sleep: close its terminals, and bring it back as it was when woken",
                                compact: true) { idle.sleep([workspace]) }
            }
            RowTextButton(title: "Wake", help: "Back to the list now") { store.keepInView(id) }
            OctetIconButton(icon: "xmark", help: "Close workspace", compact: true) { idle.close([workspace]) }
        }
        // The actions keep their size; the name gives way to them.
        .fixedSize()
    }

    private var accessibilityText: String {
        let id = workspace.workspaceId
        var text = workspace.label
        if let wake = store.snoozedUntil[id] {
            text += ", snoozed, back " + IdleShelves.wakeDescription(wake)
        } else if waits.snooze(of: id) != nil {
            text += ", snoozed until something happens"
        } else {
            let age = WorkspaceActivity.ageLabel(since: store.activity.lastActive(id))
            text += ", idle" + (age.isEmpty ? "" : ", last used \(age) ago")
        }
        if let risks = idle.work[id]?.risks { text += ", holds \(risks)" }
        return text
    }
}

/// What an idle workspace was doing and still holds, on hover, after T3
/// Code's hover card: the name, then a line each for where it is, when it
/// was used, when it comes back and what's unsaved, then what its agent
/// last said, so it needn't be opened to find out.
private struct IdleHoverCard: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    let workspace: EngineWorkspace
    let close: () -> Void
    @ObservedObject private var idle = IdleCenter.shared

    var body: some View {
        let id = workspace.workspaceId
        let work = idle.work[id]
        let sessions = AgentCenter.shared.sessions(in: id)
        let latest = sessions.max { ($0.conversation.items.last?.createdAt ?? .distantPast) < ($1.conversation.items.last?.createdAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 10) {
            Text(workspace.label).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(2)
            VStack(alignment: .leading, spacing: 5) {
                if let directory = store.snapshot.directory(ofWorkspace: id) {
                    meta("folder", HandoffBrief.abbreviate(directory), truncate: .middle)
                }
                if let branch = work?.branch ?? store.branches[id] { meta("branch", branch) }
                let age = WorkspaceActivity.ageLabel(since: store.activity.lastActive(id))
                if !age.isEmpty { meta("clock", age == "now" ? "Used just now" : "Used \(age) ago") }
                if let wake = store.snoozedUntil[id] {
                    meta("clock", "Back " + IdleShelves.wakeDescription(wake), tint: Theme.info)
                } else if let wait = WaitCenter.shared.waits.first(where: { $0.origin.workspaceId == id && $0.state == .waiting }) {
                    meta("clock", (wait.isSnooze ? "Back when " : "Waiting for ") + wait.title, tint: Theme.info)
                }
                if let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: id)), latest == nil {
                    meta("terminal", "\(AgentBrand.forAgent(agent.agent)?.displayName ?? "Agent") · \(agent.agentStatus.rawValue)")
                }
                if let risks = work?.risks {
                    meta("exclamationmark.triangle.fill", "Not saved anywhere else: " + risks, tint: .orange)
                } else if work != nil {
                    meta("checkmark.circle", "Nothing unsaved")
                }
            }
            if let latest, let reply = HandoffBrief.lastReply(in: latest.conversation.items) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(latest.engine.displayName) last said").font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textTertiary)
                    Text(HandoffBrief.clip(reply, 280)).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let files = HandoffBrief.changedFiles(in: latest.conversation.items, cwd: latest.cwd)
                    if !files.isEmpty {
                        Text("Changed " + Recap.count(files.count, "file")).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if let check = Verification.assess(latest.conversation.items).message {
                        Text(check).font(Theme.captionFont).foregroundStyle(Color.orange)
                    }
                }
            }
            if work?.mergedWorktree == true {
                OctetButton(title: "Remove Worktree…", kind: .secondary, compact: true) {
                    close()
                    idle.removeMergedWorktree(workspace, window: window)
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Theme.chrome)
    }

    private func meta(_ icon: String, _ text: String, tint: Color = Theme.textTertiary,
                      truncate: Text.TruncationMode = .tail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            OctetIcon(icon, size: 12).frame(width: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text).font(Theme.uiFont).lineLimit(2).truncationMode(truncate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

/// A workspace put to sleep, in the Idle shelf under its moon: click or
/// Wake to bring it back as it was.
private struct SleepingRow: View {
    @EnvironmentObject private var window: WindowContext
    let record: SleepingWorkspace
    @State private var hovered = false
    /// The moon's brief swell as it falls asleep or wakes.
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            IdleMark(icon: "moon.zzz", lit: hovered || pulse, restOpacity: 0.6)
                .scaleEffect(pulse ? 1.2 : 1)
            Text(record.label)
                .font(.system(size: 13))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                if hovered {
                    HStack(spacing: 2) {
                        RowTextButton(title: "Wake", help: "Open it again as it was, agents resumed") { wake() }
                        OctetIconButton(icon: "xmark", help: "Forget it", compact: true) {
                            IdleCenter.shared.confirmForget([record])
                        }
                    }
                    .fixedSize()
                    .transition(.opacity)
                } else {
                    Text(WorkspaceActivity.ageLabel(since: record.sleptAt))
                        .font(Theme.interfaceFont(11.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .transition(.opacity)
                }
            }
            .animation(MotionPreferences.shared.animation(.sidebar, .easeOut(duration: 0.15)), value: hovered)
        }
        .padding(.horizontal, 10)
        .frame(height: IdleDock.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onAppear {
            #if DEBUG
            let labels = (ProcessInfo.processInfo.environment["OCTET_IDLE_HOVER"] ?? "").split(separator: ",").map(String.init)
            if labels.contains(record.label) { hovered = true }
            #endif
            // Just put to sleep: the moon swells once, so the eye finds
            // where the workspace went.
            if Date().timeIntervalSince(record.sleptAt) < 10 { pulseMoon() }
        }
        .onTapGesture(perform: wake)
        .contextMenu {
            Button("Wake", action: wake)
            Button("Forget…") { IdleCenter.shared.confirmForget([record]) }
        }
        .help("\(record.summary)\n" + HandoffBrief.abbreviate(record.cwd) + (record.branch.map { " on \($0)" } ?? "")
              + "\nAsleep since \(WaitSchedule.dateLabel(record.sleptAt)). Click to wake it as it was.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.label), asleep")
    }

    /// Wakes it after the moon's swell, which is too short to feel like a wait.
    private func wake() {
        let motion = MotionPreferences.shared
        guard motion.animates(.sidebar) else { return IdleCenter.shared.wake(record.id, in: window) }
        pulseMoon()
        let id = record.id
        let window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { IdleCenter.shared.wake(id, in: window) }
    }

    /// Up over 0.15s, back over 0.2s; nothing when motion is off.
    private func pulseMoon() {
        let motion = MotionPreferences.shared
        guard motion.animates(.sidebar) else { return }
        withAnimation(.easeOut(duration: 0.15)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}
