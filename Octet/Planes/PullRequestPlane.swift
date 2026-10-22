import AppKit
import SwiftUI

/// One pull request, in full, after T3 Code's pull request panel: what it
/// is and where it's going at the top, then its summary, timeline and code.
/// `number == nil` means the PR for the branch checked out in `directory`,
/// and the plane follows the branch as it changes.
struct PullRequestPlane: View {
    let directory: String
    let number: Int?
    /// "owner/name" for a PR outside `directory`'s repository (the Pull
    /// Requests page); nil is the folder's own, as the panel uses it.
    let repo: String?
    /// Sends a prompt to the agent in front.
    let askAgent: (String) -> Void
    /// Number, tone and title, for the tab chip.
    let onSummary: (Int, PullRequestTone, String) -> Void
    /// Whether the plane is in front; it polls gh only then.
    var visible = true
    /// Back to the list it was opened from, shown at the start of the top
    /// row; nil when there's nowhere to go back to.
    var back: (() -> Void)?
    @StateObject private var model: PullRequestPlaneModel

    init(directory: String, number: Int?, repo: String? = nil, visible: Bool = true,
         back: (() -> Void)? = nil,
         askAgent: @escaping (String) -> Void,
         onSummary: @escaping (Int, PullRequestTone, String) -> Void) {
        self.directory = directory
        self.visible = visible
        self.back = back
        self.number = number
        self.repo = repo
        self.askAgent = askAgent
        self.onSummary = onSummary
        _model = StateObject(wrappedValue: PullRequestPlaneModel(directory: directory, number: number, repo: repo))
    }

