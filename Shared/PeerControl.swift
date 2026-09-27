import Foundation

/// How `octet-cli peer …` and the agents' MCP tools reach the app: one JSON
/// line to a Unix socket only this user can open, one line back.
enum PeerControl {
    static let socketName = "peers.sock"
    /// Set in every pane of a session Octet started, when it knows it.
    static let socketVariable = "OCTET_PEERS_SOCKET"

    /// The app's socket for a session: Octet's support folder, or the
    /// session's own under it.
    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Application Support/Octet"
        guard let session, !session.isEmpty, session != "octet" else { return base + "/" + socketName }
        return base + "/sessions/\(session)/" + socketName
    }

    /// Where to reach the app from here: `--socket`, the pane's variable,
    /// else the session's (OCTET_SESSION, or Octet's own).
    static func resolveSocket(explicit: String?, environment: [String: String]) -> String {
        explicit ?? environment[socketVariable] ?? socketPath(session: environment["OCTET_SESSION"] ?? session(ofServer: environment[EngineProtocol.socketPathVariable]))
    }

    /// `…/sessions/<name>/herdr.sock` → `<name>`: the session a pane is in,
    /// for servers started before panes were told the socket.
    static func session(ofServer socket: String?) -> String? {
        guard let parts = socket?.split(separator: "/").map(String.init),
              let index = parts.lastIndex(of: "sessions"), parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    /// Where a request comes from: an Octet pane, named by the session
    /// server that set these in its environment. Nil outside Octet, where
    /// the feature doesn't exist: other terminals get no tools.
    struct Origin: Equatable {
        let pane: String
        let session: String

        static func current(_ environment: [String: String]) -> Origin? {
            guard let pane = environment[EngineProtocol.paneIdVariable], !pane.isEmpty,
                  let session = environment[EngineProtocol.socketPathVariable], !session.isEmpty,
                  environment[socketVariable] != nil || environment["OCTET_CLI"] != nil else { return nil }
            return Origin(pane: pane, session: session)
        }

        var params: [String: Any] { ["from_pane": pane, "from_session": session] }
    }

    static let notInOctet = "This only works inside Octet: run it from an Octet terminal pane."

    enum Method: String {
        case machines, agents, send, read, delegate, wait, status, pair
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Asks the app; the answer's `error` becomes a thrown failure.
    static func call(socketPath: String, method: Method, params: [String: Any]) throws -> [String: Any] {
        let connection: EngineSocketConnection
        do {
            connection = try EngineSocketConnection(path: socketPath)
        } catch {
            throw Failure(message: "Octet isn't reachable at \(socketPath). Is it open, with Settings › Other Macs on?")
        }
        try connection.send(["method": method.rawValue, "params": params])
        let line = try connection.readLine()
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Failure(message: "Octet sent back something unreadable.")
        }
        if let error = answer["error"] as? String { throw Failure(message: error) }
        return answer["result"] as? [String: Any] ?? [:]
    }
}

/// The agents' side: a stdio MCP server (`octet-cli peer-mcp`) whose tools
/// talk to agents on other Macs through the app.
enum PeerMCP {
    static let serverName = "octet-peers"

    static let tools: [[String: Any]] = [
        tool("list_machines", "Lists the Macs paired with this one through Octet, whether each is online, and nearby Macs not yet paired.", [:], []),
        tool("list_agents", "Lists the coding agents running on another Mac: id, which agent, project folder and status (working, idle, blocked, done).",
             ["machine": string("The Mac's name, from list_machines.")], ["machine"]),
        tool("send_to_agent", "Sends a message to an agent on another Mac. It arrives as that agent's next prompt, saying who sent it and how to answer. The person at that Mac may be asked to allow it.",
             ["machine": string("The Mac's name."), "agent": string("The agent's id, from list_agents."),
              "message": string("What to say.")], ["machine", "agent", "message"]),
        tool("read_agent", "Reads the last lines of an agent's screen on another Mac, to see what it's doing or what it answered.",
             ["machine": string("The Mac's name."), "agent": string("The agent's id."),
              "lines": ["type": "integer", "description": "How many lines, up to 400. Default 60."]], ["machine", "agent"]),
        tool("delegate_task", "Starts an agent on another Mac, in a folder there, on a task. Returns a task id; the result (the end of the agent's screen when it finishes) comes back to wait_for_task. The person at that Mac may be asked to allow it.",
             ["machine": string("The Mac's name."),
              "agent_type": ["type": "string", "enum": ["claude", "codex"], "description": "Which agent to start."],
              "folder": string("Absolute path of the project folder on that Mac."),
              "task": string("What the agent should do."),
              "wait": ["type": "boolean", "description": "Wait for it to finish before returning. Default false."],
              "timeout_seconds": ["type": "integer", "description": "How long to wait when waiting. Default 600."]],
             ["machine", "agent_type", "folder", "task"]),
        tool("wait_for_task", "Waits for a delegated task to finish and returns its result, or its status if it doesn't finish in time.",
             ["task": string("The id delegate_task returned."),
              "timeout_seconds": ["type": "integer", "description": "How long to wait. Default 600."]], ["task"]),
    ]

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    /// The app call for a tool: which method, with what.
    static func request(tool: String, arguments: [String: Any], origin: PeerControl.Origin) -> (PeerControl.Method, [String: Any])? {
        var params = arguments.merging(origin.params) { $1 }
        switch tool {
        case "list_machines": return (.machines, params)
        case "list_agents": return (.agents, params)
        case "send_to_agent":
            params["text"] = arguments["message"]
            return (.send, params)
        case "read_agent": return (.read, params)
        case "delegate_task": return (.delegate, params)
        case "wait_for_task": return (.wait, params)
        default: return nil
        }
    }

