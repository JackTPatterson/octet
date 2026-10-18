import SwiftUI

/// Git as the agents in front use it: each checkout they work in, with who
/// is in it, what they changed, the commits and checkpoints they made along
/// the way, and the chores worth handing back to them as a prompt. Below,
/// every worktree of the repository and whoever is working there.
///
/// With one checkout, which is nearly always, its header and the commit box
/// stay put while the rest scrolls between them.
struct GitPanel: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var ui: UIState
    @ObservedObject private var motion = MotionPreferences.shared

    /// Whether the Git page is in front, which is when the model reads.
    private var showing: Bool { ui.showing(.git) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: model.groups)
            .onChange(of: showing, initial: true) { _, visible in if visible { model.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.count == 1, let group = model.groups.first {
            pinned(group)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.groups.isEmpty {
                        empty
                    } else {
                        ForEach(model.groups) { group in
                            CheckoutSection(model: model, group: group, inline: true)
                        }
                        worktrees
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .id(SidePanelSection.files)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// One checkout: header on top, commit box at the bottom, the rest between.
    private func pinned(_ group: GitPanelModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GitHeader(model: model, group: group)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CheckoutSection(model: model, group: group, inline: false)
                    worktrees
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .id(SidePanelSection.files)
            }
            .scrollIndicators(.hidden)
            if !group.checkout.files.isEmpty {
                GitCommitBar(model: model, group: group)
                    .padding(12)
                    .background(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
        }
    }

    @ViewBuilder
    private var worktrees: some View {
        if GitSectionPlan.showWorktrees(count: model.worktrees.count), let top = model.groups.first?.checkout.top {
            OctetCollapsible(title: "Worktrees", open: model.sectionBinding("worktrees"), trailing: {
                CountBadge(count: model.worktrees.count)
            }) {
                WorktreeMap(model: model, top: top, current: Set(model.groups.map(\.checkout.top)))
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if model.loading {
            LoadingLine(width: 18)
        } else {
            Text("Not in a repository. When the agent in this tab, or a subagent it started, works in a git repository, its changes, commits and worktrees show here.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small count in a pill, beside a section's title.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(Theme.card))
    }
}

// MARK: - One checkout

private struct CheckoutSection: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group
    /// Draws the header and commit box too, for when several checkouts share
    /// the scroll; otherwise the panel pins them.
    let inline: Bool
    /// Whose edits the changes list shows: nil for everyone's.
    @State private var filter: EditorFilter?

    private var checkout: AgentGit.Checkout { group.checkout }

    /// The changes the filter lets through.
    private var shownFiles: [AgentGit.FileChange] {
        switch filter {
        case nil: checkout.files
        case .some(.worker(let id)): checkout.files.filter { group.editors[$0.path]?.contains { $0.paneId == id } == true }
        case .some(.unattributed): checkout.files.filter { group.editors[$0.path] == nil }
        }
    }

    var body: some View {
        let plan = GitSectionPlan(checkout: checkout, promptable: group.workers.contains(where: \.takesPrompts),
                                  hasEditors: !group.allEditors.isEmpty)
        VStack(alignment: .leading, spacing: 8) {
            if inline { GitHeader(model: model, group: group) }
            if plan.showChanges {
                if plan.showFilter {
                    EditorFilterRow(editors: group.allEditors, group: group, filter: $filter)
                }
                GitChangesList(model: model, group: group, files: shownFiles)
                if inline { GitCommitBar(model: model, group: group) }
            }
            VStack(alignment: .leading, spacing: 0) {
                if plan.showHandoff { handoff }
                if plan.showHistory { timeline }
            }
        }
    }

    /// Chores worth asking the agent for, folded away until wanted.
    private var handoff: some View {
        let offered = AgentGitHandoff.offered(for: checkout)
        // Filtered to one agent's edits, Commit commits just those.
        let only = filter == nil ? nil : shownFiles.map(\.path)
        return OctetCollapsible(title: "Ask Agent", open: model.sectionBinding("handoff"), trailing: {
            CountBadge(count: offered.count)
        }) {
            HandoffRow(handoffs: offered, scoped: only != nil) { model.handoff($0, in: group, only: only) }
                .padding(.bottom, 6)
        }
    }

    /// Commits on this branch and the checkpoints taken as agents started
    /// their turns, newest first, in one line of events.
    @ViewBuilder
    private var timeline: some View {
        let events = TimelineEvent.merge(commits: checkout.commits, checkpoints: checkout.checkpoints)
        if !events.isEmpty {
            OctetCollapsible(title: checkout.onBase || checkout.base == nil ? "Recent" : "On this branch",
                             open: model.sectionBinding("history"), trailing: {
                CountBadge(count: checkout.commits.count)
            }) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.prefix(30).enumerated()), id: \.element.id) { index, event in
                        TimelineRow(event: event, isLast: index == min(events.count, 30) - 1,
                                    open: {
                                        if case .commit(let commit) = event { model.review(checkout.top, since: commit) }
                                    },
                                    restore: {
                                        if case .checkpoint(let checkpoint) = event { model.restore(checkpoint, in: checkout.top) }
                                    })
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}

private struct HandoffRow: View {
    let handoffs: [AgentGitHandoff]
    /// The changes list is filtered, and Commit takes only what it shows.
    var scoped = false
    let send: (AgentGitHandoff) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(handoffs) { handoff in
                HandoffChip(handoff: handoff, title: scoped && handoff == .commit ? "Commit These" : handoff.title) {
                    send(handoff)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A chore sent to the agent as a prompt, shown as what you'd ask it.
private struct HandoffChip: View {
    let handoff: AgentGitHandoff
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                OctetIcon("sparkles", size: 10)
                Text(title).font(Theme.captionFont.weight(.medium))
            }
            .foregroundStyle(handoff == .resolveConflicts ? Theme.danger : Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.cardSelected : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Ask the agent to \(title.lowercased())")
    }
}
// MARK: - Timeline

private enum TimelineEvent: Identifiable {
    case commit(AgentGit.Commit)
    case checkpoint(Checkpoint)

    var id: String {
        switch self {
        case .commit(let commit): "commit:\(commit.sha)"
        case .checkpoint(let checkpoint): "checkpoint:\(checkpoint.ref)"
        }
    }

    var date: Date {
        switch self {
        case .commit(let commit): commit.date
        case .checkpoint(let checkpoint): checkpoint.date
        }
    }

    /// Checkpoints older than the branch's oldest commit belong to earlier
    /// work, so on a branch they're left out.
    static func merge(commits: [AgentGit.Commit], checkpoints: [Checkpoint]) -> [TimelineEvent] {
        let oldest = commits.map(\.date).min()
        let relevant = checkpoints.filter { checkpoint in oldest.map { checkpoint.date >= $0 } ?? true }
        return (commits.map(TimelineEvent.commit) + relevant.map(TimelineEvent.checkpoint)).sorted { $0.date > $1.date }
    }
}

private struct TimelineRow: View {
    let event: TimelineEvent
    let isLast: Bool
    let open: () -> Void
    let restore: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // A rail with a mark for each event.
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle().fill(Theme.divider).frame(width: 1).padding(.top, 10)
                }
                mark.padding(.top, 5)
            }
            .frame(width: 10)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.uiFont)
                    .foregroundStyle(isCheckpoint ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(2)
                Text(detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                Button(isCheckpoint ? "Restore" : "Review", action: isCheckpoint ? restore : open)
                    .buttonStyle(.plain)
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if !isCheckpoint { open() } }
        .help(help)
    }

    private var isCheckpoint: Bool {
        if case .checkpoint = event { return true }
        return false
    }

    @ViewBuilder
    private var mark: some View {
        if isCheckpoint {
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        } else {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
        }
    }

    private var title: String {
        switch event {
        case .commit(let commit): commit.subject
        case .checkpoint(let checkpoint): "Checkpoint · \(checkpoint.label)"
        }
    }

    private var detail: String {
        switch event {
        case .commit(let commit): "\(commit.shortSha) · \(commit.author) · \(UsageMeter.relative(commit.date))"
        case .checkpoint(let checkpoint): "Before a turn · \(UsageMeter.relative(checkpoint.date))"
        }
    }

    private var help: String {
        switch event {
        case .commit: "Review what changed from this commit on"
        case .checkpoint: "The files as they were when this turn began; Restore puts them back (undoable)"
        }
    }
}

// MARK: - Worktrees

/// Every worktree of the repository, with the agents in each and how far
/// each branch has gone from the default one.
private struct WorktreeMap: View {
    @ObservedObject var model: GitPanelModel
    let top: String
    /// Checkouts already shown above.
    let current: Set<String>

    var body: some View {
        VStack(spacing: 1) {
            ForEach(model.worktrees) { worktree in
                WorktreeRow(model: model, worktree: worktree, top: top,
                            workers: model.worktreeWorkers[worktree.path] ?? [],
                            isHere: current.contains(worktree.path))
            }
        }
        .padding(.bottom, 6)
    }
}

private struct WorktreeRow: View {
    @ObservedObject var model: GitPanelModel
    let worktree: AgentGit.Worktree
    let top: String
    let workers: [GitPanelModel.Worker]
    let isHere: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            OctetIcon(worktree.isMain ? "folder" : "arrow.triangle.branch", size: 11)
                .foregroundStyle(isHere ? Theme.textPrimary : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.branch ?? (worktree.path as NSString).lastPathComponent)
                    .font(Theme.uiFont.weight(isHere ? .medium : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(state)
                    .font(Theme.captionFont)
                    .foregroundStyle(worktree.dirty ? Color(hex: "E0AF68") : Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                if worktree.removable {
                    action("Clean Up") { model.cleanUp(worktree, from: top) }
                } else if !worktree.isMain, !worktree.merged, worktree.aheadOfBase > 0 {
                    action("Merge") { model.merge(worktree) }
                }
            } else if !workers.isEmpty {
                WorkerMarks(workers: workers) { model.show($0) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.review(worktree.path) }
        .help(abbreviateHome(worktree.path))
        .contextMenu {
            Button("Review Changes") { model.review(worktree.path) }
            if let worker = workers.first { Button("Show \(worker.name)'s Tab") { model.show(worker) } }
            if !worktree.isMain, !worktree.merged { Button("Ask the Agent to Merge") { model.merge(worktree) } }
            if worktree.removable { Button("Clean Up…") { model.cleanUp(worktree, from: top) } }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
        }
    }

    private var state: String {
        var parts: [String] = []
        if worktree.isMain { parts.append("main checkout") }
        if worktree.merged { parts.append("merged") }
        if worktree.aheadOfBase > 0 { parts.append("\(worktree.aheadOfBase) ahead") }
        if worktree.behindBase > 0 { parts.append("\(worktree.behindBase) behind") }
        if worktree.dirty { parts.append("uncommitted changes") }
        if parts.isEmpty { parts.append("clean") }
        return parts.joined(separator: " · ")
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(Theme.captionFont.weight(.medium))
            .foregroundStyle(Theme.accent)
    }
}
