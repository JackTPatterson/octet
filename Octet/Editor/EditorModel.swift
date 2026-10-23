import AppKit
import Combine
import Foundation

enum EditorError: LocalizedError {
    case directory
    case tooLarge(Int)
    case notText

    var errorDescription: String? {
        switch self {
        case .directory: return "Choose a file, not a folder."
        case .tooLarge(let bytes): return "This file is too large to edit in Octet (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case .notText: return "This file isn't text Octet can read."
        }
    }
}

/// One canonical file buffer. The registry shares it between editor panes so
/// the same file can never quietly diverge in two Octet windows.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    static let maximumBytes = 5 * 1_024 * 1_024

    let id: String
    let url: URL
    @Published private(set) var text: String
    @Published private(set) var isDirty = false
    @Published private(set) var lastError: String?
    /// The file changed on disk while this buffer had unsaved edits. The
    /// edits stay; the banner asks whether to reload, compare or keep them.
    @Published private(set) var changedOnDisk = false
    private var savedText: String
    private(set) var diskModificationDate: Date?
    /// How the file opens. Media and binary files hold no text.
    private(set) var mode: FilePreviewMode
    /// Bumped when a viewer's file changes on disk, so the viewer reloads.
    @Published private(set) var revision = 0
    /// What the bytes on disk are in, so saving writes them back the same.
    @Published private(set) var encoding: String.Encoding = .utf8
    private var byteOrderMark = false

    var name: String { url.lastPathComponent }
    var directory: String { url.deletingLastPathComponent().path }
    var lineCount: Int { max(1, text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }) }
    /// "UTF-8", "UTF-16 LE", "Windows-1252"… for the footer.
    var encodingName: String { TextEncoding.name(of: encoding, byteOrderMark: byteOrderMark) }
    var lineEnding: DecodedText.LineEnding { TextEncoding.lineEnding(of: text) }

    init(url: URL) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw EditorError.directory
        }
        id = canonical.path
        self.url = canonical
        var mode = FilePreviewMode.mode(forPath: canonical.path)
        var string = ""
        if mode.readsText {
            let data = try Data(contentsOf: canonical, options: [.mappedIfSafe])
            guard data.count <= Self.maximumBytes else { throw EditorError.tooLarge(data.count) }
            // Text by name but not by content: show the "No preview" card.
            if let decoded = TextEncoding.decode(data) {
                string = decoded.text
                encoding = decoded.encoding
                byteOrderMark = decoded.byteOrderMark
            } else {
                mode = .binary
            }
        }
        self.mode = mode
        text = string
        savedText = string
        diskModificationDate = Self.modificationDate(canonical)
    }

    func replaceText(_ value: String) {
        guard value != text else { return }
        text = value
        isDirty = value != savedText
        lastError = nil
    }

    @discardableResult
    func save() -> Bool {
        do {
            // Written back as it was read; a character the old encoding
            // can't hold moves the file to UTF-8 rather than losing it.
            var data = TextEncoding.encode(text, as: encoding, byteOrderMark: byteOrderMark)
            if data == nil {
                data = Data(text.utf8)
                ToastCenter.shared.info("Saved \(name) as UTF-8",
                                        detail: "It has characters \(encodingName) can't hold")
                encoding = .utf8
                byteOrderMark = false
            }
            try data!.write(to: url, options: .atomic)
            savedText = text
            isDirty = false
            changedOnDisk = false
            lastError = nil
            diskModificationDate = Self.modificationDate(url)
            return true
        } catch {
            lastError = error.localizedDescription
            ToastCenter.shared.fail(nil, "Couldn't save \(name)", detail: error.localizedDescription)
            return false
        }
    }

    /// Pull an agent or branch-switch edit into a clean buffer. A dirty buffer
    /// keeps its edits and raises `changedOnDisk`, so the person decides.
    func refreshFromDisk() {
        guard let modified = Self.modificationDate(url), modified != diskModificationDate else { return }
        guard mode.readsText else {
            diskModificationDate = modified
            revision += 1
            return
        }
        guard !isDirty else {
            if !changedOnDisk { changedOnDisk = true }
            return
        }
        guard let decoded = readDisk() else { return }
        apply(decoded, modified: modified)
    }

    /// What the file says on disk now, for Compare.
    func diskText() -> String? { readDisk()?.text }

    func reloadDiscardingChanges() {
        guard mode.readsText, let decoded = readDisk() else { return }
        apply(decoded, modified: Self.modificationDate(url))
        isDirty = false
        lastError = nil
    }

    /// Keep the edits over the disk's version: the next save overwrites it,
    /// and this change on disk stops being raised.
    func keepMine() {
        diskModificationDate = Self.modificationDate(url)
        changedOnDisk = false
    }

    private func readDisk() -> DecodedText? {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes else { return nil }
        return TextEncoding.decode(data)
    }

    private func apply(_ decoded: DecodedText, modified: Date?) {
        text = decoded.text
        savedText = decoded.text
        encoding = decoded.encoding
        byteOrderMark = decoded.byteOrderMark
        changedOnDisk = false
        diskModificationDate = modified
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

@MainActor
final class EditorBufferRegistry {
    static let shared = EditorBufferRegistry()
    private var documents: [String: EditorDocument] = [:]

    func document(at url: URL) throws -> EditorDocument {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let document = documents[path] {
            document.refreshFromDisk()
            return document
        }
        let document = try EditorDocument(url: url)
        documents[path] = document
        return document
    }
}

/// The grouped file viewer in one Octet window. This is one main tab with an
/// inner row of files, matching Warp's grouped-editor model.
@MainActor
final class EditorWorkspace: ObservableObject {
    enum Presentation { case split, full }

    @Published private(set) var documents: [EditorDocument] = []
    @Published var activeID: String?
    @Published var isPresented = false
    @Published var fileTreeVisible = false
    @Published var filePickerVisible = false
    @Published var presentation: Presentation = .split
    var requestedPresentation: Presentation = .split
    /// A folder the Files plane is asked to show, from a breadcrumb. The
    /// plane takes the request (clearing it) once it's on screen.
    struct FolderReveal: Equatable {
        let path: String
        let at = Date()
    }
    @Published var folderReveal: FolderReveal?
    weak var textView: NSTextView?

    var activeDocument: EditorDocument? { documents.first { $0.id == activeID } }
    var dirtyDocuments: [EditorDocument] { documents.filter(\.isDirty) }

    func open(_ url: URL, presentation: Presentation? = nil) {
        do {
            let document = try EditorBufferRegistry.shared.document(at: url)
            if !documents.contains(where: { $0.id == document.id }) { documents.append(document) }
            activeID = document.id
            if let presentation { self.presentation = presentation }
            isPresented = true
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't open \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }

    func activate(_ document: EditorDocument) {
        document.refreshFromDisk()
        activeID = document.id
        isPresented = true
    }

    func dismiss() { isPresented = false }

    func close(_ document: EditorDocument) {
        guard document.isDirty else { return remove(document) }
        ConfirmCenter.shared.ask(
            title: "Save changes to \(document.name)?",
            message: "Closing this file without saving discards your changes.",
            confirmTitle: "Save",
            cancelTitle: "Cancel",
            onConfirm: { [weak self, weak document] _ in
                guard let self, let document, document.save() else { return }
                self.remove(document)
            }
        )
    }

    func closeEditor() {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else {
            documents.removeAll()
            activeID = nil
            isPresented = false
            return
        }
        ConfirmCenter.shared.ask(
            title: "Save editor changes?",
            message: "The editor has unsaved files.",
            items: dirty.map(\.name),
            confirmTitle: "Save All",
            onConfirm: { [weak self] _ in
                guard dirty.allSatisfy({ $0.save() }) else { return }
                self?.documents.removeAll()
                self?.activeID = nil
                self?.isPresented = false
            }
        )
    }

    func save() {
        guard let document = activeDocument else { return }
        if document.save() { ToastCenter.shared.info("Saved \(document.name)", after: 1.5) }
    }

    func saveAll() {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else { return }
        if dirty.allSatisfy({ $0.save() }) { ToastCenter.shared.info("Saved \(dirty.count) files", after: 1.5) }
    }

    func find(_ action: NSTextFinder.Action = .showFindInterface) {
        textView?.performTextFinderAction(action.rawValue)
    }

    func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Selects a 1-based line and scrolls to it, once the text view holding
    /// the newly opened document is there.
    func reveal(line: Int, attempts: Int = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let textView = self.textView, !textView.string.isEmpty else {
                if attempts > 0 { self.reveal(line: line, attempts: attempts - 1) }
                return
            }
            let text = textView.string as NSString
            var location = 0
            for _ in 1..<max(1, line) {
                let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
                guard next.location != NSNotFound else { break }
                location = next.location + 1
            }
            let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            self.focusEditor()
        }
    }

    func togglePresentation() {
        presentation = presentation == .split ? .full : .split
        requestedPresentation = presentation
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    private func remove(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if activeID == document.id {
            activeID = documents.indices.contains(index) ? documents[index].id : documents.last?.id
        }
        if documents.isEmpty { isPresented = false }
    }
}

struct EditorFileItem: Identifiable, Equatable {
    let path: String
    let relativePath: String
    var id: String { path }
}

enum EditorFileIndex {
    /// The project's files as editor items (see ProjectFileIndex).
    static func files(in root: String, limit: Int = ProjectFileIndex.defaultLimit) -> [EditorFileItem] {
        items(ProjectFileIndex.list(root: root, limit: limit), root: root)
    }

    static func items(_ result: ProjectFileIndex.Result, root: String) -> [EditorFileItem] {
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return result.paths.map { EditorFileItem(path: prefix + $0, relativePath: $0) }
    }
}

/// One file index per project, shared by the Files plane, the editor's
/// list and its picker, so a project is walked once rather than three
/// times. A reload is asked for explicitly (Refresh, the plane coming back
/// into view); otherwise a recent index is reused.
@MainActor
final class ProjectFileIndexStore: ObservableObject {
    static let shared = ProjectFileIndexStore()

    struct Entry {
        var items: [EditorFileItem]
        var truncated: Bool
        var fromGit: Bool
        var loadedAt: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var loading: Set<String> = []
    private var waiters: [String: [(Entry) -> Void]] = [:]

    /// Reused this long before a quiet reload on the next ask.
    static let freshFor: TimeInterval = 30

    func entry(for root: String) -> Entry? { entries[root] }

    /// The index for `root`, from cache when fresh; `done` hears it once read.
    func load(_ root: String, force: Bool = false, done: @escaping (Entry) -> Void = { _ in }) {
        if !force, let entry = entries[root], Date().timeIntervalSince(entry.loadedAt) < Self.freshFor {
            done(entry)
            return
        }
        waiters[root, default: []].append(done)
        guard !loading.contains(root) else { return }
        loading.insert(root)
        Task {
            let result = await Task.detached(priority: .userInitiated) { ProjectFileIndex.list(root: root) }.value
            let entry = Entry(items: EditorFileIndex.items(result, root: root), truncated: result.truncated,
                              fromGit: result.fromGit, loadedAt: Date())
            self.entries[root] = entry
            self.loading.remove(root)
            let waiting = self.waiters.removeValue(forKey: root) ?? []
            waiting.forEach { $0(entry) }
        }
    }
}
