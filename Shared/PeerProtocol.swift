import Foundation

/// What two paired Octets say to each other once the channel is sealed:
/// requests with an id, a response to each, and events. JSON, one message
/// per frame.
enum PeerProtocol {
    /// The Bonjour service Octets advertise on the local network.
    static let bonjourType = "_octet-peer._tcp"

    enum Method: String, CaseIterable {
        /// This Mac's agents.
        case agents = "agents.list"
        /// A message to one agent, delivered as its next prompt.
        case send = "agent.send"
        /// What's on one agent's screen.
        case read = "agent.read"
        /// Start an agent on a task in a folder; the result comes back as a
        /// `task.finished` event.
        case delegate = "task.delegate"
        case taskStatus = "task.status"
        case ping
    }

    enum Event: String {
        case taskFinished = "task.finished"
        /// A delegated task is waiting on someone at that Mac.
        case taskBlocked = "task.blocked"
    }

    /// Why a request was refused.
    enum ErrorCode: String {
        case declined, notFound = "not_found", notAllowed = "not_allowed", badRequest = "bad_request", unavailable
    }

    struct RemoteError: Error, Equatable, CustomStringConvertible {
        let code: String
        let message: String
        var description: String { message }
    }

    /// An agent on a Mac, as another Mac sees it.
    struct Agent: Equatable {
        let id: String
        let agent: String
        let name: String
        let project: String
        let folder: String
        let status: String

        var dictionary: [String: Any] {
            ["id": id, "agent": agent, "name": name, "project": project, "folder": folder, "status": status]
        }

        init(id: String, agent: String, name: String, project: String, folder: String, status: String) {
            self.id = id
            self.agent = agent
            self.name = name
            self.project = project
            self.folder = folder
            self.status = status
        }

        init?(_ object: [String: Any]) {
            guard let id = object["id"] as? String else { return nil }
            self.init(id: id, agent: object["agent"] as? String ?? "", name: object["name"] as? String ?? "",
                      project: object["project"] as? String ?? "", folder: object["folder"] as? String ?? "",
                      status: object["status"] as? String ?? "unknown")
        }
    }

    /// Who a message or task came from: a Mac, and the agent there if one sent it.
    struct Sender: Equatable {
        let machine: String
        let agent: String?
        let agentName: String?

        var dictionary: [String: Any] {
            var object: [String: Any] = ["machine": machine]
            if let agent { object["agent"] = agent }
            if let agentName { object["agent_name"] = agentName }
            return object
        }

        init(machine: String, agent: String?, agentName: String?) {
            self.machine = machine
            self.agent = agent
            self.agentName = agentName
        }

        init(_ object: [String: Any]?, machine: String) {
            // The machine is the one the channel proved, never what it claims.
            self.init(machine: machine, agent: object?["agent"] as? String, agentName: object?["agent_name"] as? String)
        }
    }

    // MARK: - Messages

    static func request(id: String, method: Method, params: [String: Any]) -> [String: Any] {
        ["type": "request", "id": id, "method": method.rawValue, "params": params]
    }

    static func response(id: String, result: [String: Any]) -> [String: Any] {
        ["type": "response", "id": id, "result": result]
    }

    static func response(id: String, error code: ErrorCode, _ message: String) -> [String: Any] {
        ["type": "response", "id": id, "error": ["code": code.rawValue, "message": message]]
    }

    static func event(_ event: Event, data: [String: Any]) -> [String: Any] {
        ["type": "event", "event": event.rawValue, "data": data]
    }

    static func encode(_ message: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Delivery

    /// How a delivery was allowed here, said plainly to the agent.
    enum Allowed {
        /// The person at this Mac said yes to this one.
        case approved
        /// This Mac's settings let that Mac send without asking.
        case trusted
    }

    /// The prompt an agent gets for a message from another Mac: who sent
    /// it and how it got here, the message, then how to answer.
    static func prompt(_ text: String, from sender: Sender, allowed: Allowed = .approved, here: String? = nil) -> String {
        let who = sender.agentName.map { "\($0) on \(sender.machine)" } ?? sender.machine
        var prompt = "[Message from \(who), delivered by Octet]\n\n\(text)"
        var notes: [String] = []
        switch allowed {
        case .approved: notes.append("The person at \(here ?? "this Mac") approved delivering this message.")
        case .trusted: notes.append("The person at \(here ?? "this Mac") lets \(sender.machine) send messages without asking.")
        }
        if let agent = sender.agent, sender.agentName != nil {
            notes.append("To answer, use the octet-peers send_to_agent tool with machine \"\(sender.machine)\" and agent \"\(agent)\".")
        }
        return prompt + "\n\n(" + notes.joined(separator: " ") + ")"
    }

    /// The pane a `layout.apply` answer made: `layout.root.pane_id`, or the
    /// layout's focused pane.
    static func paneId(inLayoutResult result: [String: Any]?) -> String? {
        guard let result else { return nil }
        if let layout = result["layout"] as? [String: Any] {
            if let pane = (layout["root"] as? [String: Any])?["pane_id"] as? String { return pane }
            if let pane = layout["focused_pane_id"] as? String { return pane }
        }
        return (result["root_pane"] as? [String: Any])?["pane_id"] as? String
    }

    /// The task an agent starts on for another Mac.
    static func taskPrompt(_ task: String, from sender: Sender) -> String {
        let who = sender.agentName.map { "\($0) on \(sender.machine)" } ?? sender.machine
        return "[Task from \(who), delivered by Octet. When you finish, end with a short summary of what you did; Octet sends the end of your screen back.]\n\n\(task)"
    }

    /// The tail of a screen, for a result: blank runs squeezed to one line,
    /// blank ends dropped, at most `lines` lines.
    static func tail(_ text: String, lines: Int) -> String {
        var rows: [String] = []
        for row in text.components(separatedBy: "\n") {
            var row = row
            while row.last == " " { row.removeLast() }
            if row.isEmpty, rows.last?.isEmpty ?? true { continue }
            rows.append(row)
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }
}

/// How much a paired Mac may do here without asking.
enum PeerTrust: String, Codable, CaseIterable {
    /// Every message and task is shown first, to deliver or decline.
    case ask
    /// Messages go straight to the agent; tasks still ask.
    case messages
    /// Messages and tasks both go ahead.
    case messagesAndTasks = "messages_and_tasks"

    var title: String {
        switch self {
        case .ask: "Ask each time"
        case .messages: "Allow messages"
        case .messagesAndTasks: "Allow messages and tasks"
        }
    }

    /// Whether `method` from a Mac trusted this much needs someone here to say yes.
    func needsApproval(_ method: PeerProtocol.Method) -> Bool {
        switch method {
        case .agents, .read, .taskStatus, .ping: false
        case .send: self == .ask
        case .delegate: self != .messagesAndTasks
        }
    }
}
