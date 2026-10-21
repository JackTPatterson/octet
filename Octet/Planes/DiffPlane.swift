import SwiftUI

/// The Diff plane: what changed in the project in front, file by file, after
/// T3 Code's diff surface. Files fold to their headers; lines take notes that
/// go to the agent as one message, as in the full review (⌘⇧R), which this
/// can open with the same comparison.
struct DiffPlane: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @State private var model: DiffReviewModel?

    private var visible: Bool { ui.showing(.diff) }

    private var directory: String? {
        #if DEBUG
        // Verification hook: a project to show without a pane in it.
        if let forced = ProcessInfo.processInfo.environment["OCTET_PLANE_DIRECTORY"] { return forced }
        if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"]?.hasSuffix(":loading") == true { return NSHomeDirectory() }
        #endif
        return window.focusedDirectory
    }

    var body: some View {
        Group {
            if let model {
                DiffPlaneBody(model: model, store: store, ui: ui)
                    .id(ObjectIdentifier(model))
            } else {
                PlaneMessage(icon: "doc.diff", title: "No project in front",
                             detail: "Open a tab in a project folder to see what changed.")
            }
        }
        .onAppear { follow(ui.diffRequest?.directory ?? directory) }
        .onChange(of: directory) { _, directory in follow(directory) }
        // A conversation's turn: the plane goes to that conversation's project.
        .onChange(of: ui.diffRequest) { _, request in
            if let request { follow(request.directory) }
        }
        .pollWhileSeen(visible, start: { model?.start() }, stop: { model?.stop() })
    }

    /// A model for the project in front; the same project keeps its model,
    /// and with it the notes written so far.
    private func follow(_ directory: String?) {
        guard let directory else { return }
        let root = AccountProfiles.projectRoot(of: directory) ?? directory
        guard model.map({ (AccountProfiles.projectRoot(of: $0.directory) ?? $0.directory) != root }) ?? true else { return }
        model?.stop()
        let next = DiffReviewModel(directory: directory)
        model = next
        if visible { next.start() }
    }
}

