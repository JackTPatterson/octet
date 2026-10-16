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
        #endif
        return window.focusedDirectory
    }

    var body: some View {
        Group {
            if let model {
                DiffPlaneBody(model: model, store: store, ui: ui)
            } else {
                PlaneMessage(icon: "doc.diff", title: "No project in front",
                             detail: "Open a tab in a project folder to see what changed.")
            }
        }
        .onAppear { follow(directory) }
        .onChange(of: directory) { _, directory in follow(directory) }
        .onChange(of: visible, initial: true) { _, visible in
            if visible { model?.start() } else { model?.stop() }
        }
        .onDisappear { model?.stop() }
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
    /// Files folded to their header, by path.
    @State private var folded: Set<String> = []
    /// Paths seen, so a file that turns up later starts folded or not by the
    /// same rule as the rest, and folding survives refreshes.
    @State private var seen: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
            if !model.comments.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                notesFooter
            }
        }
        .onChange(of: model.diff?.files.map(\.path) ?? [], initial: true) { _, paths in
            // Many files start folded, so the list reads as a summary first.
            let fresh = paths.filter { !seen.contains($0) }
            if paths.count > 3 { folded.formUnion(fresh) }
            seen.formUnion(fresh)
        }
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
            } label: {
                HStack(spacing: 4) {
                    Text(model.base == .branch ? "This Branch" : "Uncommitted")
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                    OctetIcon("chevron.down", size: 10).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
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
            if model.loading { ProgressView().controlSize(.mini) }
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
        if model.notARepository {
            PlaneMessage(icon: "doc.diff", title: "Not a Git repository",
                         detail: "Diffs need a Git repository. This folder isn't in one.")
        } else if let diff = model.diff {
            if diff.files.isEmpty {
                PlaneMessage(icon: "doc.diff", title: "No changes",
                             detail: model.base == .branch ? "This branch has nothing the default branch doesn't."
                                                          : "Nothing is uncommitted here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(diff.files) { file in
                            Section {
                                if !folded.contains(file.path) { fileBody(file) }
                            } header: {
                                DiffPlaneFileHeader(file: file, folded: folded.contains(file.path),
                                                    notes: model.comments.filter { $0.path == file.path }.count) {
                                    MotionPreferences.shared.perform(.sidebar) {
                                        if folded.contains(file.path) { folded.remove(file.path) } else { folded.insert(file.path) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .octetScrollIndicators()
            }
        } else {
            VStack(spacing: 8) {
                LoadingLine()
                Text("Loading changes…").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileBody(_ file: ReviewDiff.File) -> some View {
        if file.binary {
            fileNote("Binary file; there's no text to show.")
        } else if file.tooLarge {
            fileNote("Too large to show here: +\(file.added) −\(file.removed).")
        } else {
            let colored = DiffReviewView.colors(file)
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
                    ForEach(hunk.lines) { line in
                        DiffReviewLine(line: line, path: file.path, text: colored[line.index], model: model, wraps: true)
                    }
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

    // MARK: - Notes

    private var notesFooter: some View {
        let agents = DiffReviewView.agents(in: store, directory: model.directory)
        let target = agents.first
        let count = model.comments.count
        return HStack(spacing: 8) {
            Text("\(count) \(count == 1 ? "note" : "notes")")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
            OctetButton(title: "Clear", kind: .ghost, compact: true) { model.comments = [] }
            Spacer(minLength: 4)
            OctetButton(title: target.map { "Send to \(DiffReviewView.name($0, in: store))" } ?? "No Agent Here",
                        icon: "arrow.up", kind: target == nil ? .secondary : .primary, compact: true) {
                guard let target else { return }
                let prompt = ReviewComment.prompt(model.comments)
                guard !prompt.isEmpty else { return }
                store.broadcast(prompt, to: [Broadcast.Target(paneId: target.paneId,
                                                              name: DiffReviewView.name(target, in: store),
                                                              isAgent: true)])
                model.comments = []
            }
            .disabled(target == nil)
            .help("Send the notes to the agent working here as one message")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

/// A file's row: fold chevron, status, name and folder, notes and +/−.
/// Pinned while its lines scroll by.
private struct DiffPlaneFileHeader: View {
    let file: ReviewDiff.File
    let folded: Bool
    let notes: Int
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                OctetIcon("chevron.right", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                Text(mark)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 10)
                Text((file.path as NSString).lastPathComponent)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                if notes > 0 {
                    Text("\(notes)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                        .help("\(notes) \(notes == 1 ? "note" : "notes") on this file")
                }
                if file.binary {
                    Text("bin").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                } else {
                    DiffStatLabel(added: file.added, removed: file.removed)
                }
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

    private var mark: String {
        switch file.status {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        }
    }

    private var color: Color {
        switch file.status {
        case .added: DiffReviewView.addedColor
        case .deleted: Theme.danger
        case .modified: Theme.accent
        }
    }
}

/// A plane's centred message: a mark, a title and what to do.
struct PlaneMessage: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            OctetIcon(icon, size: 20).foregroundStyle(Theme.textTertiary).padding(.bottom, 2)
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
