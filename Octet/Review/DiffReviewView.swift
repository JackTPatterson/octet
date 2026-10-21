import SwiftUI

/// What the agents changed in a project, file by file, with notes on lines
/// that go back to the agent as one message. Opened over the terminal from
/// the palette or ⌘⇧R; Esc closes it.
@MainActor
final class DiffReviewModel: ObservableObject {
    let directory: String
    @Published var base: ReviewDiff.Base = .uncommitted { didSet { if base != oldValue { refresh() } } }
    /// Only the Diff plane sets it: staged hunks need whitespace intact.
    @Published var ignoreWhitespace = false { didSet { if ignoreWhitespace != oldValue { refresh() } } }
    @Published private(set) var diff: ReviewDiff?
    @Published private(set) var loading = false
    @Published private(set) var notARepository = false
    /// Git failed reading the diff; shown with Retry, not as "No changes".
    @Published private(set) var failure: String?
    @Published var selectedPath: String?
    @Published var comments: [ReviewComment] = []
    /// The line a note is being written on.
    @Published var drafting: (path: String, line: ReviewDiff.Line)?
    /// The other end of the lines the note covers, shift-clicked.
    @Published var draftThrough: ReviewDiff.Line?
    @Published var draft = ""
    @Published var commitMessage = ""
    @Published private(set) var committing = false
    /// Files with something staged: a commit takes only those when any are.
    @Published private(set) var staged: Set<String> = []
    private var timer: Timer?
    /// One read at a time: a slow one isn't raced by the next tick (whose
    /// result would win, dropping it), and a refresh asked for meanwhile
    /// runs once it's done.
    private var reading = false
    private var rerun: (quietly: Bool, ifChanged: Bool)?
    /// The working tree's fingerprint at the last good read, and what it
    /// was read as, so a tick where nothing moved skips the snapshot. Read
    /// again after a while anyway, for what the fingerprint can't see (the
    /// default branch moving in another worktree).
    private var lastRead: (signature: String, base: ReviewDiff.Base, ignoreWhitespace: Bool, at: Date)?
    private static let fullReadInterval: TimeInterval = 30

    /// A best-of-N attempt's starting point, offered as a third comparison.
    let attemptBase: ReviewDiff.Base?

    init(directory: String, since attemptBase: ReviewDiff.Base? = nil) {
        self.directory = directory
        self.attemptBase = attemptBase
        if let attemptBase { base = attemptBase }
    }

    var selectedFile: ReviewDiff.File? {
        diff?.files.first { $0.path == selectedPath } ?? diff?.files.first
    }

