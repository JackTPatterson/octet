import SwiftUI

/// Git as the agents in front use it: each checkout they work in, with who
/// is in it, what they changed, the commits and checkpoints they made along
/// the way, and the chores worth handing back to them as a prompt. Below,
/// every worktree of the repository and whoever is working there.
struct GitPanel: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject var ui: UIState
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if model.groups.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.groups) { group in
                            CheckoutSection(model: model, group: group)
                        }
                        if model.worktrees.count > 1, let top = model.groups.first?.checkout.top {
                            WorktreeMap(model: model, top: top, current: Set(model.groups.map(\.checkout.top)))
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.sidebar)
        .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: model.groups)
        .onChange(of: ui.gitPanelVisible) { _, visible in if visible { model.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("Git").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if let branch = model.groups.first?.checkout.branch.name {
                Text(branch)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { ui.gitPanelVisible = false } label: {
                OctetIcon("xmark", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close the git panel")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.tabBarHeight)
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 8) {
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Text("Not in a repository")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("When the agent in this tab, or a subagent it started, works in a git repository, its changes, commits and worktrees show here.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One checkout

private struct CheckoutSection: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group

    private var checkout: AgentGit.Checkout { group.checkout }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            let offered = AgentGitHandoff.offered(for: checkout)
            if !offered.isEmpty, group.workers.contains(where: \.takesPrompts) {
                HandoffRow(handoffs: offered) { model.handoff($0, in: group) }
            }
            if !checkout.files.isEmpty { changes }
            timeline
        }
    }

    /// Who's here, where, and how the branch stands.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                WorkerMarks(workers: group.workers) { model.show($0) }
                Text(workersLabel)
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if checkout.isLinkedWorktree {
                    Text("worktree")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Theme.card))
                }
            }
            HStack(spacing: 5) {
                OctetIcon("arrow.triangle.branch", size: 11).foregroundStyle(Theme.textTertiary)
                Text(checkout.branch.name ?? "detached HEAD")
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                BaseStanding(checkout: checkout)
            }
            Text(abbreviateHome(checkout.top))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !checkout.operation.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                    Text(checkout.operation.label).font(Theme.captionFont.weight(.medium))
                }
                .foregroundStyle(Theme.danger)
            }
        }
    }

    private var workersLabel: String {
        let leads = group.workers.filter { !$0.isSubagent }
        let subagents = group.workers.count - leads.count
        let lead = leads.first?.name ?? group.workers.first?.name ?? "Here"
        switch subagents {
        case 0: return leads.count > 1 ? "\(lead) + \(leads.count - 1)" : lead
        case 1: return "\(lead) · 1 subagent"
        default: return "\(lead) · \(subagents) subagents"
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SectionTitle(title: "Changes", count: checkout.files.count)
                LineCounts(added: checkout.added, removed: checkout.removed)
                Spacer()
                Button("Review") { model.review(checkout.top) }
                    .buttonStyle(.plain)
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .help("Open the changes review (⌘⇧R)")
            }
            VStack(spacing: 1) {
                ForEach(checkout.files.prefix(200)) { file in
                    FileRow(file: file,
                            open: { model.review(checkout.top, path: file.path) },
                            toggleStaged: { model.toggleStaged(file, in: checkout.top) },
                            discard: { model.discard(file, in: checkout.top) })
                }
            }
            if checkout.files.count > 200 {
                Text("and \(checkout.files.count - 200) more")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Commits on this branch and the checkpoints taken as agents started
    /// their turns, newest first, in one line of events.
    @ViewBuilder
    private var timeline: some View {
        let events = TimelineEvent.merge(commits: checkout.commits, checkpoints: checkout.checkpoints)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: checkout.onBase || checkout.base == nil ? "Recent" : "On this branch",
                             count: checkout.commits.count)
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
            }
        }
    }
}

/// Ahead of and behind the default branch, compactly.
private struct BaseStanding: View {
    let checkout: AgentGit.Checkout

