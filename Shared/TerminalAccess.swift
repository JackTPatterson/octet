import Foundation

/// Letting an agent use the sidebar terminal: the shell in Octet's right
/// panel, where the person runs servers, builds and tests while an agent
/// works. An agent can read what it shows, and can put a command at its
/// prompt for the person to run (it is never run for them). Each is off
/// until Settings › Terminal turns it on, and open to any agent: the agents' side is a stdio MCP server (`octet-cli
/// terminal-mcp`) that Claude Code, Codex, Gemini, Qwen, OpenCode, Cursor
/// and Copilot are given, and a command (`octet-cli terminal read`) for any
/// that can run one. Both ask the app over a Unix socket only this user can
/// open, one JSON line each way.
enum TerminalControl {
    static let socketName = "terminal.sock"
    /// Set in the processes Octet starts for its own conversations, and in
    /// the panes of a session it started, so a tool knows where to ask.
    static let socketVariable = "OCTET_TERMINAL_SOCKET"

    static let defaultLines = 80
    static let maxLines = 500
    static let maxCommandLength = 1000

    /// The app's socket for a session: Octet's support folder, or the
    /// session's own under it.
    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Application Support/Octet"
        guard let session, !session.isEmpty, session != "octet" else { return base + "/" + socketName }
        return base + "/sessions/\(session)/" + socketName
    }

    /// What Octet adds to the environment of a process it starts.
    static func environment(session: String, home: String = NSHomeDirectory()) -> [String: String] {
        [socketVariable: socketPath(session: session, home: home)]
    }

    /// Where to reach the app from here: the variable, else the session's
    /// (OCTET_SESSION, or the one a pane's server belongs to, or Octet's own).
    static func resolveSocket(environment: [String: String]) -> String {
        if let path = environment[socketVariable], !path.isEmpty { return path }
        return socketPath(session: environment["OCTET_SESSION"] ?? PeerControl.session(ofServer: environment[EngineProtocol.socketPathVariable]))
    }

    /// Where a request comes from: a process Octet started, in a pane or
    /// in one of its conversations. Nil elsewhere, where there are no tools:
    /// an agent in another terminal app is not in Octet.
    struct Origin: Equatable {
        /// The pane, when it is in one.
        let pane: String?
        /// Its workspace, when it is in a pane.
        let workspace: String?

        static func current(_ environment: [String: String]) -> Origin? {
            let pane = environment[EngineProtocol.paneIdVariable].flatMap { $0.isEmpty ? nil : $0 }
            let hasSocket = !(environment[socketVariable] ?? "").isEmpty
            let inPane = pane != nil && !(environment[EngineProtocol.socketPathVariable] ?? "").isEmpty
            guard hasSocket || inPane else { return nil }
            return Origin(pane: pane, workspace: environment[EngineProtocol.workspaceIdVariable].flatMap { $0.isEmpty ? nil : $0 })
        }

        var params: [String: Any] {
            var params: [String: Any] = [:]
            if let pane { params["from_pane"] = pane }
            if let workspace { params["from_workspace"] = workspace }
            return params
        }
    }

    static let notInOctet = "This only works inside Octet: run it from an Octet terminal pane or conversation."

    enum Method: String { case read, suggest }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func call(socketPath: String, method: Method, params: [String: Any]) throws -> [String: Any] {
        let connection: EngineSocketConnection
        do {
            connection = try EngineSocketConnection(path: socketPath)
        } catch {
            throw Failure(message: "Octet isn't reachable, or letting agents read the sidebar terminal is off (Octet Settings › Terminal).")
        }
        try connection.send(["method": method.rawValue, "params": params])
        let line = try connection.readLine()
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Failure(message: "Octet sent back something unreadable.")
        }
        if let error = answer["error"] as? String { throw Failure(message: error) }
        return answer["result"] as? [String: Any] ?? [:]
    }

    // MARK: - A command for the person to run

    /// A command fit to be put at a prompt without running: one line of at
    /// most `maxCommandLength` characters, with nothing that would act as a
    /// key (Return, Tab, Escape, a control character) or disguise what it
    /// says (invisible and direction-changing characters). Nil otherwise.
    static func stagedCommand(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCommandLength else { return nil }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) { return nil }
            switch scalar.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator, .control, .surrogate, .privateUse, .unassigned: return nil
            default: break
            }
        }
        return trimmed
    }

    /// Whether a process name is a shell, which is what is in front when
    /// the terminal is waiting at a prompt.
    static func isShell(_ name: String) -> Bool {
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh"].contains(base)
    }

    // MARK: - Text

    /// A requested line count, however the caller spelled it, kept in range.
    static func clampLines(_ requested: Any?) -> Int {
        let value: Int?
        switch requested {
        case let number as Int: value = number
        case let number as Double: value = Int(number)
        case let text as String: value = Int(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, value > 0 else { return defaultLines }
        return min(value, maxLines)
    }

    /// The last `count` lines of `text`, without the blank rows a terminal
    /// pads its screen with and without trailing spaces.
    static func lastLines(_ text: String, count: Int) -> (text: String, total: Int) {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            while line.last == " " || line.last == "\t" || line.last == "\r" { line.removeLast() }
            return line
        }
        while lines.last == "" { lines.removeLast() }
        let total = lines.count
        return (lines.suffix(max(count, 1)).joined(separator: "\n"), total)
    }
}

