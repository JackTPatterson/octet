import Foundation

/// Agent Delegation: an agent in Octet asks another agent on this Mac to
/// check or do something, such as Claude Code having Codex review its
/// changes, and gets the answer back. The delegate runs in a tab of the
/// same workspace where the person can watch it; a review can't change
/// files, and a task works in a worktree of its own.
///
/// The agents' side is a stdio MCP server (`octet-cli delegate-mcp`); it
/// asks the app over a Unix socket only this user can open, one JSON line
/// each way. Nothing here is Other Macs': that is a separate system.
enum DelegationControl {
    static let socketName = "delegation.sock"
    /// How deep in a chain of delegations a process is: a delegate gets 1,
    /// and a delegate may not delegate again.
    static let depthVariable = "OCTET_DELEGATION_DEPTH"
    static let maxDepth = 1

    /// The app's socket for a session, beside Other Macs' but its own.
    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/Library/Application Support/Octet"
        guard let session, !session.isEmpty, session != "octet" else { return base + "/" + socketName }
        return base + "/sessions/\(session)/" + socketName
    }

    static func resolveSocket(environment: [String: String]) -> String {
        socketPath(session: environment["OCTET_SESSION"]
            ?? PeerControl.session(ofServer: environment[EngineProtocol.socketPathVariable]))
    }

    /// The pane a request comes from; nil outside Octet, where there are no tools.
    struct Origin: Equatable {
        let pane: String
        let session: String
        let depth: Int

        static func current(_ environment: [String: String]) -> Origin? {
            guard let pane = environment[EngineProtocol.paneIdVariable], !pane.isEmpty,
                  let session = environment[EngineProtocol.socketPathVariable], !session.isEmpty else { return nil }
            return Origin(pane: pane, session: session, depth: Int(environment[depthVariable] ?? "") ?? 0)
        }

        var params: [String: Any] { ["from_pane": pane, "from_session": session, "depth": depth] }
    }

    enum Method: String { case agents, delegate, wait }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func call(socketPath: String, method: Method, params: [String: Any]) throws -> [String: Any] {
        let connection: EngineSocketConnection
        do {
            connection = try EngineSocketConnection(path: socketPath)
        } catch {
            throw Failure(message: "Octet isn't reachable. Is it open, with the Agent Delegation plugin on?")
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

// MARK: - What a delegate is asked, and how it runs

enum DelegationMode: String {
    /// Check the caller's changes and report; nothing is changed.
    case review
    /// Do something, in a worktree of its own so it can't collide with the caller.
    case task
}

enum DelegationPlan {
    /// Agents that can be handed work, in the order offered.
    static let agents = ["codex", "claude"]

    /// The prompt the delegate gets: who's asking, what for, and for a
    /// review, how to answer so the caller can act on it.
    static func prompt(task: String, mode: DelegationMode, caller: String) -> String {
        switch mode {
        case .review:
            """
            \(caller) asked you, through Octet, to review its work in this repository. You're read-only: \
            don't change any files. Look at the uncommitted changes (staged, unstaged and untracked) and \
            check them against what \(caller) wants checked:

            \(task)

            End with one line that says VERDICT: PASS if the changes do what they should without problems, \
            or VERDICT: FAIL if they don't. Before it, list each problem on its own line starting with "- ", \
            with the file and line where you can. Be specific and brief.
            """
        case .task:
            """
            \(caller) asked you, through Octet, to do this in a copy of the repository (a separate git \
            worktree), so your changes can't collide with its own:

            \(task)

            When you're done, say briefly what you changed and why, so \(caller) can decide what to bring over.
            """
        }
    }

    /// The shell command a delegate's tab runs: the agent reading `promptFile`,
    /// its final answer in `resultFile`, and `doneFile` written when it exits
    /// (with its exit status), so the app knows it's over.
    static func command(agent: String, executable: String, mode: DelegationMode,
                        promptFile: String, resultFile: String, doneFile: String) -> String? {
        let exe = quote(executable), prompt = quote(promptFile), result = quote(resultFile), done = quote(doneFile)
        let depth = "\(DelegationControl.depthVariable)=\(DelegationControl.maxDepth)"
        let run: String
        switch (agent, mode) {
        case ("codex", .review):
            // Codex's own reviewer, over the uncommitted changes; read-only by nature.
            run = "\(depth) \(exe) exec review --uncommitted --skip-git-repo-check -o \(result) - < \(prompt)"
        case ("codex", .task):
            run = "\(depth) \(exe) exec -s workspace-write --skip-git-repo-check -o \(result) - < \(prompt)"
        case ("claude", .review):
            // Plan mode reads but doesn't edit.
            run = "\(depth) \(exe) -p --permission-mode plan < \(prompt) | tee \(result)"
        case ("claude", .task):
            run = "\(depth) \(exe) -p --permission-mode acceptEdits < \(prompt) | tee \(result)"
        default:
            return nil
        }
        return "\(run); echo $? > \(done)"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// A review's answer: whether it passed, and the problems it listed.
struct DelegationVerdict: Equatable {
    enum Outcome: String { case pass, fail, unknown }
    let outcome: Outcome
    let findings: [String]

    static func read(_ text: String) -> DelegationVerdict {
        var outcome = Outcome.unknown
        var findings: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased().replacingOccurrences(of: "*", with: "")
            if upper.hasPrefix("VERDICT:") {
                let value = upper.dropFirst("VERDICT:".count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("PASS") { outcome = .pass } else if value.hasPrefix("FAIL") { outcome = .fail }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                findings.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return DelegationVerdict(outcome: outcome, findings: findings)
    }
}

// MARK: - The agents' tools

enum DelegationMCP {
    static let serverName = "octet-delegate"

    static let tools: [[String: Any]] = [
        tool("list_delegates", "Lists the coding agents on this Mac that can review your work or take a task (e.g. codex, claude).", [:], []),
        tool("delegate_to_agent",
             "Asks another coding agent on this Mac to review your uncommitted changes (mode review: read-only, ends with a PASS or FAIL verdict and a list of problems) or to do a task (mode task: in a separate git worktree so it can't collide with your edits). It runs in a tab the person can watch. By default waits for the answer.",
             ["agent": ["type": "string", "enum": DelegationPlan.agents, "description": "Which agent, e.g. codex."],
              "task": string("For a review, what to check (e.g. \"the retry logic handles timeouts\"); for a task, what to do."),
              "mode": ["type": "string", "enum": ["review", "task"], "description": "review (default) or task."],
              "wait": ["type": "boolean", "description": "Wait for the answer before returning. Default true."],
              "timeout_seconds": ["type": "integer", "description": "How long to wait. Default 900."]],
             ["agent", "task"]),
        tool("wait_for_delegate", "Waits for a delegated review or task to finish and returns its answer, or its status if it isn't done in time.",
             ["task": string("The id delegate_to_agent returned."),
              "timeout_seconds": ["type": "integer", "description": "How long to wait. Default 900."]], ["task"]),
    ]

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    static let instructions = """
        You're running inside Octet, which can have another coding agent on this Mac check your work. \
        When you've made changes worth a second opinion (a tricky fix, a refactor, anything you're unsure \
        of), call delegate_to_agent with mode review and say what to check, e.g. have Codex review them; \
        it can't change files and ends with VERDICT: PASS or FAIL and a list of problems. Fix what it finds \
        or explain why not. Use mode task to hand off separate work; it runs in its own git worktree. \
        The person can watch both in their own tab.
        """

    static func request(tool: String, arguments: [String: Any], origin: DelegationControl.Origin) -> (DelegationControl.Method, [String: Any])? {
        let params = arguments.merging(origin.params) { $1 }
        switch tool {
        case "list_delegates": return (.agents, params)
        case "delegate_to_agent": return (.delegate, params)
        case "wait_for_delegate": return (.wait, params)
        default: return nil
        }
    }

    /// Answers one JSON-RPC line; `call` asks the app. Outside Octet, and in
    /// a delegate (which may not delegate again), it offers no tools.
    static func respond(to line: String, origin: DelegationControl.Origin?,
                        call: (DelegationControl.Method, [String: Any]) throws -> [String: Any]) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]
        let usable = origin.map { $0.depth < DelegationControl.maxDepth } ?? false
        var result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": serverName, "version": "1"]]
            if usable { result["instructions"] = instructions }
        case "tools/list":
            result = ["tools": usable ? tools : []]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let origin else {
                result = error("This only works inside Octet.")
                break
            }
            guard origin.depth < DelegationControl.maxDepth else {
                result = error("You're a delegate yourself, so you can't delegate again. Answer the agent that asked you instead.")
                break
            }
            guard let (method, callParams) = self.request(tool: name, arguments: arguments, origin: origin) else {
                result = error("Unknown tool \(name).")
                break
            }
            do {
                var answer = try call(method, callParams)
                // Waiting is the default: start it, then wait for it.
                if method == .delegate, arguments["wait"] as? Bool != false, let task = answer["task"] as? String {
                    answer = try call(.wait, origin.params.merging(["task": task, "timeout_seconds": arguments["timeout_seconds"] ?? 900]) { $1 })
                }
                result = ["content": [["type": "text", "text": text(answer)]]]
            } catch {
                result = self.error(String(describing: error))
            }
        default:
            guard id != nil else { return nil }
            result = [:]
        }
        guard let id else { return nil }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: response)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func error(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    /// The answer as the calling agent reads it: the result first, then the facts.
    static func text(_ answer: [String: Any]) -> String {
        var lines: [String] = []
        if let result = answer["result"] as? String, !result.isEmpty { lines += [result, ""] }
        var facts = answer
        facts["result"] = nil
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines.joined(separator: "\n")
    }
}