    var body: some View {
        Group {
            switch PlaneLoadingPreview.shows("pullRequest") ? .loading : model.phase {
            case .loading:
                VStack(spacing: 0) {
                    backRow
                    PullRequestSkeleton()
                }
            case .failed(let failure):
                VStack(spacing: 0) {
                    backRow
                    PullRequestFailureView(failure: failure, model: model, askAgent: askAgent)
                }
            case .loaded:
                if let detail = model.detail {
                    PullRequestContent(model: model, detail: detail, askAgent: askAgent)
                } else {
                    PullRequestSkeleton()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .environment(\.pullRequestBack, back.map(PullRequestBackAction.init))
        .pollWhileSeen(visible, start: model.start, stop: model.stop)
        .onChange(of: number) { _, new in model.retarget(new) }
        .onReceive(model.$detail) { detail in
            guard let detail else { return }
            onSummary(detail.number, detail.tone, detail.title)
        }
    }

    /// Before the PR has loaded, the way back sits on its own.
    @ViewBuilder private var backRow: some View {
        if let back {
            HStack {
                PullRequestBackButton(action: back)
                Spacer()
            }
            .padding(.horizontal, PullRequestStyle.horizontalPadding)
            .padding(.top, 8)
        }
    }
}

/// The way back to the list a pull request was opened from.
struct PullRequestBackAction {
    let perform: () -> Void
}

private struct PullRequestBackKey: EnvironmentKey {
    static let defaultValue: PullRequestBackAction? = nil
}

extension EnvironmentValues {
    var pullRequestBack: PullRequestBackAction? {
        get { self[PullRequestBackKey.self] }
        set { self[PullRequestBackKey.self] = newValue }
    }
}

struct PullRequestBackButton: View {
    let action: () -> Void

    var body: some View {
        OctetIconButton(icon: "chevron.left", help: "All pull requests", compact: true, action: action)
    }
}

// MARK: - Tones

extension PullRequestTone {
    /// GitHub's colours for a PR's state, with Octet's green and red.
    var color: Color {
        switch self {
        case .open: Theme.success
        case .draft: Theme.textTertiary
        case .closed: Theme.danger
        case .merged: PullRequestStyle.violet
        }
    }

    var icon: String {
        switch self {
        case .merged: "merge"
        case .closed: "circle.x"
        case .open, .draft: "pull.request"
        }
    }
}

enum PullRequestStyle {
    static let violet = Color(hex: "a371f7")
    static var amber: Color { Theme.warning }
    static let horizontalPadding: CGFloat = 16

    static func checksColor(_ tone: PullRequestChecksSummary.Tone) -> Color {
        switch tone {
        case .passing: Theme.success
        case .failing: Theme.danger
        case .pending: amber
        case .none, .mixed: Theme.textTertiary
        }
    }

    static func checksIcon(_ tone: PullRequestChecksSummary.Tone) -> String {
        switch tone {
        case .passing: "circle.check"
        case .failing: "circle.x"
        case .pending: "circle.dot"
        case .none, .mixed: "circle.dot"
        }
    }

    static func checkColor(_ state: PullRequestCheck.State) -> Color {
        switch state {
        case .passed: Theme.success
        case .failed, .cancelled: Theme.danger
        case .running: amber
        case .skipped, .neutral: Theme.textTertiary
        }
    }

    static func checkIcon(_ state: PullRequestCheck.State) -> String {
        switch state {
        case .passed: "circle.check"
        case .failed, .cancelled: "circle.x"
        case .running: "circle.dot"
        case .skipped, .neutral: "minus"
        }
    }

    static func verdictColor(_ verdict: PullRequestDetail.Verdict?) -> Color {
        switch verdict {
        case .approved: Theme.success
        case .changesRequested: Theme.danger
        case .none, .pending: amber
        case .commented, .dismissed: Theme.textTertiary
        }
    }
}

// MARK: - Content

/// The loaded plane: a fixed top row, and everything else scrolling under it.
private struct PullRequestContent: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let askAgent: (String) -> Void

    enum Tab: Hashable { case summary, timeline, code }

    @State private var tab: Tab = .summary
    @AppStorage("octet.pr.timelineNewestFirst") private var newestFirst = true
    /// The header has scrolled away; the top row names the PR instead.
    @State private var condensed = false

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 420
            VStack(spacing: 0) {
                PullRequestTopRow(model: model, detail: detail, narrow: narrow, condensed: condensed, askAgent: askAgent)
                    .padding(.horizontal, PullRequestStyle.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PullRequestHeader(model: model, detail: detail)
                            .background(GeometryReader { header in
                                Color.clear.preference(key: HeaderBottomKey.self,
                                                       value: header.frame(in: .named("pr.scroll")).maxY)
                            })
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.top, 12)
                        tabBar
                        Group {
                            switch tab {
                            case .summary: PullRequestSummaryTab(model: model, detail: detail)
                            case .timeline: PullRequestTimelineTab(model: model, detail: detail, newestFirst: newestFirst)
                            case .code: PullRequestCodeTab(model: model, detail: detail, askAgent: askAgent)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, PullRequestStyle.horizontalPadding)
                    // Room under the last row for the comment button.
                    .padding(.bottom, 64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "pr.scroll")
                .octetScrollIndicators()
                .onPreferenceChange(HeaderBottomKey.self) { bottom in
                    let hidden = bottom < 8
                    if hidden != condensed { MotionPreferences.shared.perform(.sidebar) { condensed = hidden } }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                PullRequestCommentButton(model: model, detail: detail)
                    .padding(16)
            }
        }
        .onChange(of: detail.changedFiles) { _, files in
            if files == 0, tab == .code { tab = .summary }
        }
        .onChange(of: tab) { _, tab in
            if tab == .code { model.loadDiff() }
        }
    }

    private var tabs: [(value: Tab, title: String)] {
        var items: [(value: Tab, title: String)] = [(.summary, "Summary"), (.timeline, "Timeline")]
        if detail.changedFiles > 0 { items.append((.code, "Code")) }
        return items
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            OctetSegmented(selection: $tab, items: tabs) { hovered in
                // Read the diff while the pointer's on its way.
                if hovered == .code { model.loadDiff() }
            }
            Spacer(minLength: 4)
            switch tab {
            case .summary:
                PullRequestChecksStatus(detail: detail, model: model)
            case .timeline:
                timelineTrailing
            case .code:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
    }

    private var timelineTrailing: some View {
        let comments = detail.comments.count
        let commits = detail.commits.count
        let order = OctetButton(title: newestFirst ? "Newest First" : "Oldest First", kind: .ghost, compact: true) {
            MotionPreferences.shared.perform(.sidebar) { newestFirst.toggle() }
        }
        .help("Change the order")
        .fixedSize()
        // The counts give way first on a narrow plane.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("\(comments) \(comments == 1 ? "comment" : "comments") · \(commits) \(commits == 1 ? "commit" : "commits")")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                order
            }
            order
        }
    }
}

private struct HeaderBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Top row

private struct PullRequestTopRow: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let narrow: Bool
    let condensed: Bool
    let askAgent: (String) -> Void
    @State private var repoHovered = false
    @State private var numberHovered = false
    @Environment(\.pullRequestBack) private var back

