import Foundation

/// Permission prompts for conversations Herd drives headless. The agent is
/// started with `--permission-prompt-tool mcp__herd__approve`; that tool is
/// `herd-cli mcp-permission`, a stdio MCP server, which relays each prompt
/// over a Unix socket to the app and returns the user's answer.
enum PermissionMCP {
    static let serverName = "herd"
    static let toolName = "approve"
    /// What the agent's `--permission-prompt-tool` flag names.
    static var qualifiedToolName: String { "mcp__\(serverName)__\(toolName)" }

    /// The `--mcp-config` JSON registering the tool for one conversation.
    static func mcpConfig(cliPath: String, socketPath: String) -> String {
        let config: [String: Any] = ["mcpServers": [serverName: [
            "type": "stdio", "command": cliPath, "args": ["mcp-permission", "--socket", socketPath],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Answers one JSON-RPC line. `ask` gets the tool's arguments
    /// (`tool_name`, `input`, `tool_use_id`) and returns the decision.
    static func respond(to line: String, ask: ([String: Any]) -> [String: Any]) -> String? {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": "1"],
            ]
        case "tools/list":
            result = ["tools": [[
                "name": toolName,
                "description": "Asks the Herd user to allow or deny a tool call.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tool_name": ["type": "string"],
                        "input": ["type": "object"],
                        "tool_use_id": ["type": "string"],
                    ],
                    "required": ["tool_name", "input"],
                ] as [String: Any],
            ]]]
        case "tools/call":
            let decision = ask(params["arguments"] as? [String: Any] ?? [:])
            let text = (try? JSONSerialization.data(withJSONObject: decision)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            result = ["content": [["type": "text", "text": text]]]
        default:
            // Notifications carry no id and get no reply.
            guard id != nil else { return nil }
            result = [:]
        }
        guard let id else { return nil }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: response)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Relays one prompt to the app and waits for the answer. Denies when
    /// Herd can't be reached, so nothing runs unasked.
    static func askApp(socketPath: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let connection = try EngineSocketConnection(path: socketPath)
            try connection.send(arguments)
            let line = try connection.readLine()
            if let decision = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return decision }
        } catch {}
        return ["behavior": "deny", "message": "Herd couldn't show this permission prompt, so it was denied."]
    }
}

/// The app's end of the bridge: one line in (the prompt), one line out
/// (the decision), per connection. Replies can come later, from the UI.
final class PermissionSocketServer {
    let path: String
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "herd.permission-socket")

    init(path: String) {
        self.path = path
    }

    /// `handler` runs on the main queue with the prompt and a reply closure.
    func start(handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw EngineSocketError.connectFailed(path: path, errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngineSocketError.connectFailed(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            throw EngineSocketError.connectFailed(path: path, errno: errno)
        }
        // Only this user may answer this conversation's prompts.
        chmod(path, 0o600)
        let socketFD = listener
        queue.async {
            while true {
                let client = accept(socketFD, nil, nil)
                guard client >= 0 else { return }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async { Self.serve(client, handler: handler) }
            }
        }
    }

    private static func serve(_ fd: Int32, handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { close(fd); return }
            buffer.append(chunk, count: n)
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let prompt = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { close(fd); return }
        DispatchQueue.main.async {
            handler(prompt) { decision in
                var data = (try? JSONSerialization.data(withJSONObject: decision)) ?? Data("{}".utf8)
                data.append(0x0A)
                DispatchQueue.global().async {
                    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    close(fd)
                }
            }
        }
    }

    func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    deinit { stop() }
}
