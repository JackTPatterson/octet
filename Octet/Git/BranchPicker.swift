import SwiftUI

/// The branch picker's state for one checkout: its branches, the search,
/// what's running and what went wrong. Git runs off the main thread through
/// the same `Git` the panel uses.
@MainActor
final class BranchPickerModel: ObservableObject {
    @Published private(set) var entries: [GitBranches.Entry] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy: String?
    /// The last failure, drawn inline above the list.
    @Published var failure: String?
    /// A switch held back by changes in the tree, waiting for a stash or a cancel.
    @Published var held: Held?
    @Published var query = ""
    /// Where a new branch starts; the current branch when nil.
    @Published var base: String?

    struct Held: Equatable {
        let entry: GitBranches.Entry
        let files: Int
    }

    let top: String
    private let changed: () -> Void
    private let close: () -> Void

    init(top: String, changed: @escaping () -> Void, close: @escaping () -> Void) {
        self.top = top
        self.changed = changed
        self.close = close
    }

    var current: GitBranches.Entry? { entries.first(where: \.isCurrent) }
    var visible: [GitBranches.Entry] { GitBranches.filter(entries, query: query) }
    var newName: String { query.trimmingCharacters(in: .whitespaces) }
    /// A name worth offering to create: valid, and not already a branch.
    var canCreate: Bool {
        GitBranches.validName(newName) && !entries.contains { !$0.isRemote && $0.name == newName }
    }

    func load() {
        let top = top
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Git()
            let local = (try? git.run(["for-each-ref", "--format=" + GitBranches.listFormat, "refs/heads"], in: top)) ?? ""
            let remote = (try? git.run(["for-each-ref", "--format=" + GitBranches.remoteFormat, "refs/remotes"], in: top)) ?? ""
            let locals = GitBranches.parseLocal(local)
            let all = GitBranches.sorted(locals + GitBranches.parseRemote(remote, local: locals))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.entries = all
                    self.loaded = true
                }
            }
        }
    }

    // MARK: - Actions

    /// Checks `entry` out here. A tree with changes holds the switch for a
    /// stash; nothing is ever discarded.
    func checkOut(_ entry: GitBranches.Entry, stashing: Bool = false) {
        if let path = entry.worktree, !entry.isCurrent { return open(path) }
        guard !entry.isCurrent else { return close() }
        let top = top
        run("Switching…", failure: "Couldn't switch to \(entry.name)") { git in
            if !stashing {
                let plan = GitBranches.switchPlan(porcelain: try git.run(["status", "--porcelain"], in: top))
                if case .needsStash(let files) = plan { return .held(files) }
            }
            var stashed = false
            if stashing {
                try git.run(["stash", "push", "-m", "Octet: before switching to \(entry.name)"], in: top)
                stashed = true
            }
            do {
                try git.run(entry.isRemote ? ["switch", "--track", entry.name] : ["switch", entry.name], in: top)
            } catch {
                if stashed { _ = try? git.run(["stash", "pop"], in: top) }
                throw error
            }
            return .done(stashed ? "Stashed your changes" : nil)
        } held: { [self] files in held = Held(entry: entry, files: files) }
    }

    /// Creates `newName` from `base` (the current branch by default) and
    /// switches to it, or puts it in a worktree of its own.
    func create(inWorktree: Bool, stashing: Bool = false) {
        guard canCreate else { return }
        let name = newName, top = top
        let from = base ?? current?.name
        let folder = SettingsStore.shared.values.worktreesDirectory
        let moving = from != nil && from != current?.name
        run(inWorktree ? "Creating worktree…" : "Creating…", failure: "Couldn't create \(name)") { git in
            let start = from.map { [$0] } ?? []
            if inWorktree {
                let path = Self.worktreePath(top: top, folder: folder, branch: name)
                try git.run(["worktree", "add", "-b", name, path] + start, in: top)
                return .opened(path)
            }
            if moving, !stashing {
                let plan = GitBranches.switchPlan(porcelain: try git.run(["status", "--porcelain"], in: top))
                if case .needsStash(let files) = plan { return .held(files) }
            }
            if moving, stashing { try git.run(["stash", "push", "-m", "Octet: before creating \(name)"], in: top) }
            try git.run(["switch", "-c", name] + start, in: top)
            return .done(moving && stashing ? "Stashed your changes" : nil)
        } held: { [self] files in
            held = Held(entry: GitBranches.Entry(name: name), files: files)
        }
    }

    /// Checks `entry` out in a worktree of its own and opens it.
    func openInWorktree(_ entry: GitBranches.Entry) {
        let top = top
        let folder = SettingsStore.shared.values.worktreesDirectory
        run("Creating worktree…", failure: "Couldn't create a worktree for \(entry.name)") { git in
            let local = entry.isRemote ? GitBranches.localName(ofRemote: entry.name) : entry.name
            let path = Self.worktreePath(top: top, folder: folder, branch: local)
            try git.run(entry.isRemote ? ["worktree", "add", "--track", "-b", local, path, entry.name]
                                       : ["worktree", "add", path, entry.name], in: top)
            return .opened(path)
        } held: { _ in }
    }

    /// Stashes and goes ahead with whatever was held.
    func stashAndContinue() {
        guard let held else { return }
        self.held = nil
        if held.entry.isRemote || entries.contains(where: { $0.name == held.entry.name }) {
            checkOut(held.entry, stashing: true)
        } else {
            create(inWorktree: false, stashing: true)
        }
    }

    private func open(_ path: String) {
        close()
        WindowRegistry.shared.key?.openProject(path: path)
    }

    private nonisolated static func worktreePath(top: String, folder: String, branch: String) -> String {
        GitBranches.worktreePath(folder: folder, repository: (top as NSString).lastPathComponent, branch: branch)
    }

    private enum Outcome {
        case done(String?)
        case held(Int)
        case opened(String)
    }

    private func run(_ label: String, failure message: String, _ work: @escaping (Git) throws -> Outcome,
                     held: @escaping (Int) -> Void) {
        guard busy == nil else { return }
        busy = label
        failure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work(Git()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = nil
                    switch outcome {
                    case .success(.held(let files)): held(files)
                    case .success(.done(let note)):
                        if let note {
                            ToastCenter.shared.info(note, detail: "Run git stash pop to bring them back.")
                        }
                        self.changed()
                        self.close()
                    case .success(.opened(let path)):
                        self.changed()
                        self.open(path)
                    case .failure(let error):
                        self.failure = message + ": " + GitRemote.explain(String(describing: error))
                        self.load()
                    }
                }
            }
        }
    }
}