    func start() {
        refresh()
        // Agents keep working while it's open; follow along.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quietly: true, ifChanged: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// `ifChanged` is the poll's: it reads only when the working tree's
    /// fingerprint moved (a `git status` and some file times), since a read
    /// snapshots the whole tree into a temporary index.
    func refresh(quietly: Bool = false, ifChanged: Bool = false) {
        if !quietly { loading = true }
        guard !reading else {
            // Merged with any already waiting: the louder, more thorough one.
            rerun = (quietly: quietly && (rerun?.quietly ?? true), ifChanged: ifChanged && (rerun?.ifChanged ?? true))
            return
        }
        reading = true
        let directory = self.directory, base = self.base, ignoreWhitespace = self.ignoreWhitespace
        let previous = ifChanged ? lastRead.flatMap { Date().timeIntervalSince($0.at) < Self.fullReadInterval ? $0 : nil } : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let signature = ReviewDiff.signature(in: directory)
            let unchanged = signature != nil && previous.map {
                $0.signature == signature && $0.base == base && $0.ignoreWhitespace == ignoreWhitespace
            } == true
            let result = unchanged ? nil : ReviewDiff.readResult(in: directory, base: base, ignoreWhitespace: ignoreWhitespace)
            let staged = unchanged ? nil : ReviewDiff.stagedPaths(in: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    defer {
                        if let rerun = self.rerun {
                            self.rerun = nil
                            self.refresh(quietly: rerun.quietly, ifChanged: rerun.ifChanged)
                        }
                    }
                    // The base changed while reading; the rerun reads it.
                    guard self.base == base, self.ignoreWhitespace == ignoreWhitespace, let result, let staged else { return }
                    if case .success = result, let signature {
                        self.lastRead = (signature, base, ignoreWhitespace, Date())
                    } else {
                        self.lastRead = nil
                    }
                    if staged != self.staged { self.staged = staged }
                    self.loading = false
                    let diff = try? result.get()
                    switch result {
                    case .success: self.failure = nil; self.notARepository = false
                    case .failure(.notARepository): self.failure = nil; self.notARepository = true
                    case .failure(.git(let message)):
                        // A refresh that fails keeps what was shown.
                        self.failure = message
                        if self.diff != nil { return }
                    }
                    if diff != self.diff { self.diff = diff }
                    if let files = diff?.files, !files.contains(where: { $0.path == self.selectedPath }) {
                        self.selectedPath = files.first?.path
                    }
                }
            }
        }
    }

    func step(_ offset: Int) {
        guard let files = diff?.files, !files.isEmpty else { return }
        let index = files.firstIndex { $0.path == selectedFile?.path } ?? 0
        selectedPath = files[(index + offset + files.count) % files.count].path
    }

    func beginNote(on line: ReviewDiff.Line, in path: String) {
        if let note = notes(on: line, in: path) {
            drafting = (path, note.line)
            draftThrough = note.through
            draft = note.text
        } else {
            drafting = (path, line)
            draftThrough = nil
            draft = ""
        }
    }

    /// A click on a line: a note on it, or with shift held while a note is
    /// open in the same file, the note grown to reach this line.
    func select(_ line: ReviewDiff.Line, in path: String, extend: Bool) {
        if extend, let drafting, drafting.path == path {
            draftThrough = line == drafting.line ? nil : line
        } else {
            beginNote(on: line, in: path)
        }
    }

    /// The draft's lines, first and last by their place in the file.
    private var draftRange: (first: ReviewDiff.Line, last: ReviewDiff.Line)? {
        guard let drafting else { return nil }
        let other = draftThrough ?? drafting.line
        return drafting.line.index <= other.index ? (drafting.line, other) : (other, drafting.line)
    }

    /// The line the draft's editor sits under: its last.
    func isDraftEnd(_ line: ReviewDiff.Line, in path: String) -> Bool {
        drafting?.path == path && draftRange?.last == line
    }

    /// Lines the open note covers, washed as selected.
    func isSelected(_ line: ReviewDiff.Line, in path: String) -> Bool {
        guard drafting?.path == path, draftThrough != nil, let range = draftRange else { return false }
        return (range.first.index...range.last.index).contains(line.index)
    }

    func cancelNote() {
        drafting = nil
        draftThrough = nil
    }

    func saveNote() {
        guard let (path, _) = drafting, let range = draftRange else { return }
        comments.removeAll { $0.path == path && ($0.line == range.first || $0.line == drafting?.line) }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            comments.append(ReviewComment(path: path, line: range.first, through: range.last, text: text))
        }
        drafting = nil
        draftThrough = nil
        draft = ""
    }

    /// Whether the code a note is about has gone from the diff since.
    func isOutdated(_ note: ReviewComment) -> Bool {
        guard let diff else { return false }
        return note.isOutdated(in: diff.files)
    }

    /// Hunks can be staged only against HEAD: that's what the index holds.
    var canStage: Bool { base == .uncommitted }

    func stage(_ hunk: ReviewDiff.Hunk, of file: ReviewDiff.File) {
        let patch = ReviewDiff.patch(for: file, hunk: hunk), directory = self.directory
        git("Couldn't stage that change") { try ReviewDiff.stage(patch, in: directory) }
    }

    func toggleStaged(_ file: ReviewDiff.File) {
        let path = file.path, directory = self.directory, unstage = staged.contains(path)
        git(unstage ? "Couldn't unstage \(path)" : "Couldn't stage \(path)") {
            unstage ? try ReviewDiff.unstage(path: path, in: directory) : try ReviewDiff.stage(path: path, in: directory)
        }
    }

    private func git(_ failure: String, _ work: @escaping @Sendable () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failure(let error) = outcome {
                        ToastCenter.shared.fail(nil, failure, detail: String(describing: error))
                    }
                    self.refresh(quietly: true)
                }
            }
        }
    }

    /// Only against HEAD: the other comparisons show committed work too.
    var canCommit: Bool { base == .uncommitted }

    /// Commits what's staged, or every change shown when nothing is.
    func commitAll() {
        let message = commitMessage, directory = self.directory, onlyStaged = !staged.isEmpty
        // Return in the field lands here too, past the button's .disabled.
        guard canCommit, !committing, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        committing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                onlyStaged ? try ReviewDiff.commitStaged(message: message, in: directory)
                    : try ReviewDiff.commitAll(message: message, in: directory)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committing = false
                    switch outcome {
                    case .success(let hash):
                        self.commitMessage = ""
                        ToastCenter.shared.succeed(nil, "Committed \(hash)", detail: message)
                        self.refresh()
                    case .failure(let error):
                        ToastCenter.shared.fail(nil, "Couldn't commit", detail: String(describing: error))
                    }
                }
            }
        }
    }

    /// The note shown under `line`: one that ends there.
    func notes(on line: ReviewDiff.Line, in path: String) -> ReviewComment? {
        comments.first { $0.path == path && ($0.through ?? $0.line) == line }
    }
}

