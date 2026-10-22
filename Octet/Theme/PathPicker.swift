import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Choosing a file or folder inside Octet, after T3 Code's: no system open
/// panel, but a card over the window with a path you can type into and the
/// folder's entries under it. Typing filters the folder or jumps to a path
/// (`~` works); ↑↓ move, Return or Tab goes into a folder, ⌘Return picks the
/// folder shown, Return on a file picks it, Space marks files when several
/// can go, Esc cancels.
struct PathPickerRequest: Identifiable {
    enum Mode: Equatable {
        case folder
        case files(multiple: Bool)
    }

    let id = UUID()
    var title: String
    var message: String?
    var prompt: String = "Open"
    var mode: Mode = .folder
    var start: String?
    /// File extensions accepted, lowercased; empty takes any file.
    var extensions: Set<String> = []
    /// Folder mode: a path that doesn't exist yet can be made and picked.
    var canCreateFolder = false
    weak var window: NSWindow?
    let completion: ([URL]) -> Void
}

/// Where requests wait for the window they belong to.
@MainActor
final class PathPickerCenter: ObservableObject {
    static let shared = PathPickerCenter()
    @Published private(set) var request: PathPickerRequest?

    /// Shows a picker over `window` (the key window when nil). `completion`
    /// gets what was picked, or nothing if it was cancelled.
    func pick(_ title: String, message: String? = nil, prompt: String = "Open", mode: PathPickerRequest.Mode = .folder,
              start: String? = nil, extensions: Set<String> = [], canCreateFolder: Bool = false,
              in window: NSWindow? = nil, completion: @escaping ([URL]) -> Void) {
        request?.completion([])
        request = PathPickerRequest(title: title, message: message, prompt: prompt, mode: mode, start: start,
                                    extensions: extensions, canCreateFolder: canCreateFolder,
                                    window: window ?? NSApp.keyWindow ?? NSApp.mainWindow, completion: completion)
    }

    func finish(_ urls: [URL]) {
        let pending = request
        request = nil
        pending?.completion(urls)
    }
}

/// Hosts the picker over one window's content when a request is for it.
struct PathPickerHost: View {
    weak var window: NSWindow?
    @ObservedObject private var center = PathPickerCenter.shared

    var body: some View {
        if let request = center.request, request.window == nil || request.window === window {
            ZStack {
                Color.black.opacity(Theme.isLight ? 0.18 : 0.4)
                    .ignoresSafeArea()
                    .onTapGesture { center.finish([]) }
                PathPickerView(request: request) { center.finish($0) }
                    .id(request.id)
            }
            .transition(.opacity)
        }
    }
}