    var body: some View {
        if let base = checkout.base, !checkout.onBase {
            HStack(spacing: 4) {
                if checkout.aheadOfBase > 0 { count("arrow.up", checkout.aheadOfBase) }
                if checkout.behindBase > 0 { count("arrow.down", checkout.behindBase) }
                if checkout.aheadOfBase == 0 && checkout.behindBase == 0 {
                    Text("even").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .help("\(checkout.aheadOfBase) ahead of \(base), \(checkout.behindBase) behind")
        } else if checkout.branch.ahead > 0 || checkout.branch.behind > 0 {
            HStack(spacing: 4) {
                if checkout.branch.ahead > 0 { count("arrow.up", checkout.branch.ahead) }
                if checkout.branch.behind > 0 { count("arrow.down", checkout.branch.behind) }
            }
            .help("Against \(checkout.branch.upstream ?? "its upstream")")
        }
    }

    private func count(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 1) {
            OctetIcon(icon, size: 9)
            Text("\(value)").font(Theme.captionFont.monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
    }
}

private struct HandoffRow: View {
    let handoffs: [AgentGitHandoff]
    let send: (AgentGitHandoff) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(handoffs) { handoff in
                HandoffChip(handoff: handoff) { send(handoff) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A chore sent to the agent as a prompt, shown as what you'd ask it.
private struct HandoffChip: View {
    let handoff: AgentGitHandoff
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                OctetIcon("sparkles", size: 10)
                Text(handoff.title).font(Theme.captionFont.weight(.medium))
            }
            .foregroundStyle(handoff == .resolveConflicts ? Theme.danger : Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.cardSelected : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Ask the agent to \(handoff.title.lowercased())")
    }
}

private struct FileRow: View {
    let file: AgentGit.FileChange
    let open: () -> Void
    let toggleStaged: () -> Void
    let discard: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 10)
            Text((file.path as NSString).lastPathComponent)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            let folder = (file.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hovered {
                rowButton(file.staged ? "checkmark.square.fill" : "square",
                          help: file.staged ? "Unstage" : "Stage", action: toggleStaged)
                if file.kind != .conflicted {
                    rowButton("arrow.uturn.backward", help: "Discard changes", action: discard)
                }
            } else {
                if file.staged {
                    OctetIcon("checkmark", size: 10).foregroundStyle(Theme.textTertiary).help("Staged")
                }
                LineCounts(added: file.added, removed: file.removed)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .help(file.path)
        .contextMenu {
            Button("Review Changes", action: open)
            Button(file.staged ? "Unstage" : "Stage", action: toggleStaged)
            if file.kind != .conflicted { Button("Discard Changes…", action: discard) }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    private func rowButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var letter: String {
        switch file.kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    private var color: Color {
        switch file.kind {
        case .added, .untracked: Color(hex: AgentStateColor.done)
        case .deleted, .conflicted: Theme.danger
        case .modified, .renamed: Color(hex: "E0AF68")
        }
    }
}

private struct LineCounts: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        HStack(spacing: 4) {
            if let added, added > 0 {
                Text("+\(added)").foregroundStyle(Color(hex: AgentStateColor.done))
            }
            if let removed, removed > 0 {
                Text("−\(removed)").foregroundStyle(Theme.danger)
            }
        }
        .font(Theme.captionFont.monospacedDigit())
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
            if count > 0 {
                Text("\(count)").font(Theme.headerFont.monospacedDigit()).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// The agents' marks, overlapping; a click brings that agent's tab forward.
private struct WorkerMarks: View {
    let workers: [GitPanelModel.Worker]
    let show: (GitPanelModel.Worker) -> Void

    var body: some View {
        HStack(spacing: -3) {
            ForEach(workers.prefix(4)) { worker in
                Button { show(worker) } label: {
                    Group {
                        if let brand = AgentBrand.forAgent(worker.agent) {
                            if worker.isSubagent {
                                OctetIcon("tool.agent", size: 11)
                                    .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? Theme.textSecondary)
                            } else {
                                AgentLogo(brand: brand, size: 12)
                            }
                        } else {
                            OctetIcon("terminal", size: 11).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.sidebar))
                }
                .buttonStyle(.plain)
                .help("\(worker.name) — show its tab")
            }
        }
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
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Worktrees", count: model.worktrees.count)
            VStack(spacing: 1) {
                ForEach(model.worktrees) { worktree in
                    WorktreeRow(model: model, worktree: worktree, top: top,
                                workers: model.worktreeWorkers[worktree.path] ?? [],
                                isHere: current.contains(worktree.path))
                }
            }
        }
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

/// The tab bar's Git button, with how many files the agents have changed.
struct GitPanelButton: View {
    @ObservedObject var model: GitPanelModel
    @Binding var isShowing: Bool
    @State private var hovered = false

    var body: some View {
        if model.hasRepository || isShowing {
            Button { isShowing.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Git").font(Theme.uiFontMedium)
                    if isShowing, model.changedFiles > 0 {
                        Text("\(model.changedFiles)")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .foregroundStyle(isShowing ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(isShowing ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Show the agents' git: changes, commits, checkpoints and worktrees")
            .accessibilityLabel(isShowing ? "Hide git panel" : "Show git panel")
        }
    }
}
