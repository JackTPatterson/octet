import Foundation

/// Letting an agent set a wait for its own work: when it reaches something
/// that can't happen for days or weeks (a pull request to be merged, a
/// release, an approval), it writes down what it waits for and the next
/// step, and Octet takes it from there. Open to every agent: a stdio MCP
/// server (`octet-cli wait-mcp`) for those that take one, and `octet-cli
/// wait add` for any that can run a command. Both ask the app over a Unix
/// socket only this user can open.
enum WaitControl {
    static let socketName = "waits.sock"
    static let socketVariable = "OCTET_WAITS_SOCKET"
    /// Set in the processes of Octet's own conversations, so a wait comes
    /// back to the conversation that set it.
    static let conversationVariable = "OCTET_CONVERSATION_ID"

    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Application Support/Octet"
        guard let session, !session.isEmpty, session != "octet" else { return base + "/" + socketName }
        return base + "/sessions/\(session)/" + socketName
    }

    static func environment(session: String, home: String = NSHomeDirectory()) -> [String: String] {
        [socketVariable: socketPath(session: session, home: home)]
    }

    static func resolveSocket(environment: [String: String]) -> String {
        if let path = environment[socketVariable], !path.isEmpty { return path }
        return socketPath(session: environment["OCTET_SESSION"] ?? PeerControl.session(ofServer: environment[EngineProtocol.socketPathVariable]))
    }

    /// Where a request comes from: a pane or a conversation Octet started,
    /// and the folder it runs in. Nil outside Octet.
    struct Origin: Equatable {
        var pane: String?
        var workspace: String?
        var conversation: String?
        var cwd: String

        static func current(_ environment: [String: String], cwd: String) -> Origin? {
            func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
            let pane = value(EngineProtocol.paneIdVariable)
            let inPane = pane != nil && value(EngineProtocol.socketPathVariable) != nil
            guard inPane || value(socketVariable) != nil || value(conversationVariable) != nil else { return nil }
            return Origin(pane: pane, workspace: value(EngineProtocol.workspaceIdVariable),
                          conversation: value(conversationVariable), cwd: cwd)
        }

        var params: [String: Any] {
            var params: [String: Any] = ["cwd": cwd]
            if let pane { params["from_pane"] = pane }
            if let workspace { params["from_workspace"] = workspace }
            if let conversation { params["conversation_id"] = conversation }
            return params
        }
    }

    static let notInOctet = "This only works inside Octet: run it from an Octet terminal pane or conversation."

    enum Method: String { case add, list, cancel, checkin }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func call(socketPath: String, method: Method, params: [String: Any]) throws -> [String: Any] {
        let connection: EngineSocketConnection
        do {
            connection = try EngineSocketConnection(path: socketPath)
        } catch {
            throw Failure(message: "Octet isn't reachable, or letting agents set waits is off (Octet Settings › Agents).")
        }
        try connection.send(["method": method.rawValue, "params": params])
        let line = try connection.readLine()
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw Failure(message: "Octet sent back something unreadable.")
        }
        if let error = answer["error"] as? String { throw Failure(message: error) }
        return answer["result"] as? [String: Any] ?? [:]
    }

    /// One wait as the app describes it to an agent.
    static func describe(_ wait: Wait, now: Date = Date()) -> [String: Any] {
        var item: [String: Any] = ["id": wait.id, "waiting_for": wait.title, "condition": wait.condition.description,
                                   "next": wait.next, "state": wait.state.rawValue, "status": wait.statusLine(now: now),
                                   "since": ISO8601DateFormatter().string(from: wait.createdAt), "folder": wait.origin.cwd]
        if let link = wait.condition.link { item["link"] = link.absoluteString }
        if let checkIn = wait.checkIn {
            item["kind"] = "check_in"
            item["next_check_in"] = ISO8601DateFormatter().string(from: wait.nextCheckAt)
            item["mode"] = checkIn.mode.rawValue
            item["repeats"] = checkIn.recurrence?.summary ?? "once"
            item["prompt"] = wait.next
            item["times_so_far"] = checkIn.fired
            if let last = checkIn.log.last { item["last"] = last.line(now: now) }
        }
        return item
    }
}

/// The agents' side: a stdio MCP server with four tools.
enum WaitMCP {
    static let serverName = "octet-waits"
    static let waitTool = "wait_for"
    static let listTool = "list_waits"
    static let cancelTool = "cancel_wait"