struct DiffReviewView: View {
    @ObservedObject var model: DiffReviewModel
    @ObservedObject var store: SessionStore
    let close: () -> Void
    /// Old and new side by side, rather than one column.
    @AppStorage("octet.review.split") private var split = false
    /// Folded files (lockfiles, generated, huge) opened anyway.
    @State private var shown: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if model.notARepository {
                message("Not a git repository", "Review shows changes in a repository's working tree.")
            } else if let failure = model.failure, model.diff == nil {
                DiffReadFailure(detail: failure) { model.refresh() }
            } else if let diff = model.diff, diff.files.isEmpty {
                message("No changes", model.base == .uncommitted ? "Nothing differs from HEAD." : "Nothing differs from \(diff.baseName).")
            } else if model.diff != nil {
                HStack(spacing: 0) {
                    fileList.frame(width: 280)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    fileDiff.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DiffReviewSkeleton()
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
        }
        .background(Theme.terminalBackground)
        .pollWhileSeen(true, start: model.start, stop: model.stop)
        .onExitCommand {
            if model.drafting != nil { model.cancelNote() } else { close() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review changes").font(Theme.Text.title3).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            OctetSegmented(selection: $model.base,
                           items: [(ReviewDiff.Base.uncommitted, "Uncommitted"), (ReviewDiff.Base.branch, "This Branch")]
                               + (model.attemptBase.map { [($0, "The Attempt")] } ?? []))
            .help("Uncommitted: against HEAD. This branch: everything since it left the default branch.")
            OctetSegmented(selection: $split, items: [(false, "Unified"), (true, "Split")])
                .help("One column, or old and new side by side")
            OctetButton(title: "Previous", icon: "arrow.up", kind: .ghost, compact: true) { model.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .help("Previous file (⌥↑)")
            OctetButton(title: "Next", icon: "arrow.down", kind: .ghost, compact: true) { model.step(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .help("Next file (⌥↓)")
            OctetButton(title: "Refresh", icon: "arrow.clockwise", kind: .ghost, compact: true) { model.refresh() }
            OctetButton(title: "Close", kind: .ghost, compact: true, action: close).help("Back (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let project = URL(fileURLWithPath: model.directory).lastPathComponent
        guard let diff = model.diff else { return project }
        let files = diff.files.count
        return "\(project) · \(files) \(files == 1 ? "file" : "files") · +\(diff.added) −\(diff.removed) against \(diff.baseName)"
    }

    // MARK: - Files

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.diff?.files ?? []) { file in
                    let selected = file.path == model.selectedFile?.path
                    let notes = model.comments.filter { $0.path == file.path }.count
                    Button { model.selectedPath = file.path } label: {
                        DiffFileRow(path: file.path, mark: ChangeMark(file.status), added: file.added,
                                       removed: file.removed, binary: file.binary, emphasized: selected) {
                            if model.staged.contains(file.path) {
                                Circle().fill(Theme.success).frame(width: 6, height: 6)
                                    .help("Staged")
                                    .accessibilityLabel("Staged")
                            }
                            if notes > 0 { DiffNoteCount(count: notes) }
                            DiffFileCounts(added: file.added, removed: file.removed, binary: file.binary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(selected ? Theme.cardSelected : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button(model.staged.contains(file.path) ? "Unstage File" : "Stage File") { model.toggleStaged(file) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .octetScrollIndicators()
    }

    /// The theme's success green, which added lines and marks use.
    static var addedColor: Color { Theme.success }

    // MARK: - Diff

    @ViewBuilder
    private var fileDiff: some View {
        if let file = model.selectedFile {
            if file.binary {
                message("Binary file", "\(file.path) changed; there's no text to show.")
            } else if file.tooLarge {
                message("Too large to show", "\(file.path): +\(file.added) −\(file.removed). Open it in an editor to review.")
            } else if let reason = DiffCollapse.reason(for: file), !shown.contains(file.path) {
                VStack(spacing: 10) {
                    Text(reason.title()).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                    Text("\(file.path) is folded: \(reason == .lockfile || reason == .generated ? "a tool writes it" : "it's long to read here").")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    OctetButton(title: "Show diff", kind: .secondary, compact: true) { shown.insert(file.path) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let colors = DiffFileColors.of(file)
                GeometryReader { proxy in
                ScrollView(split ? [.vertical] : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            HStack {
                                Text(hunk.header)
                                    .font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                Spacer()
                                if model.canStage {
                                    Button("Stage") { model.stage(hunk, of: file) }
                                        .buttonStyle(.plain)
                                        .font(Theme.captionFont.weight(.semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                        .help("Stage just this change, to commit it on its own")
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .frame(width: proxy.size.width, alignment: .leading)
                            .background(Theme.card)
                            DiffHunkRows(hunk: hunk, path: file.path, colors: colors, gutter: file.gutterWidth,
                                         split: split, wraps: split, minWidth: split ? 0 : proxy.size.width - 12,
                                         model: model)
                                .frame(width: split ? proxy.size.width - 12 : nil, alignment: .leading)
                                .padding(.horizontal, 6)
                        }
                    }
                    .padding(.bottom, 20)
                    // Rows span the pane however short their text, so a line's
                    // tint reads as the whole line.
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .id(file.path)
                .octetScrollIndicators()
                }
            }
        }
    }

    /// Syntax colours for a file's lines, by index, carried across hunks,
    /// with each edited line's changed words marked.
    static func colors(_ file: ReviewDiff.File) -> DiffFileColors { DiffFileColors.of(file) }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            if !detail.isEmpty { Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sending

    /// Agents working in the project `directory` is in.
    static func agents(in store: SessionStore, directory: String) -> [EngineAgent] {
        let top = AccountProfiles.projectRoot(of: directory) ?? directory
        return store.snapshot.agents.filter { agent in
            guard agent.agent != nil, !agent.isSubagentViewer, let cwd = agent.effectiveCwd else { return false }
            return AccountProfiles.contains(top, cwd) || AccountProfiles.projectRoot(of: cwd) == top
        }
    }

    /// "Claude Code in api", or just the brand when its tab has no name.
    static func name(_ agent: EngineAgent, in store: SessionStore) -> String {
        let brand = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        let tab = agent.tabId.flatMap { id in store.snapshot.tabs.first { $0.tabId == id } }
            .map { TabAutoName.display(label: $0.label, number: $0.number) }
        return tab.map { "\(brand) in \($0)" } ?? brand
    }

    private var footer: some View {
        VStack(spacing: 0) {
            ReviewNotesTray(model: model, store: store) { note in model.selectedPath = note.path }
            // Done reviewing: commit what's here.
            if model.canCommit, model.comments.isEmpty, model.diff.map({ !$0.files.isEmpty }) == true {
                Rectangle().fill(Theme.divider).frame(height: 1)
                HStack(spacing: 10) {
                    Spacer()
                    OctetTextField(placeholder: "Commit message", text: $model.commitMessage) { model.commitAll() }
                        .frame(width: 280)
                    OctetButton(title: model.committing ? "Committing…"
                                    : model.staged.isEmpty ? "Commit All" : "Commit Staged (\(model.staged.count))",
                                kind: .secondary, compact: true) {
                        model.commitAll()
                    }
                    .disabled(model.committing || model.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(model.staged.isEmpty ? "Stage every change shown and commit it" : "Commit only what's staged")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}

/// A file's notes, counted in a pill beside its name.
struct DiffNoteCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.captionFont.monospacedDigit())
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
            .help("\(count) \(count == 1 ? "note" : "notes") on this file")
    }
}

/// Git failed reading the diff: why, Retry, and git's own words behind
/// Copy Details.
struct DiffReadFailure: View {
    let detail: String
    let retry: () -> Void

    var body: some View {
        OctetErrorState(title: "Couldn't read the changes",
                        reason: "Git failed while reading this folder's diff. It may be busy (another git command holds the lock); try again.",
                        actionTitle: "Retry", action: retry, details: detail)
    }
}

/// The review while it first reads: a file list and a diff, in outline.
private struct DiffReviewSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: 8) {
                        SkeletonBlock(width: 10, height: 10)
                        SkeletonBlock(width: [150, 110, 180, 90, 130, 160][index], height: 10)
                    }
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
            Rectangle().fill(Theme.divider).frame(width: 1)
            DiffPlaneSkeleton().frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Reading changes")
    }
}

/// A hunk's lines, in one column or side by side, each taking a note on a
/// click (shift-click to cover several lines), with notes under the lines
/// they end on. The review and the Diff plane both draw hunks with it.
struct DiffHunkRows: View {
    let hunk: ReviewDiff.Hunk
    let path: String
    let colors: DiffFileColors
    let gutter: CGFloat
    let split: Bool
    var wraps = false
    var minWidth: CGFloat = 0
    @ObservedObject var model: DiffReviewModel

    var body: some View {
        if split {
            let pairs = hunk.pairs
            let left = pairs.map { $0.left.map { DiffLineKind($0.kind) } ?? .context }
            let right = pairs.map { $0.right.map { DiffLineKind($0.kind) } ?? .context }
            ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                VStack(alignment: .leading, spacing: 0) {
                    DiffSplitLineRow(pair: pair, colors: colors, gutter: gutter,
                                     leftEdges: pair.left == nil ? (first: false, last: false) : DiffStyle.edges(left, at: index),
                                     rightEdges: pair.right == nil ? (first: false, last: false) : DiffStyle.edges(right, at: index),
                                     isSelected: { model.isSelected($0, in: path) },
                                     tap: { line in model.select(line, in: path, extend: NSEvent.modifierFlags.contains(.shift)) })
                    // A context line is the same on both sides: one note.
                    ForEach(pair.left == pair.right ? [pair.left].compactMap { $0 } : [pair.left, pair.right].compactMap { $0 }) { line in
                        DiffNoteArea(line: line, path: path, model: model)
                    }
                }
            }
        } else {
            let kinds = hunk.lineKinds
            ForEach(Array(hunk.lines.enumerated()), id: \.element.id) { index, line in
                DiffReviewLine(line: line, path: path, text: colors.text(line), model: model, wraps: wraps,
                               gutter: gutter, edges: DiffStyle.edges(kinds, at: index), minWidth: minWidth)
            }
        }
    }
}

/// One line of the diff in Octet's diff style, and its note. Click to
/// write one; shift-click to stretch the open note to this line.
struct DiffReviewLine: View {
    let line: ReviewDiff.Line
    let path: String
    var text: AttributedString?
    @ObservedObject var model: DiffReviewModel
    /// Long lines wrap rather than run off, for a narrow pane.
    var wraps = false
    var gutter: CGFloat = 48
    /// Where it sits in its run of changes, for the block's corners.
    var edges: (first: Bool, last: Bool) = (false, false)
    var minWidth: CGFloat = 0

    var body: some View {
        let note = model.notes(on: line, in: path)
        let drafting = model.isDraftEnd(line, in: path)
        VStack(alignment: .leading, spacing: 0) {
            DiffHoverTap(help: "Leave a note on this line (shift-click to cover several)", showsMark: note == nil && !drafting) {
                model.select(line, in: path, extend: NSEvent.modifierFlags.contains(.shift))
            } label: {
                DiffLineRow(line, text: text, gutter: gutter, edges: edges, wraps: wraps, minWidth: minWidth,
                            selected: model.isSelected(line, in: path))
                    .opacity(line.kind == .context ? 0.85 : 1)
            }
            DiffNoteArea(line: line, path: path, model: model)
        }
    }
}

/// A line's note under it, or the editor while one is being written.
private struct DiffNoteArea: View {
    let line: ReviewDiff.Line
    let path: String
    @ObservedObject var model: DiffReviewModel

    var body: some View {
        let note = model.notes(on: line, in: path)
        if model.isDraftEnd(line, in: path) {
            noteEditor
        } else if let note {
            let outdated = model.isOutdated(note)
            Button { model.beginNote(on: line, in: path) } label: {
                HStack(alignment: .top, spacing: 8) {
                    OctetIcon("text.bubble", size: 13).foregroundStyle(outdated ? Theme.textTertiary : Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        if note.through != nil || outdated {
                            Text((note.through != nil ? "Lines \(note.location)" : "") + (outdated ? (note.through != nil ? " · " : "") + "Outdated" : ""))
                                .font(Theme.Text.micro.weight(.medium))
                                .foregroundStyle(outdated ? Theme.warning : Theme.textTertiary)
                        }
                        Text(note.text).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .font(Theme.uiFont)
                .padding(8)
                .frame(maxWidth: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 40).padding(.trailing, 8).padding(.vertical, 4)
            .help(outdated ? "The code this note is about has changed since" : "Edit this note")
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(model.draftThrough == nil ? "What should the agent change here?" : "What should the agent change in these lines?",
                      text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .lineLimit(2...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.accent, lineWidth: 1))
                .onSubmit { model.saveNote() }
                .accessibilityLabel("Note for the agent")
            HStack(spacing: 6) {
                Text("Shift-click another line to cover several")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 4)
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { model.cancelNote() }
                OctetButton(title: "Save note", kind: .primary, compact: true) { model.saveNote() }
            }
        }
        .frame(maxWidth: 640)
        .padding(.leading, 40).padding(.trailing, 8).padding(.vertical, 6)
    }
}