    var body: some View {
        HStack(spacing: 4) {
            if let back { PullRequestBackButton(action: back.perform) }
            HStack(spacing: 6) {
                if condensed {
                    Text(detail.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(detail.title)
                        .transition(.opacity)
                } else if let repository = model.repository {
                    Button { model.open(repository.url) } label: {
                        Text(repository.nameWithOwner)
                            .font(Theme.uiFont)
                            .foregroundStyle(repoHovered ? Theme.textPrimary : Theme.textSecondary)
                            .underline(repoHovered)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .onHover { repoHovered = $0 }
                    .help("Open \(repository.nameWithOwner) on GitHub")
                    .transition(.opacity)
                }
                Button { model.open(detail.url) } label: {
                    HStack(spacing: 2) {
                        Text(verbatim: "#\(detail.number)")
                            .font(Theme.uiFontMedium.monospacedDigit())
                        OctetIcon("arrow.up.right", size: 10)
                            .opacity(numberHovered ? 1 : 0.8)
                    }
                    .foregroundStyle(detail.tone.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { numberHovered = $0 }
                .help("Open #\(detail.number) on GitHub")
                .fixedSize()
            }
            .layoutPriority(0)
            Spacer(minLength: 6)
            PullRequestPrimaryControl(model: model, detail: detail, askAgent: askAgent)
                .layoutPriority(1)
            if model.canCheckOut {
                PullRequestCheckoutMenu(model: model, narrow: narrow)
                    .layoutPriority(1)
            }
            PullRequestMoreMenu(model: model, detail: detail, askAgent: askAgent)
                .layoutPriority(1)
        }
        .frame(height: 28)
    }
}

/// Merge, or whatever stands in its way, after T3 Code's.
private struct PullRequestPrimaryControl: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let askAgent: (String) -> Void

    var body: some View {
        switch detail.primary(method: model.mergeMethod) {
        case .merged:
            PullRequestBadge(title: "Merged", icon: "merge", tint: PullRequestStyle.violet)
        case .closed:
            PullRequestBadge(title: "Closed", icon: "circle.x", tint: Theme.danger)
        case .resolveConflicts:
            PullRequestOutlineButton(title: "Resolve Conflicts", icon: "sparkles", tint: Theme.danger) {
                askAgent(detail.resolveConflictsPrompt())
            }
            .help("Ask the agent to resolve the conflicts with \(detail.baseRefName)")
        case .readyForReview:
            OctetButton(title: model.busy.contains("ready") ? "Marking…" : "Ready for Review",
                        icon: "check", kind: .secondary, compact: true) { model.markReady() }
                .disabled(model.busy.contains("ready"))
        case .autoMergeArmed(let method):
            PullRequestBadge(title: "Auto-merge (\(method.noun))", icon: "clock", tint: Theme.accent)
                .help("Merges by \(method.noun) once checks and reviews pass")
        case .autoMerge:
            OctetConfirmButton(title: "Auto-merge", icon: "merge", confirmTitle: "Confirm auto-merge?",
                               kind: .secondary, busyTitle: "Enabling…", busy: model.busy.contains("auto")) {
                model.enableAutoMerge()
            }
            .help("Merge by \(model.mergeMethod.title.lowercased()) once checks pass")
        case .merge(let method):
            OctetConfirmButton(title: method.title, icon: "merge", confirmTitle: "Confirm merge?",
                               kind: .primary, busyTitle: "Merging…", busy: model.busy.contains("merge")) {
                model.merge()
            }
        }
    }
}

/// A state shown where a button would be: Merged, Closed, Auto-merge.
struct PullRequestBadge: View {
    let title: String
    var icon: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            if let icon { OctetIcon(icon, size: 12) }
            Text(title).font(Theme.uiFontMedium).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .fixedSize()
    }
}

/// An outlined button in a colour, for an action that needs care
/// (Resolve Conflicts).
struct PullRequestOutlineButton: View {
    let title: String
    var icon: String?
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { OctetIcon(icon, size: 12) }
                Text(title).font(Theme.uiFontMedium).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).fill(tint.opacity(hovered ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .fixedSize()
    }
}

/// Check Out: switch this repository to the PR's branch.
private struct PullRequestCheckoutMenu: View {
    @ObservedObject var model: PullRequestPlaneModel
    let narrow: Bool
    @State private var hovered = false

    var body: some View {
        let checkedOut = model.isCheckedOut
        let busy = model.busy.contains("checkout")
        OctetMenuButton({
            checkedOut
                ? [OctetMenuItem.action("Checked Out", enabled: false) {}]
                : [OctetMenuItem.action("In This Repository",
                                        help: "Switches the branch you're working in, like gh pr checkout.") {
                    model.checkOut()
                }]
        }) {
            HStack(spacing: 5) {
                OctetIcon(checkedOut ? "check" : "branch", size: 12)
                if !narrow {
                    Text(busy ? "Checking Out…" : checkedOut ? "Checked Out" : "Check Out")
                        .font(Theme.uiFontMedium)
                        .lineLimit(1)
                }
                OctetIcon("chevron.down", size: 10).foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).fill(hovered ? Theme.hover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .fixedSize()
        .onHover { hovered = $0 }
        .help(checkedOut ? "This branch is checked out here" : "Check out this pull request's branch")
    }
}

/// ⋯: everything else you can do with the PR.
private struct PullRequestMoreMenu: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let askAgent: (String) -> Void
    @State private var hovered = false

    var body: some View {
        let primary = detail.primary(method: model.mergeMethod)
        OctetMenuButton({ items(primary: primary) }) {
            OctetIcon("ellipsis", size: 14)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .fixedSize()
        .onHover { hovered = $0 }
        .help("More")
        .accessibilityLabel("More pull request actions")
    }

    private func items(primary: PullRequestDetail.Primary) -> [OctetMenuItem] {
        var items: [OctetMenuItem] = [
            .action("Refresh") { model.refresh() },
            .action("Ask About This PR") { askAgent(detail.askPrompt()) },
            .action("Explain This PR", help: "A walk through the diff and what to read closely.") {
                askAgent(detail.explainPrompt())
            },
        ]
        if detail.isOpen {
            items.append(.divider)
            if detail.isDraft {
                items.append(.action("Ready for Review") { model.markReady() })
            } else {
                items.append(.action("Convert to Draft") { model.convertToDraft() })
            }
            if case .autoMerge = primary {
                items.append(.action("Merge Now") { confirmMergeNow() })
            }
            if detail.autoMerge != nil {
                items.append(.action("Disable Auto-Merge") { model.disableAutoMerge() })
            } else if !detail.isDraft {
                items.append(.action("Enable Auto-Merge") { model.enableAutoMerge() })
            }
            items.append(.divider)
            items.append(.header("Merge Method"))
            for method in model.allowedMethods {
                items.append(.action(method.title, icon: model.mergeMethod == method ? "checkmark" : nil) {
                    model.choose(method)
                })
            }
        }
        items.append(.divider)
        items.append(.action("Open on GitHub") { model.open(detail.url) })
        items.append(.action("Copy Link") { model.copy(detail.url?.absoluteString ?? "", "link") })
        items.append(.action("Copy PR Number") { model.copy("#\(detail.number)", "#\(detail.number)") })
        if detail.state != "MERGED" {
            items.append(.divider)
            if detail.isOpen {
                items.append(.action("Close Pull Request…", destructive: true) { confirmClose() })
            } else {
                items.append(.action("Reopen Pull Request") { model.reopen() })
            }
        }
        return items
    }

    private func confirmClose() {
        ConfirmCenter.shared.ask(
            title: "Close pull request #\(detail.number)?",
            message: "\"\(detail.title)\" closes without merging. You can reopen it later.",
            confirmTitle: "Close Pull Request",
            destructive: true
        ) { _ in model.close() }
    }

    private func confirmMergeNow() {
        let summary = detail.checksSummary
        ConfirmCenter.shared.ask(
            title: "Merge #\(detail.number) now?",
            message: "Checks haven't all passed (\(summary.text.lowercased())). It merges by "
                + "\(model.mergeMethod.title.lowercased()) into \(detail.baseRefName) anyway, if GitHub allows it.",
            confirmTitle: "Merge Now",
            destructive: true
        ) { _ in model.merge() }
    }
}

// MARK: - Header

/// Title, who and when, and which branch goes where.
private struct PullRequestHeader: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    @State private var titleHovered = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            meta
            branches
            if let stack = model.stack {
                PullRequestStackBar(model: model, stack: stack)
            }
            if detail.isOpen, detail.isBehind {
                behind
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var title: some View {
        if editingTitle {
            TextField("Title", text: $titleDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.interfaceFont(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .focused($titleFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                .onSubmit {
                    model.editTitle(titleDraft)
                    editingTitle = false
                }
                .onExitCommand { editingTitle = false }
                .onAppear { titleFocused = true }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(detail.title)
                    .font(Theme.interfaceFont(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(detail.title)
                if detail.isOpen {
                    OctetIconButton(icon: "pencil", help: "Rename") {
                        titleDraft = detail.title
                        editingTitle = true
                    }
                    .hoverReveal(titleHovered)
                }
            }
            .onHover { titleHovered = $0 }
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            GitHubAvatar(login: detail.author, size: 16)
            Text(detail.author)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text("·").font(Theme.uiFont).foregroundStyle(Theme.textMuted)
            Text("updated \(PullRequestJSON.ago(detail.updatedAt))")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if detail.isOpen {
                // Another repository's PR needs -R to check out anywhere.
                OctetCopyText(text: "gh pr checkout \(detail.number)" + (model.repo.map { " -R \($0)" } ?? ""))
                    .layoutPriority(-1)
            }
        }
    }

    private var branches: some View {
        HStack(spacing: 6) {
            // Bases are short (main, master); the head gives way first,
            // but a long base can't take the whole row.
            Text(detail.baseRefName)
                .font(Theme.monoFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
                .fixedSize(horizontal: detail.baseRefName.count <= 16, vertical: false)
                .help("Into \(detail.baseRefName)")
            OctetIcon("arrow.left", size: 11)
                .foregroundStyle(Theme.textTertiary)
                .opacity(0.6)
            OctetCopyText(text: detail.headRefName,
                          display: detail.isCrossRepository ? "\(detail.headOwner):\(detail.headRefName)" : nil,
                          help: "Copy the branch name")
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                OctetIcon("doc.diff", size: 11)
                Text("\(detail.changedFiles) \(detail.changedFiles == 1 ? "file" : "files")")
                    .lineLimit(1)
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize()
            DiffStatLabel(added: detail.additions, removed: detail.deletions)
                .fixedSize()
        }
    }

    private var behind: some View {
        HStack(spacing: 6) {
            OctetIcon("exclamationmark.triangle.fill", size: 12)
            Text("Behind \(detail.baseRefName)")
                .font(Theme.captionFont)
                .lineLimit(1)
            Spacer(minLength: 4)
            OctetButton(title: model.busy.contains("update") ? "Updating…" : "Update Branch",
                        icon: "arrow.clockwise", kind: .ghost, compact: true) { model.updateBranch() }
                .disabled(model.busy.contains("update"))
                .help("Merge \(detail.baseRefName) into this branch on GitHub (gh pr update-branch)")
        }
        .foregroundStyle(PullRequestStyle.amber)
    }
}

// MARK: - Loading and empty states

/// Grey bars in the header's shape while the first read is out.
private struct PullRequestSkeleton: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                bar(width: 140, height: 12)
                Spacer()
                bar(width: 90, height: 24)
                bar(width: 24, height: 24)
            }
            .frame(height: 28)
            bar(width: nil, height: 18).padding(.top, 6)
            bar(width: 200, height: 18)
            HStack(spacing: 6) {
                SkeletonCircle(size: 16)
                bar(width: 160, height: 11)
            }
            bar(width: 220, height: 11)
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.top, 6)
            bar(width: 180, height: 24)
            ForEach(0..<3, id: \.self) { _ in bar(width: nil, height: 12) }
            Spacer()
        }
        .padding(.horizontal, PullRequestStyle.horizontalPadding)
        .padding(.top, 8)
        .accessibilityLabel("Loading the pull request")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        SkeletonBlock(width: width, height: height)
    }
}

/// No PR for the branch, or gh can't be used here.
private struct PullRequestFailureView: View {
    let failure: PullRequestLoadFailure
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            OctetIcon(failure == .noPullRequest ? "pull.request" : "exclamationmark.triangle.fill", size: 22)
                .foregroundStyle(Theme.textTertiary)
            Text(failure.title)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text(failure.remedy)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                switch failure {
                case .noPullRequest:
                    OctetButton(title: "Create Pull Request", icon: "sparkles", kind: .primary, compact: true) {
                        askAgent(PullRequestDetail.createPrompt(branch: model.currentBranch))
                    }
                    OctetButton(title: "Open in Browser", icon: "arrow.up.right", kind: .secondary, compact: true) {
                        model.createInBrowser()
                    }
                    .disabled(model.busy.contains("create"))
                default:
                    if let command = failure.command {
                        OctetCopyText(text: command)
                    }
                    OctetButton(title: "Try Again", icon: "arrow.clockwise", kind: .secondary, compact: true) {
                        model.refresh()
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
