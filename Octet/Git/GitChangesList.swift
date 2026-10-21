import SwiftUI

/// The changed files as one list in up to three groups (Staged, Changes,
/// Untracked), each under a header with a count. Only groups that have files
/// are drawn. A group's bulk action appears when its header is hovered, and
/// is always in its menu and context menu. A long group shows its first
/// files and more on request.
struct GitChangesList: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group
    /// The files to show, already narrowed by the editor filter.
    let files: [AgentGit.FileChange]
    /// How many of each group show; "Show 200 more" raises it.
    @State private var shown: [GitChangeGroups.Kind: Int] = [:]

    private var checkout: AgentGit.Checkout { group.checkout }
    static let page = 200

    var body: some View {
        let groups = GitChangeGroups(files: files)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.visible.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 0) {
                    GitChangeGroupHeader(
                        title: section.kind.title, count: section.files.count,
                        bulk: groups.bulkAction(for: section.kind),
                        busy: model.busy[checkout.top] != nil,
                        perform: { action in
                            switch action {
                            case .stageAll: model.stageAll(checkout)
                            case .unstageAll: model.unstageAll(checkout)
                            }
                        },
                        // The first header carries the totals and Review.
                        trailing: index == 0 ? AnyView(totals) : AnyView(EmptyView()))
                    let limit = shown[section.kind] ?? Self.page
                    ForEach(section.files.prefix(limit)) { file in
                        GitFileRow(file: file, editors: group.editors[file.path] ?? [],
                                   open: { model.review(checkout.top, path: file.path) },
                                   toggleStaged: { model.toggleStaged(file, in: checkout.top) },
                                   discard: { model.discard(file, in: checkout.top) })
                    }
                    if section.files.count > limit {
                        let more = min(Self.page, section.files.count - limit)
                        Button { shown[section.kind] = limit + Self.page } label: {
                            Text("Show \(more) more · \(section.files.count - limit) not shown")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.top, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var totals: some View {
        HStack(spacing: 8) {
            LineCounts(added: checkout.added, removed: checkout.removed)
            Button("Review") { model.review(checkout.top) }
                .buttonStyle(.plain)
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(Theme.accent)
                .help("Open the changes review (⌘⇧R)")
        }
    }
}

private struct GitChangeGroupHeader: View {
    let title: String
    let count: Int
    let bulk: GitChangeGroups.BulkAction?
    let busy: Bool
    let perform: (GitChangeGroups.BulkAction) -> Void
    let trailing: AnyView
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 15)
                .background(Capsule().fill(Theme.card))
            if hovered, let bulk {
                Button(label(bulk)) { perform(bulk) }
                    .buttonStyle(.plain)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(busy)
            }
            Spacer(minLength: 4)
            trailing
            if bulk != nil {
                OctetIconButton(icon: "ellipsis", help: "\(title) actions", compact: true) { presentMenu() }
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            if let bulk { Button(label(bulk)) { perform(bulk) }.disabled(busy) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private func label(_ bulk: GitChangeGroups.BulkAction) -> String {
        bulk == .stageAll ? "Stage All" : "Unstage All"
    }

    private func presentMenu() {
        guard let bulk else { return }
        OctetContextMenu.present([
            .action(label(bulk), icon: bulk == .stageAll ? "plus" : "minus", enabled: !busy) { perform(bulk) },
        ])
    }
}

/// One changed file: its status, name and folder, then at the row's end who
/// edited it and its line counts, or on hover what can be done to it.
struct GitFileRow: View {
    let file: AgentGit.FileChange
    /// The agents whose edit tools changed it; none when it was changed
    /// from a shell or by hand.
    let editors: [GitPanelModel.Worker]
    let open: () -> Void
    let toggleStaged: () -> Void
    let discard: () -> Void
    @State private var hovered = false

    var body: some View {
        DiffFileRow(path: file.path, mark: ChangeMark(file.kind), added: file.added, removed: file.removed) {
            if hovered {
                rowButton("doc.text.magnifyingglass", help: "Open diff", action: open)
                rowButton(file.staged ? "minus" : "plus", help: file.staged ? "Unstage" : "Stage", action: toggleStaged)
                if file.kind != .conflicted {
                    rowButton("arrow.uturn.backward", help: "Discard changes", action: discard)
                }
            } else {
                if !editors.isEmpty {
                    WorkerMarks(workers: editors, size: 9, limit: 2)
                        .help("Edited by " + editors.map(\.name).joined(separator: ", "))
                }
                LineCounts(added: file.added, removed: file.removed)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .help(file.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.path), \(kindName)\(file.staged ? ", staged" : "")")
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
            OctetIcon(icon, size: 12)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var kindName: String {
        switch file.kind {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        }
    }
}
