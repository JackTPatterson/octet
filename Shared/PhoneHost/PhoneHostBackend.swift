import Foundation

/// What the phone host needs from Octet, in Octet's own words. The wire layer
/// turns these into T3's schemas; the app supplies the real thing.

/// A folder Octet has a workspace open in.
struct PhoneProject: Equatable {
    var id: String
    var title: String
    var folder: String
    var createdAt: Date
    var updatedAt: Date
}

enum PhoneThreadStatus: String, Equatable {
    case idle, running, waiting, completed, failed
}

/// A permission an agent is waiting on.
struct PhoneApproval: Equatable {
    var id: String
    /// "command", "file-read" or "file-change".
    var kind: String
    var prompt: String
    var createdAt: Date
}

/// An agent session: one conversation in one pane.
struct PhoneThread: Equatable {
    var id: String
    var projectID: String
    var title: String
    /// The agent's id: "claude", "codex", …
    var agent: String
    var model: String?
    var status: PhoneThreadStatus
    var createdAt: Date
    var updatedAt: Date
    var approval: PhoneApproval?
}

/// One thing in a conversation.
enum PhoneItem: Equatable {
    case user(id: String, text: String, at: Date)
    case assistant(id: String, text: String, at: Date)
    case reasoning(id: String, text: String, at: Date)
    /// A tool the agent ran, with what it printed once it finished.
    case tool(id: String, name: String, input: String, output: String?, failed: Bool, at: Date)

    var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _), .reasoning(let id, _, _), .tool(let id, _, _, _, _, _): id
        }
    }

    var at: Date {
        switch self {
        case .user(_, _, let at), .assistant(_, _, let at), .reasoning(_, _, let at), .tool(_, _, _, _, _, let at): at
        }
    }
}

/// A pane the phone can watch and type into.
struct PhoneTerminalView: Equatable {
    var text: String
    var cols: Int
    var rows: Int
    var running: Bool
}

/// A model an agent can run.
struct PhoneModel: Equatable {
    var id: String
    var name: String
    var isDefault = false
}

/// An agent the phone can switch a conversation to, with the models it offers.
struct PhoneProvider: Equatable {
    var id: String
    var name: String
    var models: [PhoneModel]
}

enum PhoneHostError: Error, Equatable {
    case notFound(String)
    case failed(String)

    var message: String {
        switch self {
        case .notFound(let message), .failed(let message): message
        }
    }
}

protocol PhoneHostBackend: AnyObject {
    /// This Mac's name, as the phone shows it.
    var machineName: String { get }
    /// The folder the phone's "home" is: the first project's, or the user's.
    var homeFolder: String { get }

    func projects() -> [PhoneProject]
    func threads() -> [PhoneThread]
    func transcript(of threadID: String) -> [PhoneItem]

    /// The agents installed here and what each can run.
    func providers() -> [PhoneProvider]
    /// Runs `model` of `provider` from the next message on. Within one agent the
    /// conversation stays where it is and the answer is its own id; to another
    /// agent it continues in a new conversation, whose id is the answer.
    func setModel(_ model: String, provider: String, for threadID: String, completion: @escaping (Result<String, PhoneHostError>) -> Void)

    func send(_ text: String, to threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void)
    func interrupt(_ threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void)
    func answer(approval: String, in threadID: String, allow: Bool, completion: @escaping (Result<Void, PhoneHostError>) -> Void)

    /// What the pane shows now; nil when there is no such pane.
    func terminal(of threadID: String) -> PhoneTerminalView?
    func type(_ data: String, into threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void)

    /// Called, on any queue, when projects, threads or a transcript may have changed.
    var onChange: (() -> Void)? { get set }
}
