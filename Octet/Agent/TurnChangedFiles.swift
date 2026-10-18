import SwiftUI

/// Under a finished turn, the files it edited as a folder tree with +/−
/// counts, after T3 Code's changed-files card. A file opens the Diff plane
/// on that turn; its chevron shows the turn's edits to it inline, and the
/// document button opens it in the editor.
struct TurnChangedFilesCard: View {
    let changes: TurnChanges
    @Environment(\.transcriptActions) private var actions
    @State private var open = true
    @State private var collapsedFolders: Set<String> = []
    @State private var previewing: Set<String> = []

    private var root: String? { actions.cwd }

    var body: some View {
        let tree = ChangedFileNode.tree(changes.files, root: root)
        let folders = Self.folderPaths(tree)
        VStack(alignment: .leading, spacing: 0) {
            header(hasFolders: !folders.isEmpty, allCollapsed: !folders.isEmpty && folders.allSatisfy(collapsedFolders.contains),
                   folders: folders)
            if open {
                Rectangle().fill(Theme.divider).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.rows(tree, collapsed: collapsedFolders), id: \.node.id) { row in
                        rowView(row.node, depth: row.depth)
                        if case .file(_, let file) = row.node, previewing.contains(file.path), !file.lines.isEmpty {
                            DiffView(lines: file.lines, path: file.path, startLine: nil)
                                .padding(.leading, CGFloat(row.depth) * 14 + 26)
                                .padding(.trailing, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.card.opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files changed in turn \(changes.number)")
    }

    private func header(hasFolders: Bool, allCollapsed: Bool, folders: [String]) -> some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    OctetIcon("chevron.right", size: 11)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(changes.files.count) changed \(changes.files.count == 1 ? "file" : "files")")
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                    DiffStatLabel(added: changes.added, removed: changes.removed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            Spacer(minLength: 4)
            if hasFolders && open {
                OctetIconButton(icon: allCollapsed ? "chevron.down.square" : "chevron.up.square",
                                help: allCollapsed ? "Expand all folders" : "Collapse all folders", compact: true) {
                    collapsedFolders = allCollapsed ? [] : Set(folders)
                }
            }
            OctetButton(title: "Open Diff", icon: "doc.diff", kind: .ghost, compact: true) {
                actions.openTurnDiff(changes, nil)
            }
            .help("Show this turn's changes in the Diff plane")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 34)
    }

    @ViewBuilder
    private func rowView(_ node: ChangedFileNode, depth: Int) -> some View {
        switch node {
        case .folder(let name, let path, _):
            let collapsed = collapsedFolders.contains(path)
            ChangedFileRow(depth: depth, added: node.added, removed: node.removed, action: {
                if collapsed { collapsedFolders.remove(path) } else { collapsedFolders.insert(path) }
            }) {
                OctetIcon("chevron.right", size: 10)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(Theme.textTertiary)
                OctetIcon("folder", size: 13).foregroundStyle(Theme.textTertiary)
                Text(name).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            } trailing: { EmptyView() }
            .accessibilityLabel("Folder \(name)")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        case .file(let name, let file):
            let shown = previewing.contains(file.path)
            ChangedFileRow(depth: depth, added: file.added, removed: file.removed, action: {
                actions.openTurnDiff(changes, file.path)
            }) {
                OctetIconButton(icon: "chevron.right", help: shown ? "Hide this turn's edits" : "Show this turn's edits",
                                compact: true) {
                    if shown { previewing.remove(file.path) } else { previewing.insert(file.path) }
                }
                .rotationEffect(.degrees(shown ? 90 : 0))
                .frame(width: 14)
                if let logo = LanguageLogo(path: file.path, size: 12) { logo } else {
                    OctetIcon("doc", size: 13).foregroundStyle(Theme.textTertiary)
                }
                Text(name).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if file.created {
                    Text("new").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            } trailing: {
                OctetIconButton(icon: "doc.text.magnifyingglass", help: "Open \(name) in the editor", compact: true) {
                    actions.openFile(file.path)
                }
            }
            .help("Open this turn's diff of \(TurnChanges.relative(file.path, to: root))")
            .accessibilityLabel("File \(name)")
        }
    }

    struct Row { let node: ChangedFileNode; let depth: Int }

    /// The tree flattened to the rows on show: a collapsed folder's
    /// contents are left out.
    static func rows(_ nodes: [ChangedFileNode], collapsed: Set<String>, depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            guard case .folder(_, let path, let children) = node else { return [Row(node: node, depth: depth)] }
            return [Row(node: node, depth: depth)]
                + (collapsed.contains(path) ? [] : rows(children, collapsed: collapsed, depth: depth + 1))
        }
    }

    static func folderPaths(_ nodes: [ChangedFileNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            guard case .folder(_, let path, let children) = node else { return [] }
            return [path] + folderPaths(children)
        }
    }
}

/// One row of the changed-files tree: indented, a fill under the pointer,
/// the line counts at the end, extra buttons showing on hover.
private struct ChangedFileRow<Label: View, Trailing: View>: View {
    let depth: Int
    let added: Int
    let removed: Int
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            label()
            Spacer(minLength: 6)
            if hovered { trailing() }
            DiffStatLabel(added: added, removed: removed)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover.opacity(0.7) : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// Each finished turn's changed files, by the id of the shown item it ends
/// on, worked out again only when a turn starts or ends or a tool call
/// changes, not on every streamed word.
final class TurnChangesCache {
    private var signature: Int?
    private var cached: [String: TurnChanges] = [:]

    func turns(_ items: [AgentItem], cwd: String?, running: Bool,
               isShown: (AgentItem) -> Bool) -> [String: TurnChanges] {
        var hasher = Hasher()
        hasher.combine(running)
        hasher.combine(cwd)
        hasher.combine(items.count)
        for item in items {
            switch item.kind {
            case .user:
                hasher.combine(item.id)
                hasher.combine(item.queued)
            case .tool(let call):
                hasher.combine(item.id)
                hasher.combine(call.result != nil)
                hasher.combine(call.isError)
                hasher.combine(call.inputData?.count ?? 0)
            default:
                break
            }
        }
        if let last = items.last { hasher.combine(last.id) }
        let signature = hasher.finalize()
        if signature == self.signature { return cached }
        self.signature = signature
        cached = Self.compute(items, cwd: cwd, running: running, isShown: isShown)
        return cached
    }

    static func compute(_ items: [AgentItem], cwd: String?, running: Bool,
                        isShown: (AgentItem) -> Bool) -> [String: TurnChanges] {
        let shown = Set(items.filter(isShown).map(\.id))
        var result: [String: TurnChanges] = [:]
        for turn in TurnChanges.derive(items, cwd: cwd, running: running) {
            // A hidden last item (an empty thinking block) hands the card to
            // the last shown one before it.
            let last = shown.contains(turn.lastItemId) ? turn.lastItemId
                : items.prefix { $0.id != turn.lastItemId }.last { shown.contains($0.id) }?.id
            if let last { result[last] = turn }
        }
        return result
    }
}