    static let untilHelp = """
    What to wait for. Octet checks these itself: a pull request ("https://github.com/owner/repo/pull/12", or "owner/repo#12 approved" / "checks pass" / "checks done" / "closed"; merged by default), a release ("release:owner/repo" for the next one, "release:owner/repo v2.0" for a tag), a package ("npm:name@1.2.0", "pypi:name==1.2", or without a version for the next one), a page ("url:https://… up", "url:https://… changes", "url:https://… contains:<text>"), "file:<path>" exists, "command:<shell command>" succeeds, or a date ("date:2026-11-03", "in 3 days", "tomorrow"). Anything else is written down as it is and Octet asks the person every few days whether it has happened.
    """

    static let checkBackTool = "check_back"

    static let tools: [[String: Any]] = [
        [
            "name": waitTool,
            "description": "Sets a wait: use it when the work can't go on until something outside this conversation happens, which may take days or weeks (a pull request to be merged or approved, a release or package to be published, a deploy, a date, an answer from someone). Octet writes down what it waits for and the next step, checks the condition itself with nothing running, and when it's met brings this work back and sends the next step to this conversation (or a new one with a summary if this one is gone). After setting it, tell the person what you're waiting for and stop; don't poll. For work that simply takes days or weeks (a long test or experiment) with no event to watch, use check_back instead.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "until": ["type": "string", "description": untilHelp],
                    "then": ["type": "string", "description": "The next step, written as the message you'd want to receive when it's done: what to do and anything you'll need to know. Required."],
                    "title": ["type": "string", "description": "A few words for the list, e.g. \"API migration PR merged\". Optional."],
                ] as [String: Any],
                "required": ["until", "then"],
            ] as [String: Any],
        ],
        [
            "name": listTool,
            "description": "Lists the waits and check-ins set for work in Octet: what each waits for or when it comes back, the next step and where it stands.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()] as [String: Any],
        ],
        [
            "name": cancelTool,
            "description": "Removes a wait or check-in that's no longer needed.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The wait's id, from list_waits."]],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": checkBackTool,
            "description": "Schedules a check-in on work that takes days or weeks to give a result (a paper-trading run, a backtest over a long period, a soak test, an experiment that has to accumulate data). Use this instead of polling, sleeping or asking the person to remind you. Octet remembers it even if this session ends, Octet is quit or the Mac sleeps or restarts; at the time it notifies the person and, in wake mode, resumes this session (or starts a new conversation from a summary if it can't) and sends you the prompt. It can repeat (every day, week, N hours) until a date or a number of times. After setting it, tell the person what you scheduled and stop; don't wait around.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "What is sent to you at each check-in, written as the message you'd want to read: what to look at, what to compare it with, what to report. Required."],
                    "in": ["type": "string", "description": "How long until the first check-in: \"3 days\", \"12 hours\", \"2 weeks\"."],
                    "at": ["type": "string", "description": "A date or time for the first check-in instead: \"2026-11-03\" (9:00 that morning), \"2026-11-03 14:30\", \"tomorrow\"."],
                    "every": ["type": "string", "description": "Repeat: \"6 hours\", \"2 days\", \"week\", \"month\", \"daily 09:00\", \"weekly monday 09:00\". Leave out for a single check-in."],
                    "until": ["type": "string", "description": "Stop repeating after this date (inclusive), e.g. \"2026-12-01\"."],
                    "count": ["type": "integer", "description": "Stop after this many check-ins (the first counts)."],
                    "mode": ["type": "string", "enum": ["wake", "remind", "both"], "description": "wake: resume this session and send the prompt. remind: only notify the person. both (default): wake and leave a reminder."],
                    "title": ["type": "string", "description": "A few words for the list, e.g. \"Paper-trading run\". Optional."],
                ] as [String: Any],
                "required": ["prompt"],
            ] as [String: Any],
        ],
    ]

    static let instructions = "You're running inside Octet. When the work reaches a point where it can't continue until something outside it happens, possibly days or weeks away (a pull request merged or approved, a release, a deploy, a date, someone's answer), call wait_for with what to wait for and the next step instead of leaving it to be remembered. Octet checks the condition and brings the work back with that next step when it's met. When the work is a long run that takes days or weeks to give a result (a paper-trading run, a long backtest, an experiment), call check_back to be woken in N days (and again every so often) instead of polling or sleeping."

    /// What an agent reads after setting one.
    static func formatAdded(_ answer: [String: Any]) -> String {
        let condition = answer["condition"] as? String ?? ""
        let checked = answer["checked_by_octet"] as? Bool ?? false
        var text = "Wait set: \(condition)."
        text += checked
            ? " Octet checks this itself and will bring this work back with the next step when it's met."
            : " Octet can't check this itself, so it will ask the person every few days whether it has happened."
        text += " Tell the person what you're waiting for, then stop."
        return text
    }

    static func formatCheckIn(_ answer: [String: Any]) -> String {
        let repeats = answer["repeats"] as? String ?? "once"
        let when = (answer["status"] as? String) ?? ""
        var text = "Check-in set (\(repeats == "once" ? "once" : repeats.lowercased())): \(when)."
        text += " Octet remembers it even if this session ends, Octet is quit or the Mac restarts, and at the time"
        let mode = answer["mode"] as? String ?? "both"
        text += mode == "remind" ? " only reminds the person." : " resumes the session and sends you the prompt."
        text += " Tell the person what you scheduled, then stop; don't poll or sleep."
        return text
    }

    static func formatList(_ answer: [String: Any]) -> String {
        let waits = answer["waits"] as? [[String: Any]] ?? []
        guard !waits.isEmpty else { return "No waits are set." }
        return waits.map { wait in
            if wait["kind"] as? String == "check_in" {
                var line = "- [\(wait["id"] as? String ?? "")] check-in: \(wait["waiting_for"] as? String ?? "") (\(wait["status"] as? String ?? ""); \(wait["repeats"] as? String ?? "once"); \(wait["mode"] as? String ?? ""))"
                if let prompt = wait["prompt"] as? String, !prompt.isEmpty { line += "\n  prompt: \(prompt)" }
                if let last = wait["last"] as? String { line += "\n  last: \(last)" }
                return line
            }
            var line = "- [\(wait["id"] as? String ?? "")] \(wait["waiting_for"] as? String ?? "")"
            line += " (\(wait["state"] as? String ?? ""): \(wait["status"] as? String ?? ""))"
            if let next = wait["next"] as? String, !next.isEmpty { line += "\n  then: \(next)" }
            line += "\n  in \(wait["folder"] as? String ?? "")"
            return line
        }.joined(separator: "\n")
    }

    static func respond(to line: String, origin: WaitControl.Origin?,
                        call: (WaitControl.Method, [String: Any]) throws -> [String: Any]) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        func text(_ value: String, error: Bool = false) -> [String: Any] {
            var content: [String: Any] = ["content": [["type": "text", "text": value]]]
            if error { content["isError"] = true }
            return content
        }
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
                result = text(WaitControl.notInOctet, error: true)
                break
            }
            var callParams = origin.params
            do {
                switch name {
                case waitTool:
                    let until = (arguments["until"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let then = (arguments["then"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !until.isEmpty, !then.isEmpty else {
                        throw WaitControl.Failure(message: "Give both what to wait for (until) and the next step (then).")
                    }
                    callParams["until"] = until
                    callParams["then"] = then
                    if let title = arguments["title"] as? String { callParams["title"] = title }
                    result = text(formatAdded(try call(.add, callParams)))
                case checkBackTool:
                    for key in ["prompt", "in", "at", "every", "until", "mode", "title"] {
                        if let value = arguments[key] as? String { callParams[key] = value }
                    }
                    if let count = arguments["count"] { callParams["count"] = count }
                    // Read here too, so a mistake comes back to the agent at once.
                    _ = try CheckInRequest.parse(callParams)
                    result = text(formatCheckIn(try call(.checkin, callParams)))
                case listTool:
                    result = text(formatList(try call(.list, callParams)))
                case cancelTool:
                    guard let waitId = arguments["id"] as? String, !waitId.isEmpty else {
                        throw WaitControl.Failure(message: "Give the wait's id, from list_waits.")
                    }
                    callParams["id"] = waitId
                    _ = try call(.cancel, callParams)
                    result = text("Removed.")
                default:
                    result = text("Unknown tool \(name).", error: true)
                }
            } catch {
                result = text(String(describing: error), error: true)
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
