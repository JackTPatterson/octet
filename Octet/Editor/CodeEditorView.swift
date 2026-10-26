import AppKit
import SwiftUI

/// The grouped editor surface. File tabs live inside one Octet tab, leaving
/// the outer strip for terminal/conversation-level context switches.
struct CodeEditorView: View {
    @ObservedObject var workspace: EditorWorkspace
    let rootDirectory: String
    /// Brings the Files plane forward on a folder.
    var revealFolder: (String) -> Void = { _ in }
    @Namespace private var tabSelection

    var body: some View {
        VStack(spacing: 0) {
            // The outer tab already names a lone file; the strip is for switching between several.
            if workspace.documents.count > 1 { editorTabs }
            HStack(spacing: 0) {
                if workspace.fileTreeVisible {
                    EditorFileTree(rootDirectory: rootDirectory, workspace: workspace)
                        .frame(width: 225)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
                if let document = workspace.activeDocument {
                    EditorDocumentView(document: document, workspace: workspace,
                                       rootDirectory: rootDirectory, revealFolder: revealFolder)
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
        // An agent or a branch switch changes files under the editor: look
        // when Octet comes back to the front, and every couple of seconds
        // while it's in view (a stat, not a read).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.activeDocument?.refreshFromDisk()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            workspace.activeDocument?.refreshFromDisk()
        }
    }

    private var editorTabs: some View {
        HStack(spacing: 0) {
            EditorFilesToggle(workspace: workspace)
                .padding(.horizontal, 6)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.documents) { document in
                        EditorFileTab(document: document, workspace: workspace, selection: tabSelection)
                    }
                }
                .animation(MotionPreferences.shared.animation(.tabs, .smooth(duration: 0.2)), value: workspace.activeID)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                OctetIconButton(icon: "plus", help: "Open File (⌘O)") { workspace.filePickerVisible = true }
                OctetIconButton(icon: workspace.presentation == .split ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1",
                                help: workspace.presentation == .split ? "Open Editor Full Screen" : "Show Editor Beside Terminal") {
                    workspace.togglePresentation()
                }
                OctetIconButton(icon: "xmark", help: "Close Editor (⌘W)") { workspace.closeEditor() }
            }
            .padding(.horizontal, 5)
        }
        .frame(height: 32)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var editorEmptyState: some View {
        OctetEmptyState(icon: "tool.edit", title: "Open a file to start editing",
                        message: "Search this workspace with ⌘O.", actionTitle: "Open File", actionIcon: "folder") {
            workspace.filePickerVisible = true
        }
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    let workspace: EditorWorkspace
    let rootDirectory: String
    let revealFolder: (String) -> Void
    /// How a Markdown file shows, kept for the next one opened.
    @AppStorage("octet.editor.markdownMode") private var markdownMode = MarkdownMode.preview.rawValue
    /// Likewise for SVG and CSV/TSV files: the rendered view or the source.
    @AppStorage("octet.editor.svgMode") private var svgMode = SourceMode.preview.rawValue
    @AppStorage("octet.editor.tableMode") private var tableMode = SourceMode.preview.rawValue
    /// What the viewer says about its file, e.g. “1200 × 800 · 340 KB”.
    @State private var detail = ""
    /// The header's width: narrow (beside a terminal), the view switch
    /// drops its words so the file's name keeps its room.
    @State private var headerWidth: CGFloat = 1_000

    /// Stored by these raw values, from when they read Edit and Preview.
    enum MarkdownMode: String, CaseIterable, Identifiable {
        case edit, split, preview
        var id: String { rawValue }
        var title: String {
            switch self {
            case .edit: "Code"
            case .split: "Split"
            case .preview: "Viewer"
            }
        }
        var icon: String {
            switch self {
            case .edit: "code"
            case .split: "rectangle.split.2x1"
            case .preview: "eye"
            }
        }
    }

    enum SourceMode: String {
        case preview, source
    }

    private var isMarkdown: Bool { document.mode == .markdown }

    private var mode: MarkdownMode { isMarkdown ? MarkdownMode(rawValue: markdownMode) ?? .preview : .edit }

    /// The binding of the Preview / Source switch for SVG and tables.
    private var sourceMode: Binding<String>? {
        switch document.mode {
        case .svg: $svgMode
        case .table: $tableMode
        default: nil
        }
    }

    private var showsPreview: Bool {
        switch document.mode {
        case .svg: svgMode == SourceMode.preview.rawValue
        case .table: tableMode == SourceMode.preview.rawValue
        default: false
        }
    }

    /// With no tab strip (a lone file), its controls sit on the breadcrumb row.
    private var lone: Bool { workspace.documents.count <= 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if lone {
                    // Set apart from the path, so it doesn't read as its root.
                    EditorFilesToggle(workspace: workspace)
                        .padding(.horizontal, 5)
                    Rectangle().fill(Theme.divider).frame(width: 1, height: 14)
                }
                FileBreadcrumbs(url: document.url, root: rootDirectory, reveal: revealFolder)
                viewSwitch
                if document.mode.readsText {
                    AgentEditingChip(document: document)
                    AgentFollowToggle()
                }
                if lone {
                    HStack(spacing: 2) {
                        OctetIconButton(icon: "plus", help: "Open File (⌘O)", compact: true) { workspace.filePickerVisible = true }
                        OctetIconButton(icon: workspace.presentation == .split ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1",
                                        help: workspace.presentation == .split ? "Open Editor Full Screen" : "Show Editor Beside Terminal",
                                        compact: true) { workspace.togglePresentation() }
                        OctetIconButton(icon: "xmark", help: "Close Editor (⌘W)", compact: true) { workspace.closeEditor() }
                    }
                    .padding(.trailing, 6)
                }
            }
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
            if document.changedOnDisk { ChangedOnDiskBanner(document: document) }
            content
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch document.mode {
        case .image:
            ImagePreview(url: document.url, detail: $detail).id(document.revision)
        case .audio:
            AudioPreview(url: document.url).id(document.revision)
        case .video:
            MediaPreview(url: document.url, video: true).id(document.revision)
        case .pdf:
            PDFPreview(url: document.url, detail: $detail).id(document.revision)
        case .binary:
            NoPreviewCard(url: document.url)
        case .svg where showsPreview:
            ImagePreview(url: document.url, svgText: document.text, detail: $detail)
        case .table where showsPreview:
            DelimitedTablePreview(text: document.text, delimiter: FilePreviewMode.delimiter(forPath: document.url.path),
                                  detail: $detail)
        default:
            HStack(spacing: 0) {
                if mode != .preview {
                    CodeEditorTextView(document: document, workspace: workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                if mode == .split { Rectangle().fill(Theme.divider).frame(width: 1) }
                if mode != .edit {
                    MarkdownWebPreview(text: document.text, baseURL: document.url.deletingLastPathComponent()) { url in
                        workspace.open(url)
                    }
                    .background(Theme.terminalBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// How the file shows, in the header where it's seen: the Markdown's
    /// code, both side by side, or the rendered viewer; an SVG's or table's
    /// viewer or its code.
    @ViewBuilder
    private var viewSwitch: some View {
        if isMarkdown {
            EditorViewSwitch(selection: $markdownMode,
                             items: MarkdownMode.allCases.map { ($0.rawValue, $0.title, $0.icon) },
                             iconsOnly: headerWidth < 720)
                .help("The Markdown's code, both side by side, or the rendered viewer")
                .padding(.horizontal, 6)
        } else if let sourceMode {
            EditorViewSwitch(selection: sourceMode,
                             items: [(SourceMode.source.rawValue, "Code", "code"),
                                     (SourceMode.preview.rawValue, "Viewer", "eye")],
                             iconsOnly: headerWidth < 720)
                .help(document.mode == .svg ? "The image's code, or the image" : "The table's code, or the table")
                .padding(.horizontal, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if document.mode.readsText { VimStatusView(workspace: workspace) }
            if !document.mode.readsText || showsPreview {
                Text(detail.isEmpty ? previewFileSize(document.url) : detail)
            }
            Spacer()
            if let error = document.lastError {
                OctetIcon("xmark.circle.fill", size: 12).foregroundStyle(Theme.danger)
                Text(error).lineLimit(1)
            }
            if document.mode.readsText && !showsPreview {
                Text("\(document.lineCount) lines")
                Text(document.lineEnding.rawValue)
                    .help("Line endings")
                Text(document.encodingName)
                    .help("Read and saved in \(document.encodingName)")
            }
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

/// Vim's mode and the keys waiting, at the left of the footer, while Vim keys are on.
private struct VimStatusView: View {
    @ObservedObject var workspace: EditorWorkspace

    var body: some View {
        if !workspace.vimStatus.isEmpty {
            Text(workspace.vimStatus)
                .font(Theme.Text.mono(11).weight(.semibold))
                .foregroundStyle(workspace.vimStatus.hasPrefix("-- INSERT") ? Theme.success : Theme.textSecondary)
                .lineLimit(1)
        }
    }
}

/// "Claude is editing", with its logo and a loading line, while an agent has
/// an edit to this file in flight.
private struct AgentEditingChip: View {
    let document: EditorDocument
    @ObservedObject private var activity = AgentEditActivity.shared

    var body: some View {
        Group {
            if let pending = activity.pending[document.id] {
                HStack(spacing: 5) {
                    if let brand = AgentBrand.forAgent(pending.writer.brandId) { AgentLogo(brand: brand, size: 11) }
                    Text("\(pending.writer.name) is editing")
                        .font(Theme.captionFont.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    LoadingLine(width: 14, thickness: 1.5)
                }
                .fixedSize()
                .layoutPriority(2)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Theme.hover))
                .padding(.trailing, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.smooth(duration: 0.2), value: activity.pending[document.id] != nil)
    }
}

/// Whether the view follows an agent's edits: scrolling to where its cursor goes.
private struct AgentFollowToggle: View {
    @AppStorage("octet.editor.followAgent") private var follow = true

    var body: some View {
        OctetIconButton(icon: "eye", help: follow ? "Following the agent's edits. Click to stay where you are."
                                                  : "Follow the agent's edits as they land", active: follow, compact: true) {
            follow.toggle()
        }
        .padding(.trailing, 4)
    }
}

/// Shows or hides the editor's file tree: the navigator mark Xcode and
/// Finder use, lit while the tree is open.
private struct EditorFilesToggle: View {
    @ObservedObject var workspace: EditorWorkspace
    @State private var hovered = false

    var body: some View {
        let open = workspace.fileTreeVisible
        Button { workspace.fileTreeVisible.toggle() } label: {
            OctetIcon("files.navigator", size: 13)
                .foregroundStyle(open || hovered ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(open ? Theme.cardSelected : hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(open ? "Hide Files" : "Show Files")
        .accessibilityLabel("Files")
        .accessibilityValue(open ? "Shown" : "Hidden")
    }
}

/// A compact segmented switch for the editor's header: each way to see the
/// file as an icon and a word, the one in use raised.
private struct EditorViewSwitch: View {
    @Binding var selection: String
    let items: [(value: String, title: String, icon: String)]
    /// Narrow: icons alone, each named in its tooltip.
    var iconsOnly = false
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.value) { item in
                let chosen = item.value == selection
                Button {
                    MotionPreferences.shared.perform(.sidebar) { selection = item.value }
                } label: {
                    HStack(spacing: 4) {
                        OctetIcon(item.icon, size: 11)
                        if !iconsOnly { Text(item.title).font(Theme.captionFont.weight(.medium)) }
                    }
                    .foregroundStyle(chosen || hovered == item.value ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.cardSelected)
                        } else if hovered == item.value {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.hover)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.value : (hovered == item.value ? nil : hovered) }
                .help(iconsOnly ? item.title : "")
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hover.opacity(0.5)))
        .fixedSize()
    }
}

/// The file changed on disk while it had unsaved edits here: say so above
/// the text and let the person choose, rather than keeping one silently.
private struct ChangedOnDiskBanner: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            OctetIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Changed on disk").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                Text("Something else saved \(document.name) while you had unsaved edits.")
                    .font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.md)
            OctetButton(title: "Compare", kind: .ghost, compact: true) { compare() }
            OctetButton(title: "Keep Mine", kind: .secondary, compact: true) { document.keepMine() }
                .help("Keep your edits; saving overwrites the version on disk")
            OctetButton(title: "Reload", kind: .primary, compact: true) { document.reloadDiscardingChanges() }
                .help("Discard your edits and load the version on disk")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.warning.opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.warning.opacity(0.35)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(document.name) changed on disk while you had unsaved edits")
    }

    /// The two versions side by side as a diff, with the same choices.
    private func compare() {
        guard let disk = document.diskText() else {
            ToastCenter.shared.fail(nil, "Couldn't read \(document.name) from disk")
            return
        }
        let lines = LineDiff.lines(old: disk, new: document.text, context: 2)
        let diff = lines.map { line in
            switch line.kind {
            case .context: "  " + line.text
            case .removed: "- " + line.text
            case .added: "+ " + line.text
            }
        }.joined(separator: "\n")
        var request = ConfirmCenter.Request(
            title: "Your edits against the file on disk",
            message: "Lines marked − are on disk; lines marked + are yours.",
            detail: diff.isEmpty ? "No differences." : diff,
            confirmTitle: "Keep Mine",
            onConfirm: { [weak document] _ in document?.keepMine() }
        )
        request.alternateTitle = "Reload from Disk"
        request.onAlternate = { [weak document] in document?.reloadDiscardingChanges() }
        ConfirmCenter.shared.ask(request)
    }
}

private struct EditorFileTab: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var workspace: EditorWorkspace
    let selection: Namespace.ID
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
            // An unsaved file's dot turns into its close button under the
            // pointer, as in most editors, so the tab can still be closed.
            if document.isDirty && !hovered {
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Unsaved changes")
            } else if hovered || active || document.isDirty {
                OctetIconButton(icon: "xmark", help: document.isDirty ? "Close \(document.name) (unsaved)" : "Close \(document.name)",
                                compact: true) { workspace.close(document) }
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, maxWidth: 210, minHeight: 32, maxHeight: 32)
        .background {
            ZStack {
                if hovered && !active { Theme.hover }
                // One selection surface slides between the tabs, as in the
                // tab bar and the planes strip.
                if active {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        Rectangle().fill(Theme.selectionMark).frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedFile", in: selection)
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(document) }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.name + (document.isDirty ? ", unsaved" : ""))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workspace.activate(document) }
        .contextMenu {
            Button("Save") { document.save() }.disabled(!document.isDirty)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            Divider()
            Button("Close") { workspace.close(document) }
        }
        .help(document.url.path)
    }
}

/// The editor's view of the shared project index (ProjectFileIndexStore).
@MainActor
private final class EditorFilesModel: ObservableObject {
    @Published var files: [EditorFileItem] = []
    @Published var truncated = false
    @Published var loading = false
    private var loadedRoot: String?

    func load(_ root: String) {
        guard loadedRoot != root else { return }
        loadedRoot = root
        let store = ProjectFileIndexStore.shared
        if let entry = store.entry(for: root) { apply(entry) }
        loading = store.entry(for: root) == nil
        store.load(root) { [weak self] entry in
            guard let self, self.loadedRoot == root else { return }
            self.apply(entry)
            self.loading = false
        }
    }

    private func apply(_ entry: ProjectFileIndexStore.Entry) {
        files = entry.items
        truncated = entry.truncated
    }
}

/// "Showing the first 20,000 files": the index stopped, so search may miss some.
private struct IndexCapNote: View {
    let count: Int

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            OctetIcon("info.circle.fill", size: 11)
            Text("Showing the first \(count.formatted()) files")
        }
        .font(Theme.Text.caption)
        .foregroundStyle(Theme.textTertiary)
        .help("This project has more files than Octet lists. Files past the limit won't show or match a search.")
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
                if model.truncated {
                    IndexCapNote(count: model.files.count).padding(.horizontal, 10).padding(.bottom, 8)
                }
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

    /// Fuzzy, as the command palette is: "cev" finds CodeEditorView.swift.
    /// The file's name counts for more than its folder, so a match on the
    /// name ranks above the same letters scattered through the path.
    private var results: [EditorFileItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(model.files.prefix(14)) }
        return Array(model.files
            .compactMap { item -> (EditorFileItem, Int)? in
                let name = (item.relativePath as NSString).lastPathComponent
                let byName = FuzzyMatcher.match(needle, in: name).map { $0.score + 40 }
                let byPath = FuzzyMatcher.match(needle, in: item.relativePath)?.score
                guard let score = [byName, byPath].compactMap({ $0 }).max() else { return nil }
                return (item, score - item.relativePath.count / 8)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(14)
            .map(\.0))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim.ignoresSafeArea().onTapGesture(perform: close)
            OctetPalettePanel(style: .floating, divider: .none) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        OctetIcon("magnifyingglass", size: 17).foregroundStyle(Theme.textSecondary)
                        TextField("Open file in \(URL(fileURLWithPath: rootDirectory).lastPathComponent)…", text: $query)
                            .textFieldStyle(.plain)
                            .font(Theme.interfaceFont(14))
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
                    if results.isEmpty && !model.loading {
                        HStack(spacing: 9) {
                            OctetIcon("magnifyingglass", size: 14).foregroundStyle(Theme.textTertiary)
                            Text(model.files.isEmpty ? "No files in this folder" : "No files match “\(query)”")
                                .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .accessibilityAddTraits(.updatesFrequently)
                    }
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
                        if model.truncated {
                            IndexCapNote(count: model.files.count)
                        } else {
                            Text("\(model.files.count) files").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        }
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
