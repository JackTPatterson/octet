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
        case .notText: return "This file is not UTF-8 text."
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
    private var savedText: String
    private(set) var diskModificationDate: Date?

    var name: String { url.lastPathComponent }
    var directory: String { url.deletingLastPathComponent().path }
    var lineCount: Int { max(1, text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }) }

    init(url: URL) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw EditorError.directory
        }
        let data = try Data(contentsOf: canonical, options: [.mappedIfSafe])
        guard data.count <= Self.maximumBytes else { throw EditorError.tooLarge(data.count) }
        guard let string = String(data: data, encoding: .utf8), !string.contains("\0") else { throw EditorError.notText }
        id = canonical.path
        self.url = canonical
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
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
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
    /// wins until the user explicitly reloads it, so their typing is not lost.
    func refreshFromDisk() {
        guard !isDirty, let modified = Self.modificationDate(url), modified != diskModificationDate,
              let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes,
              let string = String(data: data, encoding: .utf8) else { return }
        text = string
        savedText = string
        diskModificationDate = modified
    }

    func reloadDiscardingChanges() {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes,
              let string = String(data: data, encoding: .utf8) else { return }
        text = string
        savedText = string
        isDirty = false
        lastError = nil
        diskModificationDate = Self.modificationDate(url)
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
    @Published var fileTreeVisible = true
    @Published var filePickerVisible = false
    @Published var presentation: Presentation = .split
    var requestedPresentation: Presentation = .split
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
    static let ignoredDirectories: Set<String> = [".git", "build", "DerivedData", "node_modules", ".build", "Pods"]

    static func files(in root: String, limit: Int = 20_000) -> [EditorFileItem] {
        // Normalize aliases such as macOS' /var -> /private/var before deriving
        // relative paths; FileManager's enumerator reports canonical child URLs.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var result: [EditorFileItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, ignoredDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard canonicalURL.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(canonicalURL.path.dropFirst(rootPrefix.count))
            result.append(EditorFileItem(path: canonicalURL.path, relativePath: relative))
            if result.count >= limit { break }
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