private struct PathPickerView: View {
    let request: PathPickerRequest
    let finish: ([URL]) -> Void

    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let isFolder: Bool
        var id: String { path }
    }

    @State private var text = ""
    @State private var entries: [Entry] = []
    @State private var highlighted = 0
    @State private var marked: Set<String> = []
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// The folder shown and the filter typed after it.
    private var parts: (folder: String, filter: String) {
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasSuffix("/") || expanded.isEmpty { return (expanded.isEmpty ? "/" : expanded, "") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue, text.hasSuffix("/") {
            return (expanded, "")
        }
        return ((expanded as NSString).deletingLastPathComponent, (expanded as NSString).lastPathComponent)
    }

    private var shown: [Entry] {
        let filter = parts.filter.lowercased()
        return entries.filter { entry in
            if !filter.isEmpty { return entry.name.lowercased().contains(filter) }
            return !entry.name.hasPrefix(".")
        }
        .sorted { a, b in
            // Names starting with what's typed come first.
            let aStarts = !filter.isEmpty && a.name.lowercased().hasPrefix(filter)
            let bStarts = !filter.isEmpty && b.name.lowercased().hasPrefix(filter)
            if aStarts != bStarts { return aStarts }
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var rows: [Entry] {
        let folder = parts.folder
        let up = folder == "/" ? [] : [Entry(name: "..", path: (folder as NSString).deletingLastPathComponent, isFolder: true)]
        return up + shown
    }

    private var folderMode: Bool { request.mode == .folder }
    private var multiple: Bool { request.mode == .files(multiple: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            pathField
            Rectangle().fill(ChatStyle.border).frame(height: 1)
            list
            Rectangle().fill(ChatStyle.border).frame(height: 1)
            footer
        }
        .frame(width: 600)
        .chatPopover()
        .onAppear {
            let start = request.start.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? NSHomeDirectory()
            text = abbreviate(start.hasSuffix("/") ? start : start + "/")
            load()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: parts.folder) { _, _ in load() }
        .onChange(of: text) { _, _ in highlighted = 0 }
        .onExitCommand { finish([]) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.title).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(ChatStyle.text)
            if let message = request.message {
                Text(message).font(Theme.interfaceFont(11)).foregroundStyle(ChatStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var pathField: some View {
        HStack(spacing: 8) {
            Image(systemName: folderMode ? "folder" : "doc").font(.system(size: 13)).foregroundStyle(ChatStyle.mutedText)
            TextField("", text: $text, prompt: Text("Type a path, or a name to filter").foregroundStyle(ChatStyle.placeholder))
                .textFieldStyle(.plain)
                .font(Theme.Text.mono(12.5))
                .foregroundStyle(ChatStyle.text)
                .focused($fieldFocused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.tab) { enterHighlighted(); return .handled }
                .onKeyPress(.space) {
                    guard multiple, let entry = rows[safe: highlighted], !entry.isFolder else { return .ignored }
                    toggle(entry)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { choose(); return .handled }
                    activateHighlighted()
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        row(entry, index: index).id(entry.id)
                    }
                    if rows.allSatisfy({ $0.name == ".." }) {
                        Text(parts.filter.isEmpty ? "This folder is empty." : "Nothing here matches “\(parts.filter)”.")
                            .font(ChatStyle.meta)
                            .foregroundStyle(ChatStyle.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(height: 320)
            .onChange(of: highlighted) { _, index in
                if let entry = rows[safe: index] { proxy.scrollTo(entry.id) }
            }
        }
    }

    private func row(_ entry: Entry, index: Int) -> some View {
        let selectable = entry.isFolder || (!folderMode && accepts(entry))
        let isMarked = marked.contains(entry.path)
        return HStack(spacing: 10) {
            Group {
                if entry.name == ".." {
                    Image(systemName: "arrow.turn.left.up").font(.system(size: 12)).foregroundStyle(ChatStyle.mutedText)
                } else if entry.isFolder {
                    Image(systemName: "folder.fill").font(.system(size: 14)).foregroundStyle(Color(hex: "0EA5E9"))
                } else {
                    ChatFileBadge(style: ChatFileStyle(path: entry.path), size: 20)
                }
            }
            .frame(width: 22)
            Text(entry.name)
                .font(ChatStyle.meta)
                .foregroundStyle(selectable ? ChatStyle.text : ChatStyle.faintIcon)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if isMarked {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(ChatStyle.primary)
            } else if entry.isFolder, entry.name != ".." {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ChatStyle.faintIcon)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
            .fill(index == highlighted ? ChatStyle.text.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        .onTapGesture(count: 2) { activate(entry) }
        .onTapGesture {
            highlighted = index
            if multiple, !entry.isFolder { toggle(entry) } else if !entry.isFolder, selectable { activate(entry) }
            else if entry.isFolder { activate(entry) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerNote)
                .font(Theme.interfaceFont(11))
                .foregroundStyle(ChatStyle.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ChatButton(title: "Cancel", kind: .ghost) { finish([]) }
            ChatButton(title: primaryTitle, kind: .primary) { choose() }
                .disabled(!canChoose)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var footerNote: String {
        if folderMode { return "⌘↩ picks " + abbreviate(chosenFolder) }
        if multiple { return marked.isEmpty ? "Space marks files · ↩ picks one" : "\(marked.count) marked" }
        return "↩ picks the file · Tab opens a folder"
    }

    /// The folder ⌘Return would pick: what's typed when it names a folder
    /// (made first if it can be), else the one shown.
    private var chosenFolder: String {
        let expanded = (text as NSString).expandingTildeInPath
        let trimmed = expanded.hasSuffix("/") && expanded.count > 1 ? String(expanded.dropLast()) : expanded
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue { return trimmed }
        if request.canCreateFolder, !parts.filter.isEmpty, shown.isEmpty { return trimmed }
        return parts.folder
    }

    private var creating: Bool {
        folderMode && request.canCreateFolder && !FileManager.default.fileExists(atPath: chosenFolder)
    }

    private var primaryTitle: String {
        creating ? "Create & \(request.prompt)" : request.prompt
    }

    private var canChoose: Bool {
        if folderMode { return true }
        if !marked.isEmpty { return true }
        guard let entry = rows[safe: highlighted] else { return false }
        return !entry.isFolder && accepts(entry)
    }

    // MARK: Actions

    private func accepts(_ entry: Entry) -> Bool {
        request.extensions.isEmpty || request.extensions.contains((entry.path as NSString).pathExtension.lowercased())
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = (highlighted + delta + rows.count) % rows.count
    }

    private func enterHighlighted() {
        guard let entry = rows[safe: highlighted], entry.isFolder else { return }
        open(entry.path)
    }

    private func activateHighlighted() {
        if let entry = rows[safe: highlighted] {
            activate(entry)
        } else if folderMode {
            choose()
        }
    }

    private func activate(_ entry: Entry) {
        if entry.isFolder {
            open(entry.path)
        } else if !folderMode, accepts(entry) {
            if multiple, !marked.isEmpty {
                toggle(entry)
            } else {
                finish([URL(fileURLWithPath: entry.path)])
            }
        }
    }

    private func toggle(_ entry: Entry) {
        guard accepts(entry) else { return }
        if marked.contains(entry.path) { marked.remove(entry.path) } else { marked.insert(entry.path) }
    }

    private func open(_ path: String) {
        text = abbreviate(path == "/" ? "/" : path + "/")
    }

    private func choose() {
        if folderMode {
            let folder = chosenFolder
            if creating {
                do {
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                } catch {
                    ToastCenter.shared.fail(nil, "Couldn't make that folder", detail: error.localizedDescription)
                    return
                }
            }
            finish([URL(fileURLWithPath: folder)])
        } else if !marked.isEmpty {
            finish(marked.sorted().map { URL(fileURLWithPath: $0) })
        } else if let entry = rows[safe: highlighted], !entry.isFolder, accepts(entry) {
            finish([URL(fileURLWithPath: entry.path)])
        }
    }

    /// Reads the folder off the main thread; the latest one typed wins.
    private func load() {
        let folder = parts.folder
        loadTask?.cancel()
        let foldersOnly = folderMode
        loadTask = Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [Entry] in
                let manager = FileManager.default
                guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return [] }
                return names.prefix(5_000).compactMap { name in
                    let path = (folder as NSString).appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
                    // Packages (apps, bundles) read as files.
                    let isFolder = isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)
                    if foldersOnly && !isFolder { return nil }
                    return Entry(name: name, path: path, isFolder: isFolder)
                }
            }.value
            guard !Task.isCancelled else { return }
            entries = found
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
