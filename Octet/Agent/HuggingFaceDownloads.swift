import AppKit
import Combine
import Foundation

/// Models being pulled from Hugging Face through Ollama, and the ones that
/// finished this launch. Each goes: checking Ollama is up (started if it's
/// installed but not running), pulling with Ollama's own progress, then
/// written into OpenCode's config as an Ollama model.
@MainActor
final class HuggingFaceDownloads: ObservableObject {
    static let shared = HuggingFaceDownloads()

    enum Phase: Equatable {
        case waiting
        case checking
        case pulling(OllamaPull.Progress)
        case registering
        case done
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .waiting, .checking, .pulling, .registering: true
            case .done, .failed, .cancelled: false
            }
        }

        var text: String {
            switch self {
            case .waiting: "Waiting…"
            case .checking: "Checking Ollama…"
            case .pulling(let progress): progress.text
            case .registering: "Adding to OpenCode…"
            case .done: "Ready in OpenCode"
            case .failed(let reason): reason
            case .cancelled: "Cancelled"
            }
        }

        /// 0 to 1 while there's a number to show, nil while there isn't.
        var fraction: Double? {
            switch self {
            case .pulling(let progress): progress.fraction
            case .registering, .done: 1
            default: nil
            }
        }
    }

    struct Download: Identifiable, Equatable {
        let id: UUID
        let reference: HuggingFaceModel.Reference
        var phase: Phase = .waiting
        let startedAt: Date

        var modelID: String { OpenCodeOllama.modelID(reference.ollamaName) }
    }

    enum Ollama: Equatable {
        case unknown
        case running(version: String)
        case stopped(installed: Bool)
    }

    @Published private(set) var downloads: [Download] = []
    @Published private(set) var ollama: Ollama = .unknown
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var toasts: [UUID: ToastCenter.Handle] = [:]
    private var serve: Process?

    /// The session that works with these models (ollama is only on
    /// OpenCode's side), configured for the long pull of a big file.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration)
    }()

    // MARK: - Ollama

    /// Whether Ollama answers on its port, and if not, whether it's
    /// installed so it can be started.
    func checkOllama() {
        Task { await refreshOllama() }
    }

    @discardableResult
    private func refreshOllama() async -> Ollama {
        var request = URLRequest(url: OllamaPull.baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        if let answer = try? await Self.session.data(for: request),
           (answer.1 as? HTTPURLResponse)?.statusCode == 200 {
            let version = (try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any])?["version"] as? String
            ollama = .running(version: version ?? "")
        } else {
            let installed = await Task.detached { Self.ollamaExecutable() != nil }.value || Self.ollamaApp() != nil
            ollama = .stopped(installed: installed)
        }
        return ollama
    }

    /// Starts Ollama: the app if it's there (its menu bar item keeps it
    /// up), else `ollama serve` kept for the app's life. Waits for it.
    func startOllama() async -> Bool {
        if case .running = await refreshOllama() { return true }
        if let app = Self.ollamaApp() {
            NSWorkspace.shared.openApplication(at: app, configuration: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                return configuration
            }()) { _, _ in }
        } else if let executable = Self.ollamaExecutable(), serve?.isRunning != true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            serve = process
        } else {
            return false
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if case .running = await refreshOllama() { return true }
        }
        return false
    }

    nonisolated private static func ollamaExecutable() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["PATH"]
        return AgentDiscovery.locate(command: "ollama", in: AgentDiscovery.searchDirectories(shellPath: shellPath))
    }

    private static func ollamaApp() -> URL? {
        for path in ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
        where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
    }

    // MARK: - Downloads

    func download(_ id: UUID) -> Download? { downloads.first { $0.id == id } }

    /// Whether this model is already pulled and in OpenCode's config.
    func isDone(_ reference: HuggingFaceModel.Reference) -> Bool {
        downloads.contains { $0.reference == reference && $0.phase == .done }
    }

    /// Pulls the model, unless it's on its way already; `then` runs with
    /// the OpenCode model id once it's usable.
    @discardableResult
    func add(_ reference: HuggingFaceModel.Reference, then: (@MainActor (String) -> Void)? = nil) -> UUID {
        if let existing = downloads.first(where: { $0.reference == reference && $0.phase.isActive }) {
            return existing.id
        }
        let download = Download(id: UUID(), reference: reference, startedAt: Date())
        downloads.removeAll { $0.reference == reference }
        downloads.insert(download, at: 0)
        start(download, then: then)
        return download.id
    }

    func retry(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), !downloads[index].phase.isActive else { return }
        downloads[index].phase = .waiting
        start(downloads[index], then: nil)
    }

    func cancel(_ id: UUID) {
        guard let task = tasks[id] else { return }
        task.cancel()
        tasks[id] = nil
        set(id, .cancelled)
        if let toast = toasts.removeValue(forKey: id) { ToastCenter.shared.dismiss(handleId: toast) }
    }

    func remove(_ id: UUID) {
        cancel(id)
        downloads.removeAll { $0.id == id }
    }

    private func set(_ id: UUID, _ phase: Phase) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].phase = phase
        if let toast = toasts[id] {
            switch phase {
            case .pulling(let progress) where progress.fraction != nil:
                let percent = Int((progress.fraction ?? 0) * 100)
                ToastCenter.shared.update(toast, title: "Downloading \(downloads[index].reference.displayName) · \(percent)%",
                                          detail: progress.text)
            case .pulling(let progress):
                ToastCenter.shared.update(toast, title: "Downloading \(downloads[index].reference.displayName)", detail: progress.text)
            case .registering:
                ToastCenter.shared.update(toast, title: "Adding \(downloads[index].reference.displayName) to OpenCode")
            default: break
            }
        }
    }

    private func start(_ download: Download, then: (@MainActor (String) -> Void)?) {
        let id = download.id
        let reference = download.reference
        toasts[id] = ToastCenter.shared.progress("Downloading \(reference.displayName)", detail: "From Hugging Face, through Ollama")
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                set(id, .checking)
                guard await startOllama() else {
                    var installed = false
                    if case .stopped(let found) = ollama { installed = found }
                    throw Problem.noOllama(installed: installed)
                }
                set(id, .pulling(OllamaPull.Progress(status: "pulling manifest")))
                try await pull(reference, id: id)
                try Task.checkCancellation()
                set(id, .registering)
                try register(reference)
                try Task.checkCancellation()
                set(id, .done)
                tasks[id] = nil
                if let toast = toasts.removeValue(forKey: id) {
                    ToastCenter.shared.succeed(toast, "\(reference.displayName) is ready",
                                               detail: "In OpenCode's model menu, under Ollama")
                }
                then?(download.modelID)
            } catch {
                // Cancelled: marked by cancel() already.
                guard !Task.isCancelled else { return }
                tasks[id] = nil
                let reason = (error as? Problem)?.message ?? error.localizedDescription
                set(id, .failed(reason))
                if let toast = toasts.removeValue(forKey: id) {
                    ToastCenter.shared.fail(toast, "Couldn't add \(reference.displayName)", detail: reason,
                                            action: (error as? Problem)?.action)
                }
            }
        }
    }

    private enum Problem: Error {
        case noOllama(installed: Bool)
        case pull(String)
        case config(String)

        var message: String {
            switch self {
            case .noOllama(let installed):
                installed ? "Ollama is installed but didn't start. Open it, then try again."
                          : "Ollama runs the model, and isn't installed. Get it from ollama.com, then try again."
            case .pull(let reason): reason
            case .config(let reason): reason
            }
        }

        var action: ToastCenter.Action? {
            guard case .noOllama(let installed) = self, !installed else { return nil }
            return ToastCenter.Action(title: "Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
        }
    }

    /// Ollama's streaming pull; each line is a step or a layer's progress.
    private func pull(_ reference: HuggingFaceModel.Reference, id: UUID) async throws {
        var request = URLRequest(url: OllamaPull.baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = OllamaPull.body(model: reference.ollamaName)
        let (bytes, response) = try await Self.session.bytes(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            let reason = OllamaPull.parse(line: body)?.error ?? body
            throw Problem.pull(reason.isEmpty ? "Ollama answered \(status)" : reason)
        }
        var finished = false
        var shownAt = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let progress = OllamaPull.parse(line: line) else { continue }
            if let error = progress.error { throw Problem.pull(Self.explain(error, reference: reference)) }
            if progress.isDone { finished = true }
            // Ollama reports many times a second; the row is redrawn ten.
            let now = Date()
            guard finished || progress.fraction == nil || now.timeIntervalSince(shownAt) > 0.1 else { continue }
            shownAt = now
            set(id, .pulling(progress))
        }
        guard finished else { throw Problem.pull("Ollama stopped before the download finished.") }
    }

    /// Ollama's errors in plainer words, where it's clear what happened.
    private static func explain(_ error: String, reference: HuggingFaceModel.Reference) -> String {
        let lowered = error.lowercased()
        if lowered.contains("file does not exist") || lowered.contains("not found") || lowered.contains("404") {
            return reference.quantization != nil
                ? "Hugging Face has no \(reference.quantization ?? "") GGUF file in \(reference.repoId)."
                : "Hugging Face has no GGUF files in \(reference.repoId); Ollama needs a GGUF repo."
        }
        if lowered.contains("unauthorized") || lowered.contains("401") || lowered.contains("403") || lowered.contains("gated") {
            return "\(reference.repoId) is gated: accept its terms on Hugging Face and give Ollama your Hugging Face key (`ollama` reads HF_TOKEN)."
        }
        return error
    }

    /// Puts the model in OpenCode's config, and has the server read it.
    private func register(_ reference: HuggingFaceModel.Reference) throws {
        let path = AgentMCP.opencodeConfig(home: NSHomeDirectory())
        let existing = FileManager.default.contents(atPath: path)
        guard let data = OpenCodeOllama.registered(existing, model: reference.ollamaName, name: reference.displayName) else {
            throw Problem.config("\(path) isn't plain JSON; add \(reference.ollamaName) under provider.ollama there by hand.")
        }
        if data != existing {
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw Problem.config(error.localizedDescription)
            }
        }
        // OpenCode reads its config when it starts: the server is started
        // again, unless a conversation is mid-turn, which it would lose.
        let busy = AgentCenter.shared.sessions.contains { $0.engine == .opencode && $0.conversation.isRunning }
        if !busy { OpenCodeServer.shared.shutDown() }
        let store = OpenCodeCatalogStore.shared
        for cwd in store.catalogs.keys { store.load(cwd: cwd, refresh: true) }
        if store.everything != nil, let cwd = store.catalogs.keys.first { store.loadEverything(cwd: cwd) }
    }
}