/// The agents' side: a stdio MCP server (`octet-cli terminal-mcp`) with one
/// tool, which reads the sidebar terminal through the app.
enum TerminalMCP {
    static let serverName = "octet-terminal"
    static let toolName = "read_sidebar_terminal"
    static let suggestToolName = "suggest_sidebar_command"

    static let tools: [[String: Any]] = [
        [
            "name": toolName,
            "description": "Reads the latest output of the terminal in Octet's right-hand panel (the sidebar terminal), where the person runs things like dev servers, builds and tests. Read only: this can't type into it. Use it when the person points at what's in that terminal, or to see the logs or test output of something they started there.",
            "inputSchema": [
                "type": "object",
                "properties": ["lines": ["type": "integer",
                                         "description": "How many of the last lines to read, up to \(TerminalControl.maxLines). Default \(TerminalControl.defaultLines)."]],
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": suggestToolName,
            "description": "Opens Octet's sidebar terminal and puts a command at its prompt WITHOUT running it, so the person can read it and run it with Return (or Octet's Run button). Use it when the person should run something themselves: a command that needs their credentials or a password, a long-running server they should watch, or anything you shouldn't run for them. One line only. It fails if the terminal is busy running something. Afterwards, read_sidebar_terminal shows what happened.",
            "inputSchema": [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "The command, on one line, up to \(TerminalControl.maxCommandLength) characters."]],
                "required": ["command"],
            ] as [String: Any],
        ],
    ]

    static let instructions = "You're running inside Octet. The person may have a terminal open in Octet's right-hand panel (the sidebar terminal), where they run things like dev servers, builds and tests. With read_sidebar_terminal you can read its latest output, read only. Use it when the person refers to what's in that terminal, or to see the logs or test results of something they started there. With suggest_sidebar_command you can open that panel and put a command at its prompt for the person to run themselves; it is never run for them. Both can be turned off in Octet's Settings, and the terminal may not be open."

    /// What the agent reads for an answer: a line saying what it is, then the text.
    static func format(_ answer: [String: Any]) -> String {
        let text = answer["text"] as? String ?? ""
        let shown = answer["lines"] as? Int ?? 0
        let total = answer["total_lines"] as? Int ?? shown
        var header = "[sidebar terminal"
        if let title = answer["title"] as? String, !title.isEmpty { header += " · \(title)" }
        if answer["shell_running"] as? Bool == false { header += " · the shell has exited" }
        header += total > shown ? " · last \(shown) of \(total) lines]" : " · \(Recap.count(shown, "line"))]"
        guard !text.isEmpty else { return header + "\n(nothing on screen yet)" }
        return header + "\n" + text
    }

    /// What the agent reads after putting a command at the prompt.
    static func formatSuggestion(_ answer: [String: Any]) -> String {
        let command = answer["command"] as? String ?? ""
        return "Put this at the sidebar terminal's prompt, without running it: \(command)\nThe person has been asked to look at it and press Return (or Run) to run it. Nothing has run yet. If they do, read_sidebar_terminal shows the result."
    }

    /// Answers one JSON-RPC line. `call` asks the app. Outside Octet
    /// (`origin` nil) the server offers no tools.
    static func respond(to line: String, origin: TerminalControl.Origin?,
                        call: (TerminalControl.Method, [String: Any]) throws -> [String: Any]) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": serverName, "version": "1"]]
            if origin != nil { result["instructions"] = instructions }
        case "tools/list":
            result = ["tools": origin == nil ? [] : tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let origin else {
                result = ["content": [["type": "text", "text": TerminalControl.notInOctet]], "isError": true]
                break
            }
            var callParams = origin.params
            do {
                switch name {
                case toolName:
                    callParams["lines"] = TerminalControl.clampLines(arguments["lines"])
                    result = ["content": [["type": "text", "text": format(try call(.read, callParams))]]]
                case suggestToolName:
                    guard let command = TerminalControl.stagedCommand(arguments["command"] as? String ?? "") else {
                        throw TerminalControl.Failure(message: "Give one line of text, up to \(TerminalControl.maxCommandLength) characters, with no control or invisible characters.")
                    }
                    callParams["command"] = command
                    _ = try call(.suggest, callParams)
                    result = ["content": [["type": "text", "text": formatSuggestion(["command": command])]]]
                default:
                    result = ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
                }
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
}
