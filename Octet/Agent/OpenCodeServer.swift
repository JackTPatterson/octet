import AppKit
import Foundation

/// The one `opencode serve` process behind every OpenCode conversation.
///
/// OpenCode is a local HTTP server: sessions, prompts and answers go in as
/// requests, and progress comes back on one event stream. One server serves
/// every folder (each request names its `directory`), so Octet starts it once,
/// on loopback with a password made fresh each launch, and routes the stream
/// to whichever conversation each event is about.
@MainActor
final class OpenCodeServer {
    static let shared = OpenCodeServer()

    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case exited(String)
        case http(Int, String)
        case unreachable(String)

        var description: String {
            switch self {
            case .notInstalled: "OpenCode isn't installed, or isn't on your shell's PATH."
            case .exited(let detail): detail.isEmpty ? "OpenCode's server stopped." : "OpenCode's server stopped: \(detail)"
            case .http(let status, let body): "OpenCode answered \(status)" + (body.isEmpty ? "" : ": \(body)")
            case .unreachable(let detail): "Couldn't reach OpenCode's server: \(detail)"
            }
        }
    }

    /// Everything that wants the stream: each open OpenCode conversation.
    protocol Listener: AnyObject {
        func openCodeEvent(_ event: [String: Any])
        /// The server went away (or came back); a turn in flight is lost.
        func openCodeServerRestarted()
        /// The event stream reconnected; anything sent meanwhile was missed.
        func openCodeStreamResumed()
    }

    private var process: Process?
    private(set) var baseURL: URL?
    private let password = UUID().uuidString + UUID().uuidString
    private var waiters: [(Result<URL, Failure>) -> Void] = []
    private var starting = false
    private var output = ""
    private var stream: Task<Void, Never>?
    private var listeners: [ObjectIdentifier: WeakListener] = [:]
    private var terminateWatch: NSObjectProtocol?

    private struct WeakListener { weak var value: Listener? }

    // MARK: - Listening

    func listen(_ listener: Listener) {
        listeners[ObjectIdentifier(listener)] = WeakListener(value: listener)
    }

    func stopListening(_ listener: Listener) {
        listeners.removeValue(forKey: ObjectIdentifier(listener))
    }

    // MARK: - Starting

    /// The server's address, starting it if it isn't running.
    func ready(_ completion: @escaping (Result<URL, Failure>) -> Void) {
        if let baseURL, process?.isRunning == true { return completion(.success(baseURL)) }
        waiters.append(completion)
        guard !starting else { return }
        start()
    }

    private func start() {
        starting = true
        output = ""
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // A login shell, so OpenCode sees the PATH, keys and config it gets in
        // a terminal. Port 0 picks a free one, which it prints.
        process.arguments = ["-l", "-c", "exec opencode serve --hostname 127.0.0.1 --port 0"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { OpenCodeServer.shared.read(text) } }
        }
        process.terminationHandler = { ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { OpenCodeServer.shared.ended(ended, status: status) } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            finish(.failure(.unreachable(error.localizedDescription)))
            return
        }
        if terminateWatch == nil {
            terminateWatch = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { OpenCodeServer.shared.shutDown() } }
        }
        // A server that never says where it's listening isn't coming up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.starting else { return }
            self.shutDown()
            self.finish(.failure(.unreachable("it didn't start within 30 seconds")))
        }
    }

    private func read(_ text: String) {
        output = String((output + text).suffix(4000))
        guard starting,
              let match = output.range(of: #"listening on (http://[0-9.:a-z]+)"#, options: .regularExpression),
              let url = URL(string: String(output[match]).replacingOccurrences(of: "listening on ", with: "")) else { return }
        baseURL = url
        subscribe()
        finish(.success(url))
    }

    private func finish(_ result: Result<URL, Failure>) {
        starting = false
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(result) }
    }

    private func ended(_ ended: Process, status: Int32) {
        guard ended === process else { return }
        process = nil
        baseURL = nil
        stream?.cancel()
        stream = nil
        connectedBefore = false
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if starting {
            let notFound = status == 127 || detail.contains("command not found")
            finish(.failure(notFound ? .notInstalled : .exited(String(detail.suffix(300)))))
        } else {
            listeners.values.compactMap(\.value).forEach { $0.openCodeServerRestarted() }
        }
    }

    func shutDown() {
        stream?.cancel()
        stream = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        baseURL = nil
    }

    // MARK: - Requests

    private var authorization: String {
        "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }

    /// One request, in `directory` (the project a session belongs to). The
    /// answer is the decoded JSON body, or nil for an empty one.
    func request(_ method: String, _ path: String, directory: String?, body: Any? = nil,
                 completion: @escaping (Result<Any?, Failure>) -> Void) {
        ready { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                completion(.failure(failure))
            case .success(let base):
                self.send(method, path, base: base, directory: directory, body: body, completion: completion)
            }
        }
    }

    private func send(_ method: String, _ path: String, base: URL, directory: String?, body: Any?,
                      completion: @escaping (Result<Any?, Failure>) -> Void) {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return }
        if let directory { components.queryItems = [URLQueryItem(name: "directory", value: directory)] }
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Any?, Failure>
            if let error {
                result = .failure(.unreachable(error.localizedDescription))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if (200..<300).contains(status) {
                    result = .success(data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0) })
                } else {
                    result = .failure(.http(status, Self.message(fromBody: text)))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// The message in an error body, which is JSON when OpenCode wrote it.
    private nonisolated static func message(fromBody body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return String(body.prefix(300)) }
        let data2 = json["data"] as? [String: Any]
        return data2?["message"] as? String ?? json["message"] as? String ?? json["error"] as? String ?? String(body.prefix(300))
    }

    // MARK: - Events

    /// One stream for every folder the server works in: each event arrives
    /// as `{directory, payload}` and goes to every listener, which keeps the
    /// ones about its own session.
    private func subscribe() {
        stream?.cancel()
        guard let base = baseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent("global/event"))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity
        stream = Task.detached(priority: .userInitiated) {
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:"),
                          let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                          let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let event = wrapper["payload"] as? [String: Any] ?? wrapper
                    await MainActor.run { OpenCodeServer.shared.deliver(event) }
                }
            } catch {}
            // The stream closed while the server lives on: reconnect.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                let server = OpenCodeServer.shared
                if server.process?.isRunning == true, !Task.isCancelled { server.subscribe() }
            }
        }
    }

    /// Whether the stream has connected before: its events carry no ids to
    /// resume from, so after a reconnect conversations refetch instead.
    private var connectedBefore = false

    private func deliver(_ event: [String: Any]) {
        if event["type"] as? String == "server.connected" {
            defer { connectedBefore = true }
            guard connectedBefore else { return }
            for listener in listeners.values.compactMap(\.value) { listener.openCodeStreamResumed() }
            return
        }
        for listener in listeners.values.compactMap(\.value) { listener.openCodeEvent(event) }
    }
}
