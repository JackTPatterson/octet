import AppKit
import SwiftUI

/// The grouped editor surface. File tabs live inside one Octet tab, leaving
/// the outer strip for terminal/conversation-level context switches.
struct CodeEditorView: View {
    @ObservedObject var workspace: EditorWorkspace
    let rootDirectory: String

    var body: some View {
        VStack(spacing: 0) {
            editorTabs
            HStack(spacing: 0) {
                if workspace.fileTreeVisible {
                    EditorFileTree(rootDirectory: rootDirectory, workspace: workspace)
                        .frame(width: 225)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
                if let document = workspace.activeDocument {
                    EditorDocumentView(document: document, workspace: workspace)
                        .id(document.id)
                } else {
                    editorEmptyState
                }
            }
        }
        .background(Theme.terminalBackground)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { workspace.focusEditor() }
        }
        .onChange(of: workspace.activeID) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { workspace.focusEditor() }
        }
    }

    private var editorTabs: some View {
        HStack(spacing: 0) {
            Button { workspace.fileTreeVisible.toggle() } label: {
                OctetIcon("folder", size: 15)
                    .foregroundStyle(workspace.fileTreeVisible ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workspace.fileTreeVisible ? "Hide Files" : "Show Files")
            Rectangle().fill(Theme.divider).frame(width: 1, height: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.documents) { document in
                        EditorFileTab(document: document, workspace: workspace)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { workspace.filePickerVisible = true } label: {
                OctetIcon("plus", size: 14)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .help("Open File (⌘O)")
            Button { workspace.togglePresentation() } label: {
                OctetIcon(workspace.presentation == .split ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1", size: 14)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .help(workspace.presentation == .split ? "Open Editor Full Screen" : "Show Editor Beside Terminal")
            Button { workspace.closeEditor() } label: {
                OctetIcon("xmark", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .help("Close Editor (⌘W)")
        }
        .frame(height: 32)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var editorEmptyState: some View {
        VStack(spacing: 10) {
            OctetIcon("tool.edit", size: 28).foregroundStyle(Theme.textTertiary)
            Text("Open a file to start editing").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("Search this workspace with ⌘O")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            OctetButton(title: "Open File", icon: "folder", compact: true) {
                workspace.filePickerVisible = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    let workspace: EditorWorkspace

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorTextView(document: document, workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            HStack(spacing: 8) {
                Text(document.url.path)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if let error = document.lastError {
                    OctetIcon("xmark.circle.fill", size: 12).foregroundStyle(Theme.danger)
                    Text(error).lineLimit(1)
                }
                Text("\(document.lineCount) lines")
                Text("UTF-8")
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .background(Theme.chrome)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }
}

private struct EditorFileTab: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var workspace: EditorWorkspace
    @State private var hovered = false

    var body: some View {
        let active = workspace.activeID == document.id
        HStack(spacing: 7) {
            if let logo = LanguageLogo(path: document.url.path, size: 12) { logo }
            else { OctetIcon("doc", size: 13).foregroundStyle(Theme.textSecondary) }
            Text(document.name)
                .font(Theme.uiFont)
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if document.isDirty {
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
            } else if hovered || active {
                Button { workspace.close(document) } label: {
                    OctetIcon("xmark", size: 12).foregroundStyle(Theme.textSecondary).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, maxWidth: 210, minHeight: 32, maxHeight: 32)
        .background(active ? Theme.terminalBackground : hovered ? Theme.hover : Color.clear)
        .overlay(alignment: .bottom) {
            if active { Rectangle().fill(Color.white.opacity(0.82)).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(document) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Save") { document.save() }.disabled(!document.isDirty)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            Divider()
            Button("Close") { workspace.close(document) }
        }
        .help(document.url.path)
    }
}

@MainActor
private final class EditorFilesModel: ObservableObject {
    @Published var files: [EditorFileItem] = []
    @Published var loading = false
    private var loadedRoot: String?

    func load(_ root: String) {
        guard loadedRoot != root else { return }
        loadedRoot = root
        loading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { EditorFileIndex.files(in: root) }.value
            guard self.loadedRoot == root else { return }
            self.files = result
            self.loading = false
        }
    }
}

private struct EditorFileTree: View {
    let rootDirectory: String
    @ObservedObject var workspace: EditorWorkspace
    @StateObject private var model = EditorFilesModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                OctetIcon("folder", size: 13).foregroundStyle(Theme.textSecondary)
                Text(URL(fileURLWithPath: rootDirectory).lastPathComponent)
                    .font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                if model.loading { LoadingLine(width: 14) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.files) { file in
                        Button { workspace.open(URL(fileURLWithPath: file.path)) } label: {
                            HStack(spacing: 7) {
                                if let logo = LanguageLogo(path: file.path, size: 12) { logo }
                                else { OctetIcon("doc", size: 12).foregroundStyle(Theme.textTertiary) }
                                Text(file.relativePath)
                                    .font(Theme.monoFont)
                                    .foregroundStyle(workspace.activeID == file.path ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                            .background(workspace.activeID == file.path ? Theme.cardSelected : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 5)
            }
            .octetScrollIndicators()
        }
        .background(Theme.sidebar)
        .onAppear { model.load(rootDirectory) }
        .onChange(of: rootDirectory) { _, root in model.load(root) }
    }
}

/// Workspace file search reuses the same panel and moving-list primitives as
/// slash commands, @ references and the main command palette.
struct EditorFilePickerView: View {
    let rootDirectory: String
    @ObservedObject var workspace: EditorWorkspace
    @StateObject private var model = EditorFilesModel()
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [EditorFileItem] {
        guard !query.isEmpty else { return Array(model.files.prefix(14)) }
        let terms = query.lowercased().split(separator: " ")
        return Array(model.files.lazy.filter { item in
            let haystack = item.relativePath.lowercased()
            return terms.allSatisfy(haystack.contains)
        }.prefix(14))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: close)
            OctetPalettePanel(style: .floating, divider: .none) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        OctetIcon("magnifyingglass", size: 17).foregroundStyle(Theme.textSecondary)
                        TextField("Open file in \(URL(fileURLWithPath: rootDirectory).lastPathComponent)…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($focused)
                            .onChange(of: query) { _, _ in highlighted = 0 }
                            .onKeyPress(.upArrow) { move(-1) }
                            .onKeyPress(.downArrow) { move(1) }
                            .onKeyPress(.escape) { close(); return .handled }
                            .onSubmit { if results.indices.contains(highlighted) { choose(results[highlighted]) } }
                        if model.loading { LoadingLine(width: 18) }
                        Keycap(text: "esc")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            OctetAnimatedList(items: results, highlighted: highlighted,
                                              highlight: { highlighted = $0 }, choose: choose) { file, selected in
                                HStack(spacing: 9) {
                                    if let logo = LanguageLogo(path: file.path, size: 14) { logo }
                                    else { OctetIcon("doc", size: 14).foregroundStyle(Theme.textTertiary) }
                                    Text(file.relativePath)
                                        .font(Theme.monoFont)
                                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent)
                                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        .frame(maxHeight: 390)
                        .octetScrollIndicators()
                        .onChange(of: highlighted) { _, index in
                            if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                        }
                    }
                    HStack {
                        Text("↑↓ navigate  ↩ open").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text("\(model.files.count) files").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .frame(width: 620)
            .padding(.top, 72)
        }
        .onAppear {
            model.load(rootDirectory)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func move(_ amount: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        highlighted = (highlighted + amount + results.count) % results.count
        return .handled
    }

    private func choose(_ file: EditorFileItem) {
        workspace.open(URL(fileURLWithPath: file.path), presentation: workspace.requestedPresentation)
        close()
    }

    private func close() { workspace.filePickerVisible = false }
}
