import Foundation

/// One word for what an agent is doing, wherever it runs: a terminal tab, a
/// conversation in Octet, a background session. Every surface that shows an
/// agent's state (sidebar, peek, tab bar, Notch, the hub, runtime rows)
/// reads it from here, so "needs you" is drawn and said one way.
///
/// After T3 Code's thread status pills, with its priorities for rolling a
/// workspace or project up to its loudest agent.
enum AgentState: String, CaseIterable, Equatable {
    case needsApproval, needsInput, failed, working, waiting, planReady, done, idle, unknown

    /// The colour role a state is drawn in. The app picks the colour, from
    /// the theme, so a state reads the same on every theme.
    enum Tone: Equatable {
        /// Something wants a look: approval, input.
        case warning
        case danger
        /// Set aside for you to read: a plan.
        case info
        /// Moving.
        case accent
        case success
        case muted
    }

    /// The bucket the agents dashboard files it under, after Orca's.
    enum Bucket: Int, CaseIterable, Comparable {
        case needsYou, working, idle, done

        static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .needsYou: "Needs You"
            case .working: "Working"
            case .idle: "Idle"
            case .done: "Done"
            }
        }
    }

    /// A pill's or a heading's word for it; empty for unknown, which says
    /// nothing rather than guess.
    var title: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsInput: "Needs input"
        case .failed: "Failed"
        case .working: "Working"
        case .waiting: "Waiting"
        case .planReady: "Plan ready"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: ""
        }
    }

    /// The same word inside a sentence: "Claude Code needs input".
    var label: String { title.lowercased() }

    var tone: Tone {
        switch self {
        case .needsApproval, .needsInput: .warning
        case .failed: .danger
        case .working: .accent
        case .planReady: .info
        case .done: .success
        case .waiting, .idle, .unknown: .muted
        }
    }

    /// An `OctetIcon` key for it.
    var icon: String {
        switch self {
        case .needsApproval: "lock"
        case .needsInput: "message"
        case .failed: "exclamationmark.triangle.fill"
        case .working: "clock.arrow.circlepath"
        case .waiting: "pause.circle"
        case .planReady: "list.bullet.rectangle"
        case .done: "circle.check"
        case .idle: "moon.zzz"
        case .unknown: "circle.dot"
        }
    }

    /// How loud it is when several agents share a workspace or project:
    /// the loudest one speaks for all (T3 Code's order).
    var priority: Double {
        switch self {
        case .needsApproval: 5
        case .needsInput: 4
        case .failed: 3.5
        case .working: 3
        case .waiting: 2.5
        case .planReady: 2
        case .done: 1
        case .idle: 0.5
        case .unknown: 0
        }
    }

    /// Waiting on the person: what raises a notice and counts on the Dock.
    var needsYou: Bool { self == .needsApproval || self == .needsInput }

    var bucket: Bucket {
        switch self {
        case .needsApproval, .needsInput, .failed, .planReady: .needsYou
        case .working, .waiting: .working
        case .done: .done
        case .idle, .unknown: .idle
        }
    }

    /// What the session server reports for a terminal agent. It only knows
    /// "blocked", not whether that's a permission prompt or a question, so
    /// it reads as input.
    init(_ status: EngineAgentStatus) {
        switch status {
        case .working: self = .working
        case .blocked: self = .needsInput
        case .done: self = .done
        case .idle: self = .idle
        case .unknown: self = .unknown
        }
    }

    /// Back to the session server's five, for views still drawn from those.
    var engineStatus: EngineAgentStatus {
        switch self {
        case .needsApproval, .needsInput, .planReady: .blocked
        case .working, .waiting: .working
        case .done: .done
        case .failed, .idle: .idle
        case .unknown: .unknown
        }
    }

    /// A conversation Octet runs itself. A permission prompt outranks a
    /// question, a question outranks the turn still running; a finished turn
    /// is Done until it's been seen, then Idle, as the session server does
    /// for terminal agents.
    static func conversation(pendingPermission: Bool, pendingQuestion: Bool, isRunning: Bool,
                             failed: Bool = false, planReady: Bool = false, unseenFinish: Bool = false) -> AgentState {
        if pendingPermission { return .needsApproval }
        if pendingQuestion { return .needsInput }
        if isRunning { return .working }
        if failed { return .failed }
        if planReady { return .planReady }
        return unseenFinish ? .done : .idle
    }

    /// The loudest of several, for a workspace or project; unknown for none.
    static func rollUp<S: Sequence>(_ states: S) -> AgentState where S.Element == AgentState {
        states.max { $0.priority < $1.priority } ?? .unknown
    }
}

/// How full a model's context window is, in three steps every meter shares
/// (the sidebar's ring, the composer's, the hub's bar): quiet until it
/// matters, a warning near the end, danger at it.
enum ContextLevel: Equatable {
    case normal, warning, danger

    static let warningAt = 0.8
    static let dangerAt = 0.95

    init(fraction: Double?) {
        let fraction = fraction ?? 0
        self = fraction >= Self.dangerAt ? .danger : fraction >= Self.warningAt ? .warning : .normal
    }
}
