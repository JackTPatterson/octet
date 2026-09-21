import Foundation

/// Errors from the session server's socket API.
enum EngineSocketError: Error, CustomStringConvertible {
    case connectFailed(path: String, errno: Int32)
    case writeFailed
    case closed
    case server(code: String, message: String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .connectFailed(let path, let err):
            return "cannot reach the terminal at \(path): \(String(cString: strerror(err)))"
        case .writeFailed: return "write to the terminal failed"
        case .closed: return "the terminal connection closed"
        case .server(let code, let message): return "terminal error \(code): \(message)"
        case .malformedResponse(let line): return "malformed terminal response: \(line.prefix(200))"
        }
    }
}

/// A line-oriented connection to the session server's newline-delimited JSON socket.
final class EngineSocketConnection {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineSocketError.connectFailed(path: path, errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw EngineSocketError.connectFailed(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw EngineSocketError.connectFailed(path: path, errno: err)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let written = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard written == data.count else { throw EngineSocketError.writeFailed }
    }

    /// Blocks until one full line arrives.
    func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw EngineSocketError.closed }
            buffer.append(chunk, count: n)
        }
    }

    func shutdownNow() {
        shutdown(fd, SHUT_RDWR)
    }
}

/// Request/response access to the session server's socket API. Each call opens a short
/// connection, which keeps the client stateless and thread-safe.
struct EngineClient {
    let socketPath: String

    /// Socket for a named session (`<state folder>/sessions/<name>/<socket file>`).
    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/" + EngineProtocol.stateDirectory
        let socket = EngineProtocol.socketFileName
        guard let session, !session.isEmpty else { return base + "/" + socket }
        return base + "/sessions/\(session)/" + socket
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let connection = try EngineSocketConnection(path: socketPath)
        let id = "octet-\(UUID().uuidString.prefix(8))"
        try connection.send(["id": id, "method": method, "params": params])
        let line = try connection.readLine()
        return try Self.parseResponse(line)
    }

    static func parseResponse(_ line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw EngineSocketError.malformedResponse(String(decoding: line, as: UTF8.self))
        }
        if let error = object["error"] as? [String: Any] {
            throw EngineSocketError.server(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? ""
            )
        }
        guard let result = object["result"] as? [String: Any] else {
            throw EngineSocketError.malformedResponse(String(decoding: line, as: UTF8.self))
        }
        return result
    }

    func snapshot() throws -> EngineSnapshot {
        let result = try call("session.snapshot")
        guard let raw = result["snapshot"] else {
            throw EngineSocketError.malformedResponse("session.snapshot without snapshot")
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(EngineSnapshot.self, from: data)
    }

    /// Event types Octet listens to; any of them triggers a snapshot refresh.
    static let subscribedEvents = [
        "workspace.created", "workspace.updated", "workspace.renamed", "workspace.moved",
        "workspace.reordered", "workspace.closed", "workspace.focused",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved",
        "pane.exited", "pane.agent_detected", "layout.updated",
        // pane.agent_status_changed requires a pane_id; agent state is picked
        // up by SessionStore's periodic refresh instead.
    ]

    /// Opens a subscription and calls `onEvent` with each pushed event's type
    /// until the connection closes or `connection.shutdownNow()` is called.
    func subscribe(
        connectionCreated: (EngineSocketConnection) -> Void,
        onEvent: (String) -> Void
    ) throws {
        let connection = try EngineSocketConnection(path: socketPath)
        try connection.send([
            "id": "octet-events",
            "method": "events.subscribe",
            "params": ["subscriptions": Self.subscribedEvents.map { ["type": $0] }],
        ])
        _ = try Self.parseResponse(try connection.readLine())
        connectionCreated(connection)
        while true {
            let line = try connection.readLine()
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = (object["event"] as? String)
                ?? (object["type"] as? String)
                ?? ((object["result"] as? [String: Any])?["type"] as? String)
                ?? "event"
            onEvent(type)
        }
    }
}