private struct DiffPlaneBody: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var model: DiffReviewModel
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject private var outbox = ReviewNotesOutbox.shared
    /// Files folded to their header, by path.
    @State private var folded: Set<String> = []
    /// Paths seen, so a file that turns up later starts folded or not by the
    /// same rule as the rest, and folding survives refreshes.
    @State private var seen: Set<String> = []
    /// Kept across launches, as T3 Code keeps it.
    @AppStorage("octet.diff.hideWhitespace") private var hideWhitespace = false
    /// Old and new side by side; the review keeps its own choice.
    @AppStorage("octet.diff.split") private var split = false
    /// Folded-by-rule files (lockfiles, generated, huge) opened anyway.
    @State private var shown: Set<String> = []
    /// The agent's turns here, newest first.
    @State private var turns: [(base: ReviewDiff.Base, title: String, date: Date)] = []
    /// A file a conversation asked to see: the plane opens on it once the
    /// diff has it, the others folded.
    @State private var focusPath: String?
    /// The file to bring into view, once its section is laid out.
    @State private var focusTarget: String?

    private var scopeTitle: String {
        switch model.base {
        case .uncommitted: "Uncommitted"
        case .branch: "This Branch"
        case .turn: turns.first { $0.base == model.base }?.title ?? "Turn"
        case .since(_, let name): "Since \(name)"
        }
    }

    private func loadTurns() {
        let directory = model.directory
        Task {
            let found = await Task.detached(priority: .utility) { ReviewDiff.turns(Checkpoints.list(in: directory)) }.value
            turns = found
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
            if !model.comments.isEmpty || !outbox.notes(for: model.directory).isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                ReviewNotesTray(model: model, store: store, compact: true) { note in
                    folded.remove(note.path)
                    focusTarget = note.path
                }
            }
        }
        .onAppear {
            if model.ignoreWhitespace != hideWhitespace { model.ignoreWhitespace = hideWhitespace }
            loadTurns()
        }
        .onChange(of: ui.diffRequest, initial: true) { _, request in take(request) }
        .onChange(of: model.diff?.baseCommit) { _, _ in loadTurns() }
        .onChange(of: model.diff?.files.map(\.path) ?? [], initial: true) { _, paths in
            // Many files start folded, so the list reads as a summary first.
            let fresh = paths.filter { !seen.contains($0) }
            if paths.count > 3 { folded.formUnion(fresh) }
            seen.formUnion(fresh)
            focus(in: paths)
        }
    }

    /// Opens on the file asked for, the others folded, once the diff has it.
    private func focus(in paths: [String]) {
        guard let focusPath, let match = Self.file(matching: focusPath, in: paths) else { return }
        folded = Set(paths).subtracting([match])
        focusTarget = match
        self.focusPath = nil
    }

    /// A turn a conversation asked for: its comparison, worked out from the
    /// checkpoint taken as the turn started; without one, what's uncommitted.
    private func take(_ request: UIState.DiffRequest?) {
        guard let request else { return }
        let root = AccountProfiles.projectRoot(of: request.directory) ?? request.directory
        guard (AccountProfiles.projectRoot(of: model.directory) ?? model.directory) == root else { return }
        ui.diffRequest = nil
        focusPath = request.path
        guard let promptAt = request.promptAt else { return focus(in: model.diff?.files.map(\.path) ?? []) }
        let directory = model.directory
        Task {
            let base = await Task.detached(priority: .userInitiated) { () -> ReviewDiff.Base? in
                let points = Checkpoints.list(in: directory)
                guard let found = Checkpoints.checkpoint(forPromptAt: promptAt, nextPromptAt: request.nextPromptAt,
                                                         in: points) else { return nil }
                return ReviewDiff.turns(points).first { turn in
                    if case .turn(let from, _, _) = turn.base { return from == found.commit }
                    return false
                }?.base
            }.value
            if let base {
                model.base = base
            } else {
                model.base = .uncommitted
                ToastCenter.shared.info("No checkpoint for this turn",
                                        detail: "Showing what's uncommitted instead. Octet takes one as an agent starts a turn.")
            }
            loadTurns()
            // Already loaded with the file in it: open on it now.
            focus(in: model.diff?.files.map(\.path) ?? [])
        }
    }

    /// The diff's path (relative to the repository) for an absolute one.
    static func file(matching path: String, in paths: [String]) -> String? {
        paths.first { path == $0 || path.hasSuffix("/" + $0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Compare", selection: $model.base) {
                    Text("Uncommitted").tag(ReviewDiff.Base.uncommitted)
                    Text("This Branch").tag(ReviewDiff.Base.branch)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                // An agent's turns, from the checkpoints Octet takes as each
                // starts, after T3 Code's turn diffs.
                if !turns.isEmpty {
                    Picker("Turns", selection: $model.base) {
                        ForEach(turns.prefix(20), id: \.title) { turn in
                            Text("\(turn.title) · \(turn.date.formatted(.relative(presentation: .named)))").tag(turn.base)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeTitle)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                    OctetIcon("chevron.down", size: 10).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Compare against HEAD, or against where this branch left the default branch")
            if let diff = model.diff, !diff.files.isEmpty {
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                DiffStatLabel(added: diff.added, removed: diff.removed)
            }
            Spacer(minLength: 4)
            if model.loading || PlaneLoadingPreview.shows("diff") { LoadingLine(width: 12) }
            OctetIconButton(icon: "pilcrow", help: model.ignoreWhitespace ? "Show whitespace changes" : "Hide whitespace changes",
                            active: model.ignoreWhitespace) {
                model.ignoreWhitespace.toggle()
                hideWhitespace = model.ignoreWhitespace
            }
            OctetIconButton(icon: split ? "rectangle.split.2x1" : "rectangle.split.1x2",
                            help: split ? "Show in one column" : "Show old and new side by side", active: split) {
                split.toggle()
            }
            OctetIconButton(icon: "arrow.clockwise", help: "Refresh diff") { model.refresh() }
            let allFolded = model.diff.map { $0.files.allSatisfy { folded.contains($0.path) } } ?? false
            OctetIconButton(icon: allFolded ? "chevron.down.square" : "chevron.up.square",
                            help: allFolded ? "Expand all files" : "Collapse all files") {
                MotionPreferences.shared.perform(.sidebar) {
                    folded = allFolded ? [] : Set(model.diff?.files.map(\.path) ?? [])
                }
            }
            OctetIconButton(icon: "arrow.up.left.and.arrow.down.right", help: "Open the full review (⌘⇧R)") {
                ui.review = DiffReviewModel(directory: model.directory)
                ui.review?.base = model.base
                ui.review?.comments = model.comments
                model.comments = []
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    // MARK: - Files

    @ViewBuilder
    private var content: some View {
        if PlaneLoadingPreview.shows("diff") {
            DiffPlaneSkeleton().frame(maxHeight: .infinity, alignment: .top)
        } else if model.notARepository {
            PlaneMessage(icon: "doc.diff", title: "Not a Git repository",
                         detail: "Diffs need a Git repository. This folder isn't in one.")
        } else if let failure = model.failure, model.diff == nil {
            DiffReadFailure(detail: failure) { model.refresh() }
        } else if let diff = model.diff {
            if diff.files.isEmpty {
                PlaneMessage(icon: "doc.diff", title: "No changes",
                             detail: { switch model.base {
                                 case .branch: "This branch has nothing the default branch doesn't."
                                 case .turn: "This turn changed no files."
                                 default: "Nothing is uncommitted here."
                             } }())
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(diff.files) { file in
                                Section {
                                    if !folded.contains(file.path) { fileBody(file) }
                                } header: {
                                    DiffPlaneFileHeader(file: file, folded: folded.contains(file.path),
                                                        notes: model.comments.filter { $0.path == file.path }.count,
                                                        reason: shown.contains(file.path) ? nil : DiffCollapse.reason(for: file)) {
                                        MotionPreferences.shared.perform(.sidebar) {
                                            if folded.contains(file.path) { folded.remove(file.path) } else { folded.insert(file.path) }
                                        }
                                    }
                                    .id(file.path)
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .octetScrollIndicators()
                    .onChange(of: focusTarget, initial: true) { _, target in
                        guard let target else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(target, anchor: .top)
                            focusTarget = nil
                        }
                    }
                }
            }
        } else {
            DiffPlaneSkeleton()
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .bottom) { LoadingLine().padding(8) }
        }
    }

    @ViewBuilder
    private func fileBody(_ file: ReviewDiff.File) -> some View {
        if file.binary {
            fileNote("Binary file; there's no text to show.")
        } else if file.tooLarge {
            fileNote("Too large to show here: +\(file.added) −\(file.removed).")
        } else if let reason = DiffCollapse.reason(for: file), !shown.contains(file.path) {
            DiffCollapsedNote(reason: reason) {
                MotionPreferences.shared.perform(.sidebar) { _ = shown.insert(file.path) }
            }
        } else {
            let colors = DiffFileColors.of(file)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card.opacity(0.6))
                    DiffHunkRows(hunk: hunk, path: file.path, colors: colors, gutter: file.gutterWidth,
                                 split: split, wraps: true, model: model)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func fileNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// A file's row: fold chevron, then the shared changed-file row with its
/// notes, why it's folded if it is, and +/−. Pinned while its lines
/// scroll by.
private struct DiffPlaneFileHeader: View {
    let file: ReviewDiff.File
    let folded: Bool
    let notes: Int
    /// Why its lines start hidden, when they do.
    var reason: DiffCollapse?
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            DiffFileRow(path: file.path, mark: ChangeMark(file.status), added: file.added, removed: file.removed,
                           binary: file.binary) {
                OctetIcon("chevron.right", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            } trailing: {
                if notes > 0 { DiffNoteCount(count: notes) }
                if let reason {
                    Text(reason.title())
                        .font(Theme.Text.micro.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Theme.card))
                        .lineLimit(1)
                }
                DiffFileCounts(added: file.added, removed: file.removed, binary: file.binary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovered ? Theme.hover : Theme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(file.path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
    }
}

/// A plane's centred message: a mark, a title and what to do. The shared
/// empty state in its compact form, kept under this name for the planes
/// that use it.
struct PlaneMessage: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        OctetEmptyState(icon: icon, title: title, message: detail, compact: true)
    }
}
