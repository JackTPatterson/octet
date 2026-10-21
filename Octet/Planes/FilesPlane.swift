import AppKit
import SwiftUI

/// The Files plane: the project in front as a tree, after T3 Code's Files
/// surface. Folders fold; search narrows to a flat list of matches; a file
/// opens beside the terminal in Octet's editor.
struct FilesPlane: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var ui: UIState
    let directory: String?
    @StateObject private var model = FilesPlaneModel()
    @State private var query = ""
    @State private var open: Set<String> = []
    /// The folder a breadcrumb asked for, to scroll to once the tree has it.
    @State private var scrollTarget: String?
    @FocusState private var searchFocused: Bool

    private var root: String? {
        directory.map { AccountProfiles.projectRoot(of: $0) ?? $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .onAppear { if let root { model.load(root) } }
        .onChange(of: root) { _, root in
            open = []
            if let root { model.load(root) }
        }
        .onReceive(window.editor.$folderReveal) { request in
            guard let request else { return }
            window.editor.folderReveal = nil
            reveal(request.path)
        }
        .onChange(of: ui.showing(.files)) { _, shown in
            // Back in front: pick up files made since.
            if shown, let root { model.load(root, force: true) }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                OctetIcon("folder", size: 13).foregroundStyle(Theme.textTertiary)
                Text(root.map { ($0 as NSString).lastPathComponent } ?? "Files")
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !model.files.isEmpty {
                    Text(model.truncated ? "first \(model.files.count.formatted()) files" : "\(model.files.count) files")
                        .font(Theme.captionFont)
                        .foregroundStyle(model.truncated ? Theme.warning : Theme.textTertiary)
                        .monospacedDigit()
                        .help(model.truncated
                              ? "This project has more files than Octet lists. Files past the limit won't show or match a search."
                              : model.fromGit ? "Files git tracks, plus new ones .gitignore doesn't exclude" : "")
                }
                Spacer(minLength: 4)
                if model.loading || PlaneLoadingPreview.shows("files") { LoadingLine(width: 12) }
                OctetIconButton(icon: "chevron.up.square", help: "Collapse all folders") {
                    MotionPreferences.shared.perform(.sidebar) { open = [] }
                }
                .disabled(open.isEmpty)
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh files") {
                    if let root { model.load(root, force: true) }
                }
            }
            // T3 Code's search row: no box, a fill when in use.
            HStack(spacing: 8) {
                OctetIcon("magnifyingglass", size: 13).foregroundStyle(Theme.textTertiary)
                TextField("Search files", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { openFile(first.path) } }
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        OctetIcon("xmark", size: 11).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(searchFocused || !query.isEmpty ? Theme.cardSelected : Theme.card.opacity(0.6)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if PlaneLoadingPreview.shows("files") {
            FilesPlaneSkeleton()
        } else if root == nil {
            OctetEmptyState(icon: "folder", title: "No project in front",
                            message: "Open a tab in a project folder to browse its files.", compact: true)
        } else if model.files.isEmpty {
            if model.loading && !model.loaded {
                FilesPlaneSkeleton().overlay(alignment: .bottom) { LoadingLine().padding(8) }
            } else {
                OctetEmptyState(icon: "folder", title: "No files", message: "This folder is empty.", compact: true)
            }
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if matches.isEmpty {
                OctetEmptyState(icon: "magnifyingglass", title: "No files match",
                                message: "Nothing here matches “\(query)”.", compact: true,
                                actionTitle: "Clear Search") { query = "" }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(matches.prefix(200), id: \.path) { item in
                            FileRow(name: (item.relativePath as NSString).lastPathComponent,
                                    detail: (item.relativePath as NSString).deletingLastPathComponent,
                                    isFolder: false, isOpen: false, depth: 0,
                                    mark: model.status.files[item.relativePath]) { openFile(item.path) }
                                .contextMenu { fileMenu(item.path, relative: item.relativePath) }
                        }
                    }
                    .padding(6)
                }
                .octetScrollIndicators()
            }
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(FileTreeNode.rows(model.tree, open: open), id: \.node.path) { row in
                        let node = row.node
                        FileRow(name: node.name, detail: nil, isFolder: node.isFolder,
                                isOpen: open.contains(node.path), depth: row.depth,
                                mark: node.isFolder ? nil : model.status.files[node.path],
                                holdsChanges: node.isFolder && model.status.folders.contains(node.path)) {
                            if node.isFolder {
                                MotionPreferences.shared.perform(.sidebar, .easeOut(duration: 0.15)) {
                                    if open.contains(node.path) { open.remove(node.path) } else { open.insert(node.path) }
                                }
                            } else if let root {
                                openFile(root + "/" + node.path)
                            }
                        }
                        .contextMenu { if let root { fileMenu(root + "/" + node.path, relative: node.path) } }
                        .id(node.path)
                    }
                }
                .padding(6)
            }
            .octetScrollIndicators()
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                scrollTarget = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    MotionPreferences.shared.perform(.sidebar) { proxy.scrollTo(target, anchor: .top) }
                }
            }
            }
        }
    }

    /// Opens every folder down to `folder` and scrolls to it.
    private func reveal(_ folder: String) {
        guard let root else { return }
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else { return }
        query = ""
        var path = ""
        var opened = open
        for part in target.dropFirst(base.count + 1).split(separator: "/") {
            path += (path.isEmpty ? "" : "/") + part
            opened.insert(path)
        }
        MotionPreferences.shared.perform(.sidebar) { open = opened }
        scrollTarget = path
    }

    private var matches: [EditorFileItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return model.files
            .compactMap { item in FuzzyMatcher.match(needle, in: item.relativePath).map { (item, $0.score) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func openFile(_ path: String) {
        window.openFile(URL(fileURLWithPath: path), presentation: .full)
    }

    @ViewBuilder
    private func fileMenu(_ path: String, relative: String) -> some View {
        Button("Open") { openFile(path) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Divider()
        Button("Copy Path") { copy(path) }
        Button("Copy Relative Path") { copy(relative) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A row in the tree: indented by depth, a chevron for folders.
private struct FileRow: View {
    let name: String
    let detail: String?
    let isFolder: Bool
    let isOpen: Bool
    let depth: Int
    /// What git says about the file: modified, added, untracked…
    var mark: ProjectGitStatus.Mark?
    /// A folder with a change somewhere inside it.
    var holdsChanges = false
    let action: () -> Void
    @State private var hovered = false

    private var markColor: Color {
        switch mark {
        case .added, .untracked: Theme.success
        case .deleted, .conflicted: Theme.danger
        case .modified, .renamed: Theme.warning
        case nil: Theme.textTertiary
        }
    }

    private var markName: String {
        switch mark {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        case nil: ""
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if isFolder {
                        OctetIcon("chevron.right", size: 10)
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                if isFolder {
                    OctetIcon("folder", size: 13).foregroundStyle(Theme.textSecondary)
                } else {
                    FileTypeIcon(name: name)
                }
                Text(name)
                    .font(Theme.uiFont)
                    .foregroundStyle(mark == nil ? Theme.textPrimary : markColor)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if let mark {
                    Text(mark.rawValue)
                        .font(Theme.Text.mono(10, weight: .semibold))
                        .foregroundStyle(markColor)
                        .help("\(markName.capitalized) since the last commit")
                } else if holdsChanges {
                    Circle().fill(Theme.warning.opacity(0.8)).frame(width: 5, height: 5)
                        .help("Has changes inside")
                }
            }
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityValue([isFolder ? (isOpen ? "Expanded" : "Collapsed") : nil,
                             mark == nil ? nil : markName, holdsChanges ? "has changes" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// The Files plane's tree, from the shared project index, and git's marks.
@MainActor
final class FilesPlaneModel: ObservableObject {
    @Published private(set) var files: [EditorFileItem] = []
    @Published private(set) var tree: [FileTreeNode] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var truncated = false
    @Published private(set) var fromGit = false
    @Published private(set) var status = ProjectGitStatus.empty
    private var loadedRoot: String?

    func load(_ root: String, force: Bool = false) {
        guard force || loadedRoot != root else { return }
        if loadedRoot != root {
            loaded = false
            files = []
            tree = []
            status = .empty
        }
        loadedRoot = root
        loading = true
        ProjectFileIndexStore.shared.load(root, force: force) { [weak self] entry in
            guard let self, self.loadedRoot == root else { return }
            Task {
                let items = entry.items
                let (tree, status) = await Task.detached(priority: .userInitiated) {
                    (FileTreeNode.build(items.map(\.relativePath)), ProjectGitStatus.read(root: root))
                }.value
                guard self.loadedRoot == root else { return }
                self.files = items
                self.tree = tree
                self.status = status
                self.truncated = entry.truncated
                self.fromGit = entry.fromGit
                self.loading = false
                self.loaded = true
            }
        }
    }
}