/// The current branch as a chip that opens the picker. The git panel's
/// header and the status bar draw this same view.
struct BranchPickerChip: View {
    enum Style { case panel, statusBar }

    let top: String
    /// Nil while HEAD is detached with nothing to name it by.
    let branch: String?
    /// HEAD is detached, and `branch` is what names it.
    var detached = false
    var style: Style = .panel
    let changed: () -> Void
    @State private var shown = false

    private var title: String {
        guard let branch else { return "detached HEAD" }
        return detached ? "HEAD \(branch)" : branch
    }

    var body: some View {
        Button { shown.toggle() } label: { label }
            .buttonStyle(.plain)
            .modifier(StatusLinkHover(on: style == .statusBar))
            .accessibilityLabel("Branch")
            .accessibilityValue(title)
            .accessibilityHint("Opens the branch picker")
            .popover(isPresented: $shown, arrowEdge: style == .panel ? .bottom : .top) {
                BranchPickerPanel(top: top, changed: changed) { shown = false }
            }
    }

    @ViewBuilder
    private var label: some View {
        let name = Text(title).font(Theme.monoFont).lineLimit(1).truncationMode(.middle)
        let help = (detached ? "Detached HEAD\n" : "") + "Switch branch, or create one\n" + abbreviateHome(top)
        if style == .statusBar {
            StatusChip(tone: detached ? .warning : .normal, help: help) {
                OctetIcon("branch", size: 13)
                name
            }
        } else {
            HStack(spacing: 6) {
                OctetIcon("arrow.triangle.branch", size: 11).foregroundStyle(Theme.textTertiary)
                name.foregroundStyle(Theme.textPrimary)
                OctetIcon("chevron.down", size: 9).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .help(help)
        }
    }
}

/// The searchable list: local branches (the current one marked, recent
/// first), remote-only ones, and the ways to create or check one out.
struct BranchPickerPanel: View {
    @StateObject private var model: BranchPickerModel
    @State private var highlighted: String?
    @FocusState private var searching: Bool

    init(top: String, changed: @escaping () -> Void, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: BranchPickerModel(top: top, changed: changed, close: close))
    }

