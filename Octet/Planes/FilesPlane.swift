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
                    Text("\(model.files.count) files")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
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
            PlaneMessage(icon: "folder", title: "No project in front",
                         detail: "Open a tab in a project folder to browse its files.")
        } else if model.files.isEmpty {
            if model.loading && !model.loaded {
                FilesPlaneSkeleton().overlay(alignment: .bottom) { LoadingLine().padding(8) }
            } else {
                PlaneMessage(icon: "folder", title: "No files", detail: "This folder is empty.")
            }
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if matches.isEmpty {
                PlaneMessage(icon: "magnifyingglass", title: "No matches", detail: "No file here matches “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(matches.prefix(200), id: \.path) { item in
                            FileRow(name: (item.relativePath as NSString).lastPathComponent,
                                    detail: (item.relativePath as NSString).deletingLastPathComponent,
                                    isFolder: false, isOpen: false, depth: 0) { openFile(item.path) }
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
                                isOpen: open.contains(node.path), depth: row.depth) {
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
        window.openFile(URL(fileURLWithPath: path))
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
    let action: () -> Void
    @State private var hovered = false

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
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityValue(isFolder ? (isOpen ? "Expanded" : "Collapsed") : "")
    }
}

@MainActor
final class FilesPlaneModel: ObservableObject {
    @Published private(set) var files: [EditorFileItem] = []
    @Published private(set) var tree: [FileTreeNode] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    private var loadedRoot: String?

    func load(_ root: String, force: Bool = false) {
        guard force || loadedRoot != root else { return }
        if loadedRoot != root {
            loaded = false
            files = []
            tree = []
        }
        loadedRoot = root
        loading = true
        Task {
            let (files, tree) = await Task.detached(priority: .userInitiated) {
                let files = EditorFileIndex.files(in: root)
                return (files, FileTreeNode.build(files.map(\.relativePath)))
            }.value
            guard self.loadedRoot == root else { return }
            self.files = files
            self.tree = tree
            self.loading = false
            self.loaded = true
        }
    }
}
