import Foundation

/// One-shot questions for `codex app-server`.
///
/// A conversation keeps its own server for the life of the thread (see
/// `AgentSession`); this is for the things Octet asks outside one: what the
/// allowance is, what models exist, which sandboxes are allowed. It starts a
/// server, asks, and ends it.
enum CodexRPC {
    struct Call {
        let id: Int
        let method: String
        var params: [String: Any] = [:]
    }

    /// What `initialize` says about Octet. `experimentalApi` is what lets a
    /// thread's model and effort change without restarting it.
    static func handshake(requestId: Int = 1) -> [[String: Any]] {
        [
            ["jsonrpc": "2.0", "id": requestId, "method": "initialize",
             "params": ["clientInfo": ["name": "octet", "title": "Octet", "version": AgentSession.version],
                        "capabilities": ["experimentalApi": true]]],
            ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
        ]
    }

    /// Makes every call and returns the results by id. Calls that error or
    /// never answer are simply absent.
    static func ask(_ calls: [Call], timeout: TimeInterval = 20) -> [Int: [String: Any]] {
        guard !calls.isEmpty else { return [:] }
        var lines = handshake().compactMap(encode)
        lines += calls.compactMap { encode(["jsonrpc": "2.0", "id": $0.id, "method": $0.method, "params": $0.params]) }

        let wanted = Set(calls.map(\.id))
        var results: [Int: [String: Any]] = [:]
        run(input: lines.joined(separator: "\n") + "\n", timeout: timeout) { message in
            guard let id = message["id"] as? Int, wanted.contains(id) else { return false }
            if let result = message["result"] as? [String: Any] { results[id] = result }
            // Answered, one way or the other.
            results[id] = results[id] ?? [:]
            return results.count == wanted.count
        }
        return results
    }

    private static func encode(_ message: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: message)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Starts an app server, writes `input`, and hands each JSON-RPC message
    /// to `receive` until it says it has enough or `timeout` passes. The
    /// server holds its pipe open, so it is always ended here.
    private static func run(input: String, timeout: TimeInterval, receive: @escaping ([String: Any]) -> Bool) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "exec codex app-server"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return }
        stdin.fileHandleForWriting.write(Data(input.utf8))

        let done = DispatchSemaphore(value: 0)
        let reader = Reader(receive: receive)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty || reader.take(chunk) { break }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        process.terminate()
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit() }
    }

    /// Splits the server's output into lines across reads, and stops when the
    /// caller has what it came for.
    private final class Reader {
        private let lock = NSLock()
        private var buffer = Data()
        private let receive: ([String: Any]) -> Bool

        init(receive: @escaping ([String: Any]) -> Bool) { self.receive = receive }

        /// True once the caller is satisfied.
        func take(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if receive(message) { return true }
            }
            return false
        }
    }
}