    var body: some View {
        let rows = model.visible
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                OctetIcon("magnifyingglass", size: 12).foregroundStyle(Theme.textTertiary)
                TextField("Search or name a new branch", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($searching)
                    .onSubmit { submit(rows) }
                    .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                if let busy = model.busy {
                    LoadingLine(width: 12)
                        .help(busy)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            if let failure = model.failure { ServiceBanner(text: failure).padding(.top, 6) }
            if let held = model.held { stashPrompt(held) }
            list(rows)
            if model.canCreate { createRows }
            if let base = model.base { baseNote(base) }
        }
        .frame(width: 300)
        .background(Theme.card)
        .onAppear {
            model.load()
            DispatchQueue.main.async { searching = true }
        }
        .onChange(of: model.query) { _, _ in highlighted = nil }
        .onExitCommand { model.failure = nil }
    }

    // MARK: Parts

    @ViewBuilder
    private func list(_ rows: [GitBranches.Entry]) -> some View {
        if !model.loaded {
            LoadingLine(width: 14).frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if rows.isEmpty {
            Text(model.query.isEmpty ? "No branches." : "No branch matches.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    section("LOCAL", rows.filter { !$0.isRemote })
                    section("REMOTE", rows.filter(\.isRemote))
                }
                .padding(4)
            }
            .frame(maxHeight: 260)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [GitBranches.Entry]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { entry in
                BranchRow(entry: entry, highlighted: highlighted == entry.id,
                          isBase: model.base == entry.name,
                          choose: { model.checkOut(entry) },
                          worktree: { model.openInWorktree(entry) },
                          branchFrom: { model.base = model.base == entry.name ? nil : entry.name })
                    .onHover { if $0 { highlighted = entry.id } }
            }
        }
    }

    private var createRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.bottom, 3)
            PickerAction(icon: "plus", title: "Create branch", name: model.newName, note: "from " + (model.base ?? model.current?.name ?? "HEAD")) {
                model.create(inWorktree: false)
            }
            PickerAction(icon: "square.stack.3d.up", title: "Create in a new worktree", name: model.newName, note: nil) {
                model.create(inWorktree: true)
            }
        }
        .padding(4)
    }

    private func baseNote(_ base: String) -> some View {
        HStack(spacing: 6) {
            Text("New branches start from").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            Text(base).font(Theme.monoFont).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            OctetIconButton(icon: "xmark", help: "Start from the current branch again", compact: true) { model.base = nil }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 3)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    /// Changes in the tree: stash them and go on, or stay.
    private func stashPrompt(_ held: BranchPickerModel.Held) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Recap.count(held.files, "file")) changed here. Stash \(held.files == 1 ? "it" : "them") to continue? Nothing is discarded.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                OctetButton(title: "Stash and Continue", kind: .primary, compact: true) { model.stashAndContinue() }
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { model.held = nil }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
        .padding(.horizontal, 8).padding(.top, 6)
    }

    // MARK: Keys

    private func move(_ step: Int, in rows: [GitBranches.Entry]) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : rows.count)
        highlighted = rows[min(rows.count - 1, max(0, index + step))].id
    }

    private func submit(_ rows: [GitBranches.Entry]) {
        if let entry = rows.first(where: { $0.id == highlighted }) ?? (model.canCreate ? nil : rows.first) {
            model.checkOut(entry)
        } else if model.canCreate {
            model.create(inWorktree: false)
        }
    }
}

private struct BranchRow: View {
    let entry: GitBranches.Entry
    let highlighted: Bool
    let isBase: Bool
    let choose: () -> Void
    let worktree: () -> Void
    let branchFrom: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if entry.isCurrent { OctetIcon("checkmark", size: 11).foregroundStyle(Theme.textPrimary) }
                else if entry.worktree != nil { OctetIcon("square.stack.3d.up", size: 11).foregroundStyle(Theme.textTertiary) }
                else { Color.clear }
            }
            .frame(width: 14)
            Text(entry.name)
                .font(Theme.monoFont)
                .foregroundStyle(entry.checkedOutElsewhere ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hovered && !entry.isCurrent {
                if entry.worktree == nil {
                    OctetIconButton(icon: "square.stack.3d.up", help: "Check out in a new worktree", compact: true, action: worktree)
                }
                OctetIconButton(icon: "arrow.triangle.branch", help: isBase ? "Stop starting new branches from here" : "Start new branches from here",
                                active: isBase, compact: true, action: branchFrom)
            } else {
                if entry.ahead > 0 { count("arrow.up", entry.ahead) }
                if entry.behind > 0 { count("arrow.down", entry.behind) }
                Text(entry.isCurrent ? "current" : GitBranches.age(entry.date))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered || highlighted ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovered = $0 }
        .help(entry.checkedOutElsewhere ? "Checked out in \(abbreviateHome(entry.worktree ?? ""))\nClick to open it" : entry.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func count(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 1) {
            OctetIcon(icon, size: 9)
            Text("\(value)").font(Theme.captionFont.monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
    }
}

private struct PickerAction: View {
    let icon: String
    let title: String
    let name: String
    let note: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OctetIcon(icon, size: 12).foregroundStyle(Theme.textTertiary).frame(width: 14)
                Text(title).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                Text(name).font(Theme.monoFont).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let note {
                    Text(note).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct StatusLinkHover: ViewModifier {
    let on: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if on { content.modifier(LinkHover()) } else { content }
    }
}