    /// What the agent is told when the server starts, so it knows it can
    /// reach other Macs and how. From the app's `machines` answer.
    static func instructions(machines answer: [String: Any]) -> String {
        let here = answer["this_machine"] as? String ?? "this Mac"
        let on = answer["on"] as? Bool ?? false
        let machines = answer["machines"] as? [[String: Any]] ?? []
        var text = "You're running inside Octet on \(here). "
        guard on else {
            return text + "Octet can connect this Mac to the person's other Macs so agents can work together, but that's turned off (Octet Settings › Other Macs). Don't use these tools unless the person turns it on."
        }
        if machines.isEmpty {
            text += "Octet can connect this Mac to the person's other Macs running Octet, but none are paired yet; the person pairs them in Octet's Settings › Other Macs. "
        } else {
            let list = machines.map { machine in
                "\(machine["name"] as? String ?? "?") (\(machine["online"] as? Bool == true ? "online" : "not connected right now"))"
            }.joined(separator: ", ")
            text += "It's paired with the person's other Macs: \(list). "
        }
        text += "With these tools you can list the coding agents on another Mac (list_agents), send one a message that arrives as its next prompt (send_to_agent), read its screen (read_agent), or start an agent there on a task in a project folder and get the result back (delegate_task, then wait_for_task). Use them when work belongs on another Mac or another agent's help is needed. The person at the other Mac may have to approve messages and tasks. A prompt that starts with \"[Message from … over Octet]\" came from an agent on another Mac; answer it with send_to_agent, using the machine and agent it names."
        return text
    }

    /// Answers one JSON-RPC line. `call` asks the app. Outside Octet
    /// (`origin` nil) the server offers no tools and says nothing.
    static func respond(to line: String, origin: PeerControl.Origin?,
                        instructions: () -> String? = { nil },
                        call: (PeerControl.Method, [String: Any]) throws -> [String: Any]) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": serverName, "version": "1"]]
            if origin != nil, let text = instructions() { result["instructions"] = text }
        case "tools/list":
            result = ["tools": origin == nil ? [] : tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let origin else {
                result = ["content": [["type": "text", "text": PeerControl.notInOctet]], "isError": true]
                break
            }
            guard let (method, callParams) = self.request(tool: name, arguments: arguments, origin: origin) else {
                result = ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
                break
            }
            do {
                var answer = try call(method, callParams)
                // delegate_task with wait: start it, then wait for it.
                if method == .delegate, arguments["wait"] as? Bool == true, let task = answer["task"] as? String {
                    answer = try call(.wait, origin.params.merging(["task": task, "timeout_seconds": arguments["timeout_seconds"] ?? 600]) { $1 })
                }
                result = ["content": [["type": "text", "text": text(answer)]]]
            } catch {
                result = ["content": [["type": "text", "text": String(describing: error)]], "isError": true]
            }
        default:
            guard id != nil else { return nil }
            result = [:]
        }
        guard let id else { return nil }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: response)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func text(_ answer: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The commands that add this server to an agent's MCP config.
    static func installCommands(cliPath: String, agents: [String]) -> [String] {
        let quoted = "'" + cliPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return agents.compactMap { agent in
            switch agent {
            case "claude": "claude mcp add --scope user \(serverName) -- \(quoted) peer-mcp"
            case "codex": "codex mcp add \(serverName) -- \(quoted) peer-mcp"
            default: nil
            }
        }
    }
}
