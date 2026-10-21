import SwiftUI

// The pull request plane's Code tab, after T3 Code's: the diff file by
// file, a Viewed checkbox on each file that folds it and syncs with GitHub,
// the review comments already on each line, and line comments you write
// for the next review or for the agent.

struct PullRequestCodeTab: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let askAgent: (String) -> Void
    /// Files opened or folded by hand, which beats every default.
    @State private var openOverride: [String: Bool] = [:]
    /// Expand All / Collapse All: every file one way.
    @State private var allOpen: Bool?
    /// Old and new side by side, as the Diff plane keeps it.
    @AppStorage("octet.diff.split") private var split = false

    var body: some View {
        Group {
            if let files = model.diffFiles {
                if files.isEmpty {
                    Text("No changes to show.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 12)
                } else {
                    list(files)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LoadingLine(width: 18)
                    DiffPlaneSkeleton()
                }
                .padding(.vertical, 12)
            }
        }
        .onAppear { model.loadDiff() }
    }

    /// A file you've viewed starts folded, as on GitHub; a long diff starts
    /// with everything folded, and so do lockfiles, generated and huge files.
    private func isOpen(_ file: ReviewDiff.File, _ count: Int) -> Bool {
        if let open = openOverride[file.path] { return open }
        if let allOpen { return allOpen }
        if model.isViewed(file.path) { return false }
        if DiffCollapse.reason(for: file) != nil { return false }
        return count <= 10
    }

    /// Why a file is folded, shown with "Show diff", while nothing else
    /// (a click, Viewed, Expand All) has decided.
    private func foldReason(_ file: ReviewDiff.File) -> DiffCollapse? {
        guard openOverride[file.path] == nil, allOpen == nil, !model.isViewed(file.path) else { return nil }
        return DiffCollapse.reason(for: file)
    }

    private func list(_ files: [ReviewDiff.File]) -> some View {
        let everyOpen = files.allSatisfy { isOpen($0, files.count) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(files.count) \(files.count == 1 ? "file" : "files") changed")
                if let state = model.viewedState {
                    Text("·")
                    Text(PullRequestViewedState.summary(viewed: state.count(in: files.map(\.path)), of: files.count))
                        .monospacedDigit()
                }
                Spacer()
                OctetIconButton(icon: split ? "rectangle.split.2x1" : "rectangle.split.1x2",
                                help: split ? "Show in one column" : "Show old and new side by side", active: split) {
                    split.toggle()
                }
                OctetButton(title: everyOpen ? "Collapse All" : "Expand All", kind: .ghost, compact: true) {
                    MotionPreferences.shared.perform(.sidebar) {
                        allOpen = !everyOpen
                        openOverride = [:]
                    }
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            ForEach(files) { file in
                let open = isOpen(file, files.count)
                PullRequestFileDiff(
                    file: file, open: open, split: split, reason: foldReason(file), model: model, askAgent: askAgent,
                    toggle: {
                        MotionPreferences.shared.perform(.sidebar) { openOverride[file.path] = !open }
                    },
                    setViewed: { viewed in
                        // Marking a file viewed folds it; unmarking opens it again.
                        MotionPreferences.shared.perform(.sidebar) { openOverride[file.path] = !viewed }
                        model.setViewed(file.path, viewed)
                    })
            }
        }
        .padding(.top, 4)
    }
}

/// One file: its header, and its hunks when open.
private struct PullRequestFileDiff: View {
    let file: ReviewDiff.File
    let open: Bool
    let split: Bool
    /// Why it starts folded, offered with "Show diff".
    let reason: DiffCollapse?
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void
    let toggle: () -> Void
    let setViewed: (Bool) -> Void
    @State private var hovered = false
    /// The card's width, so short lines' tints still span it.
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !open, let reason {
                DiffCollapsedNote(reason: reason, show: toggle)
            }
            if open {
                if file.binary {
                    note("Binary file; there's no text to show.")
                } else if file.tooLarge {
                    note("Too large to show here: +\(file.added) −\(file.removed).")
                } else {
                    hunks
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// The fold button spans the row; the Viewed checkbox sits apart from
    /// it so a click there doesn't also fold.
    private var header: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                DiffFileRow(path: file.path, mark: ChangeMark(file.status), added: file.added,
                               removed: file.removed, binary: file.binary) {
                    OctetIcon("chevron.right", size: 10)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                } trailing: {
                    DiffFileCounts(added: file.added, removed: file.removed, binary: file.binary)
                }
                .help(file.path)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.viewedState != nil {
                PullRequestViewedToggle(viewed: model.isViewed(file.path)) { setViewed($0) }
                    .padding(.trailing, 4)
            }
        }
        .background(hovered ? Theme.hover : Theme.card)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var hunks: some View {
        let colors = DiffFileColors.of(file)
        if split {
            // Side by side wraps rather than scrolling sideways.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkHeader(hunk)
                    let pairs = hunk.pairs
                    let left = pairs.map { $0.left.map { DiffLineKind($0.kind) } ?? .context }
                    let right = pairs.map { $0.right.map { DiffLineKind($0.kind) } ?? .context }
                    ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                        PullRequestSplitLine(pair: pair, path: file.path, colors: colors, gutter: file.gutterWidth,
                                             leftEdges: pair.left == nil ? (first: false, last: false) : DiffStyle.edges(left, at: index),
                                             rightEdges: pair.right == nil ? (first: false, last: false) : DiffStyle.edges(right, at: index),
                                             width: width, model: model, askAgent: askAgent)
                    }
                    .padding(.horizontal, 6)
                }
            }
        } else {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        hunkHeader(hunk)
                        let kinds = hunk.lineKinds
                        ForEach(Array(hunk.lines.enumerated()), id: \.element.id) { index, line in
                            PullRequestDiffLine(line: line, path: file.path, text: colors.text(line),
                                                gutter: file.gutterWidth, edges: DiffStyle.edges(kinds, at: index),
                                                width: width, model: model, askAgent: askAgent)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                // The card's width at least, then as wide as the longest line;
                // every row stretches to it.
                .frame(minWidth: width, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            }
            .octetScrollIndicators()
        }
    }

    private func hunkHeader(_ hunk: ReviewDiff.Hunk) -> some View {
        Text(hunk.header)
            .font(Theme.monoFont)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card.opacity(0.5))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The file header's "Viewed" checkbox.
private struct PullRequestViewedToggle: View {
    let viewed: Bool
    let set: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        Button { set(!viewed) } label: {
            HStack(spacing: 5) {
                OctetIcon(viewed ? "checkmark.square.fill" : "square", size: 13)
                    .foregroundStyle(viewed ? Theme.accent : hovered ? Theme.textPrimary : Theme.textTertiary)
                Text("Viewed")
                    .font(Theme.captionFont)
                    .foregroundStyle(viewed || hovered ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(viewed ? "Mark as not viewed" : "Mark as viewed; it folds until the file changes")
        .accessibilityLabel("Viewed")
        .accessibilityValue(viewed ? "On" : "Off")
    }
}

// MARK: - Lines

/// One diff line, with a comment button on hover and, under it, the review
/// comments on it, your pending ones, and the draft while you write one.
private struct PullRequestDiffLine: View {
    let line: ReviewDiff.Line
    let path: String
    let text: AttributedString?
    let gutter: CGFloat
    let edges: (first: Bool, last: Bool)
    /// The file card's width; cards under the line fit inside it.
    let width: CGFloat
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void
    @State private var hovered = false

    var body: some View {
        let anchor = PullRequestLineAnchor(path: path, line: line)
        let drafting = anchor != nil && model.lineDraft?.anchor == anchor
        VStack(alignment: .leading, spacing: 0) {
            DiffLineRow(line, text: text, gutter: gutter, edges: edges, minWidth: max(0, width - 12))
                .background {
                    if line.kind == .context && (hovered || drafting) { Theme.hover }
                }
                .overlay(alignment: .leading) {
                    if hovered && anchor != nil && !drafting {
                        OctetIconButton(icon: "text.bubble", help: "Comment on this line", tint: Theme.accent) {
                            model.beginLineComment(on: line, in: path)
                        }
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
                        .frame(height: DiffStyle.rowHeight)
                    }
                }
                .onHover { hovered = $0 }
            PullRequestLineThread(line: line, path: path, width: width, model: model, askAgent: askAgent)
        }
    }
}

/// One row of the side-by-side diff: either side's line takes a comment on
/// a click, and the comments on each side's line follow the row.
private struct PullRequestSplitLine: View {
    let pair: ReviewDiff.Hunk.Pair
    let path: String
    let colors: DiffFileColors
    let gutter: CGFloat
    let leftEdges: (first: Bool, last: Bool)
    let rightEdges: (first: Bool, last: Bool)
    let width: CGFloat
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void

    var body: some View {
        // A context line is the same on both sides: one thread.
        let lines = pair.left == pair.right ? [pair.left].compactMap { $0 } : [pair.left, pair.right].compactMap { $0 }
        VStack(alignment: .leading, spacing: 0) {
            DiffSplitLineRow(pair: pair, colors: colors, gutter: gutter, leftEdges: leftEdges, rightEdges: rightEdges,
                             tap: { line in
                                 if PullRequestLineAnchor(path: path, line: line) != nil { model.beginLineComment(on: line, in: path) }
                             })
            ForEach(lines) { line in
                PullRequestLineThread(line: line, path: path, width: width, model: model, askAgent: askAgent)
            }
        }
    }
}

/// The review comments on a line, your pending ones, and the draft while
/// you write one.
private struct PullRequestLineThread: View {
    let line: ReviewDiff.Line
    let path: String
    let width: CGFloat
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void

    var body: some View {
        let anchor = PullRequestLineAnchor(path: path, line: line)
        let drafting = anchor != nil && model.lineDraft?.anchor == anchor
        let thread = anchor.flatMap { model.reviewComments[$0] } ?? []
        let pending = anchor.map { anchor in model.pendingComments.filter { $0.anchor == anchor } } ?? []
        if !thread.isEmpty || !pending.isEmpty || drafting {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(thread) { PullRequestLineCommentCard(comment: $0) }
                ForEach(pending) { comment in
                    PullRequestPendingCard(comment: comment) { model.removePending(comment) }
                }
                if drafting { PullRequestLineDraftCard(model: model, askAgent: askAgent) }
            }
            .frame(width: max(240, min(640, width - 28)), alignment: .leading)
            .padding(.leading, 8)
            .padding(.vertical, 6)
        }
    }
}

/// A review comment already on the line: who, when, and what they said.
private struct PullRequestLineCommentCard: View {
    let comment: PullRequestReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GitHubAvatar(login: comment.author, size: 16)
                Text(comment.author)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(PullRequestJSON.ago(comment.createdAt))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if !comment.body.isEmpty { MarkdownView(text: comment.body) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
    }
}

/// A line comment held for your review, until you submit or drop it.
private struct PullRequestPendingCard: View {
    let comment: PullRequestPendingComment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pending")
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    .help("Sent with your review")
                Text(comment.body)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            OctetIconButton(icon: "xmark", help: "Remove from the review", action: remove)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
    }
}

/// The comment being written under a line. ⌘↩ adds it to the review;
/// Escape drops it.
private struct PullRequestLineDraftCard: View {
    @ObservedObject var model: PullRequestPlaneModel
    let askAgent: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let text = Binding(get: { model.lineDraft?.text ?? "" }, set: { model.lineDraft?.text = $0 })
        let blank = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add a comment…", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3...10)
                .focused($focused)
                .accessibilityLabel("Add a comment")
            HStack(spacing: 6) {
                Text("⌘↩ to comment")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { model.lineDraft = nil }
                OctetButton(title: "Add to Agent", kind: .secondary, compact: true) {
                    if let prompt = model.takeDraftForAgent() { askAgent(prompt) }
                }
                .disabled(blank)
                .help("Send this comment to the agent instead of GitHub")
                OctetButton(title: "Add to Review", kind: .primary, compact: true) { model.addDraftToReview() }
                    .disabled(blank)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Hold it for your review; submit the review from the comment button (⌘↩)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        .onAppear { focused = true }
        .onExitCommand { model.lineDraft = nil }
    }
}
