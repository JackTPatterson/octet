import AppKit
import SwiftUI

/// Hovering a workspace in the sidebar shows what's running in it without
/// switching to it, the way Warp's tab hover card does, drawn as the
/// title bar's usage card is: a calm glass card. A header says where it is
/// (the project's icon, its name, folder, branch and what's unsaved), then
/// every tab and conversation with its agent and state, the servers it
/// runs and its pull request, each a click away; the footer has the
/// workspace's own actions.
struct WorkspacePeek: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var agents = AgentCenter.shared
    @ObservedObject private var portsWatcher = PortsWatcher.shared
    @ObservedObject private var workspaceIcons = WorkspaceIconStore.shared
    let workspace: EngineWorkspace
    let dismiss: () -> Void
    /// Verification hook: RootView posts this to open the first workspace's card.
    static let debugOpen = Notification.Name("octet.debug.openWorkspacePeek")
    /// Read when the card opens: what's uncommitted or unpushed, and the
    /// branch's pull request, as the Idle dock and status bar read them.
    @State private var git = PeekGit.cached

    var body: some View {
        let id = workspace.workspaceId
        let snapshot = store.snapshot
        let directory = snapshot.directory(ofWorkspace: id)
        let tabs = snapshot.tabs(inWorkspace: id)
        let conversations = agents.sessions(in: id)
        let ports = portsWatcher.ports(inWorkspace: id, snapshot: snapshot)
        let shownTab = WindowRegistry.shared.window(showing: id)?.displayedFocusedTabId
            ?? (window.focusedWorkspace?.workspaceId == id ? window.displayedFocusedTabId : nil)
        let reading = directory.flatMap { git[$0] }

        VStack(alignment: .leading, spacing: 0) {
            header(directory: directory, reading: reading)
            hairline
            VStack(alignment: .leading, spacing: 1) {
                section("Tabs", count: tabs.count)
                ForEach(tabs) { tab in
                    TabPeekRow(store: store, tab: tab, showing: tab.tabId == shownTab) {
                        dismiss()
                        window.focusTabAnywhere(tab)
                    }
                }
                if !conversations.isEmpty {
                    section("Conversations", count: conversations.count)
                    ForEach(conversations) { session in
                        ConversationPeekRow(session: session) {
                            dismiss()
                            window.focusWorkspace(id)
                            AgentCenter.shared.setActive(session.id, in: id)
                        }
                    }
                }
                if !ports.isEmpty || reading?.pullRequest != nil {
                    section("Running", count: nil)
                    ForEach(ports, id: \.self) { port in
                        PeekLinkRow(icon: "safari", title: "localhost:\(String(port))",
                                    detail: portsWatcher.services[port], help: "Open in your browser") {
                            dismiss()
                            if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                        }
                    }
                    if let pull = reading?.pullRequest {
                        let tone = PullRequestTone(state: pull.state, isDraft: pull.isDraft)
                        PeekLinkRow(icon: tone.icon, tint: tone.color, title: "#\(pull.number) \(pull.title)",
                                    detail: pull.statusText, help: "Show the pull request") {
                            dismiss()
                            window.focusWorkspace(id)
                            MotionPreferences.shared.perform(.sidebar) { window.ui.showPlane(.pullRequest, number: pull.number) }
                        }
                    }
                }
            }
            .padding(6)
            hairline
            footer
        }
        .frame(width: 320, alignment: .leading)
        // The popover is the glass; this is its tint, as AccountCard's.
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Theme.chrome.opacity(0.86))
            }
        }
        .onAppear {
            DebugSnapshot.overlay("peek", true)
            guard let directory else { return }
            PeekGit.read(directory: directory, isWorktree: workspace.worktree != nil) { git = PeekGit.cached }
        }
        .onChange(of: directory) { _, directory in
            guard let directory else { return }
            PeekGit.read(directory: directory, isWorktree: workspace.worktree != nil) { git = PeekGit.cached }
        }
        .onDisappear { DebugSnapshot.overlay("peek", false) }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    // MARK: Header

    private func header(directory: String?, reading: PeekGit.Reading?) -> some View {
        let id = workspace.workspaceId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                projectMark(directory: directory)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(workspace.label)
                            .font(Theme.interfaceFont(13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if store.isPinned(id) {
                            OctetIcon("pin.fill", size: 10).foregroundStyle(Theme.textMuted)
                                .help("Pinned: never moves to Idle")
                        }
                    }
                    if let directory, abbreviateHome(directory) != workspace.label {
                        Text(abbreviateHome(directory))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(directory)
                    }
                }
                Spacer(minLength: 6)
                // Ticks over by the minute while the card is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let age = WorkspaceActivity.ageLabel(since: store.activity.lastActive(id), now: context.date)
                    if !age.isEmpty {
                        Text(age == "now" ? "now" : "\(age) ago")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .help("Last active")
                    }
                }
            }
            let branch = reading?.work.branch ?? store.branches[id]
            if branch != nil || (reading?.work.uncommitted ?? 0) > 0 || (reading?.work.unpushed ?? 0) > 0 {
                HStack(spacing: 6) {
                    if let branch {
                        PeekChip(icon: workspace.worktree != nil ? "square.stack.3d.up" : "branch", text: branch, mono: true)
                            .help(workspace.worktree != nil ? "Worktree on \(branch)" : "Branch \(branch)")
                    }
                    if let work = reading?.work {
                        if work.uncommitted > 0 {
                            PeekChip(dot: .orange, text: Recap.count(work.uncommitted, "change"))
                                .help(Recap.count(work.uncommitted, "uncommitted file"))
                        }
                        if work.unpushed > 0 {
                            PeekChip(icon: "arrow.up", text: "\(work.unpushed)")
                                .help(Recap.count(work.unpushed, "unpushed commit"))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// The project's favicon or app icon when a plugin has one, else a
    /// folder in a quiet tile.
    @ViewBuilder
    private func projectMark(directory: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        if let image = workspaceIcons.image(for: directory) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 32, height: 32)
                .background(shape.fill(Theme.card))
                .overlay(shape.strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
        } else {
            OctetIcon("folder", size: 15)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(shape.fill(Theme.card))
                .overlay(shape.strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
        }
    }

    private func section(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(Theme.headerFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    // MARK: Footer

    /// The workspace's own actions, the same ones its context menu has.
    private var footer: some View {
        let id = workspace.workspaceId
        let pinned = store.isPinned(id)
        return HStack(spacing: 4) {
            OctetButton(title: "Open", icon: "arrow.right", kind: .primary, compact: true) {
                dismiss()
                HoverIntent.navigating = true
                window.focusWorkspace(id)
            }
            .help("Switch to this workspace")
            Spacer(minLength: 8)
            OctetIconButton(icon: pinned ? "pin.slash" : "pin", help: pinned ? "Unpin" : "Pin to keep in view",
                            compact: true) {
                store.setPinned(id, !pinned)
            }
            OctetIconButton(icon: "moon.zzz", help: "Move to Idle", compact: true) {
                dismiss()
                store.markIdle(id)
            }
            OctetIconButton(icon: "xmark", help: "Close workspace", compact: true) {
                dismiss()
                store.closeWorkspace(id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card.opacity(0.35))
    }
}

/// A small capsule in the header: the branch, what's unsaved.
private struct PeekChip: View {
    var icon: String?
    var dot: Color?
    let text: String
    var mono = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { OctetIcon(icon, size: 10) }
            if let dot { Circle().fill(dot.opacity(0.85)).frame(width: 6, height: 6) }
            Text(text)
                .font(mono ? .system(size: 10.5, design: .monospaced) : Theme.captionFont.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
    }
}

/// A terminal tab: its name, the agent running in it and what that agent is
/// doing. A tab with several agents (a split, or subagent viewers) lists
/// how many.
private struct TabPeekRow: View {
    @ObservedObject var store: SessionStore
    let tab: EngineTab
    let showing: Bool
    let action: () -> Void

    var body: some View {
        let running = store.snapshot.agents(inTab: tab.tabId)
        let agent = store.primaryAgent(in: running)
        let brand = AgentBrand.forAgent(agent?.agent)
        let status = agent?.agentStatus ?? tab.agentStatus
        PeekRow(status: status, action: action) {
            if let brand { AgentLogo(brand: brand, size: 14) } else {
                OctetIcon("terminal", size: 13).foregroundStyle(Theme.textTertiary)
            }
        } title: {
            TabAutoName.display(label: tab.label, number: tab.number)
        } detail: {
            detail(agent: agent, brand: brand, count: running.count,
                   location: agent.flatMap { store.agentLocations[$0.paneId] })
        } trailing: {
            if showing {
                Text("Showing")
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.card))
            }
        }
    }

    private func detail(agent: EngineAgent?, brand: AgentBrand?, count: Int, location: AgentLocation?) -> String {
        var parts: [String] = []
        if let agent, let brand {
            let state = stateLabel(agent.agentStatus)
            parts.append(state.isEmpty ? brand.displayName : "\(brand.displayName) \(state)")
        } else {
            parts.append("Shell")
        }
        if let location { parts.append("in \(location.phrase)") }
        if count > 1 { parts.append("\(count) agents") }
        if tab.paneCount > 1 { parts.append("\(tab.paneCount) panes") }
        return parts.joined(separator: " · ")
    }
}

/// A native conversation, whether it's working, waiting on you, or done,
/// and when it last said anything.
private struct ConversationPeekRow: View {
    @ObservedObject var session: AgentSession
    let action: () -> Void

    var body: some View {
        let status: EngineAgentStatus = session.pendingPermission != nil ? .blocked
            : session.conversation.isRunning ? .working : .idle
        PeekRow(status: status, action: action) {
            if let brand = AgentBrand.forAgent(session.engine.agent) { AgentLogo(brand: brand, size: 14) }
        } title: {
            session.title
        } detail: {
            detail(status)
        } trailing: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age = WorkspaceActivity.ageLabel(since: session.conversation.items.last?.createdAt, now: context.date)
                if !age.isEmpty, status != .working {
                    Text(age)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .help("Last activity")
                }
            }
        }
    }

    private func detail(_ status: EngineAgentStatus) -> String {
        switch status {
        case .blocked: return "Needs your approval"
        case .working:
            guard let started = session.turnStartedAt else { return "Working" }
            let seconds = Int(Date().timeIntervalSince(started))
            return seconds < 60 ? "Working \(seconds)s" : "Working \(seconds / 60)m \(seconds % 60)s"
        default: return "\(session.engine.displayName) · idle"
        }
    }
}

/// The shared row: the agent's mark with its state on the corner, the
/// title over a detail line, and something on the right.
private struct PeekRow<Mark: View, Trailing: View>: View {
    let status: EngineAgentStatus
    let action: () -> Void
    @ViewBuilder let mark: () -> Mark
    let title: () -> String
    let detail: () -> String
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                mark()
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card.opacity(0.7)))
                    .overlay(alignment: .bottomTrailing) {
                        if status != .unknown {
                            AgentStateGlyph(status: status, size: 8)
                                .frame(width: 12, height: 12)
                                .background(Circle().fill(Theme.chrome))
                                .offset(x: 3, y: 3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title())
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(detail())
                        .font(Theme.captionFont)
                        .foregroundStyle(status == .blocked ? Color(hex: AgentStateColor.blocked) : Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
    }
}

/// A server or pull request: an icon, a title and a quiet detail.
private struct PeekLinkRow: View {
    let icon: String
    var tint: Color?
    let title: String
    var detail: String?
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                OctetIcon(icon, size: 13)
                    .foregroundStyle(tint ?? Theme.textSecondary)
                    .frame(width: 26)
                Text(title)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                OctetIcon("arrow.up.right", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// What the peek knows about a workspace's repository beyond its branch:
/// what's uncommitted or unpushed (`IdleWork`, as the Idle dock reads it)
/// and the branch's pull request (`gh`, as the status bar reads it, and only
/// when the status bar's pull request item is on). Read off the main thread
/// when a card opens and kept a minute by folder, so hovering back and forth
/// doesn't run git and gh each time.
@MainActor
enum PeekGit {
    struct Reading: Equatable {
        var work: IdleWork
        var pullRequest: GitHubPullRequest?
        var readAt: Date
    }

    private(set) static var cached: [String: Reading] = [:]
    private static var reading: Set<String> = []

    static func read(directory: String, isWorktree: Bool, then: @escaping @MainActor () -> Void) {
        if let last = cached[directory], Date().timeIntervalSince(last.readAt) < 60 { return then() }
        guard !reading.contains(directory) else { return }
        reading.insert(directory)
        let askGitHub = OctetPluginHost.shared.statusBarOrder.contains("builtin.pullRequest")
        let previous = cached[directory]?.pullRequest
        DispatchQueue.global(qos: .utility).async {
            let work = IdleWork.read(directory: directory, ports: [], isWorktree: isWorktree)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cached[directory] = Reading(work: work, pullRequest: previous, readAt: Date())
                    if !askGitHub { reading.remove(directory) }
                    then()
                }
            }
            guard askGitHub, work.branch != nil else {
                if askGitHub { DispatchQueue.main.async { MainActor.assumeIsolated { _ = reading.remove(directory) } } }
                return
            }
            let result = LoginShell.run(["gh", "pr", "view", "--json",
                                         "number,title,state,url,isDraft,reviewDecision,statusCheckRollup"], in: directory)
            let value = result.status == 0 ? GitHubPullRequest.parse(Data(result.output.utf8)) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    reading.remove(directory)
                    // A failed call (offline, signed out) keeps the last answer;
                    // a successful empty one means the branch has no PR.
                    let next = result.status == 0 ? value : (result.output.contains("no pull requests") ? nil : previous)
                    cached[directory]?.pullRequest = next
                    then()
                }
            }
        }
    }
}

/// Waits before showing a hover card, and a moment before hiding it so the
/// pointer can cross from the row into it: hover intent, as menus do. Once
/// the pointer is in the card, the card stays until it leaves.
@MainActor
final class HoverIntent: ObservableObject {
    @Published var isShown = false
    private var overSource = false
    private var overCard = false
    private var pending: DispatchWorkItem?

    /// Set by a click on a workspace, cleared when the pointer leaves the
    /// sidebar. While someone is clicking between workspaces a peek only gets
    /// in the way: an open popover takes the next click just to close itself,
    /// so the workspace clicked next doesn't switch.
    static var navigating = false

    func source(_ hovering: Bool) {
        overSource = hovering && !Self.navigating
        // Leaving the row: long enough to cross the gap to the card's edge.
        schedule(hovering && !isShown ? 0.5 : 0.3)
    }

    func card(_ hovering: Bool) {
        overCard = hovering
        // In the card it shows at once (and stays); out of it, the same
        // grace as leaving the row, in case the pointer is heading back.
        schedule(hovering ? 0 : 0.3)
    }

    /// Opens it now, for the DEBUG verification hook.
    func show() {
        pending?.cancel()
        overCard = true
        isShown = true
    }

    func close() {
        pending?.cancel()
        overSource = false
        overCard = false
        isShown = false
    }

    private func schedule(_ delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let want = self.overSource || self.overCard
            if want != self.isShown { self.isShown = want }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
