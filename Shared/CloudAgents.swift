import Foundation

/// Agents whose CLI runs a session in the vendor's cloud rather than on this
/// Mac. The session still opens in a tab: the CLI streams it there, so it's
/// watched, answered and notified like any agent in a pane.
enum CloudAgents {
    enum Start: Equatable {
        /// The CLI takes the task on its command line; Octet asks for it.
        case withTask
        /// The CLI opens its own view of cloud tasks, where one is started.
        case browser
    }

    /// How an agent starts a cloud session, or nil when it has none.
    static func start(for agentId: String) -> Start? {
        switch agentId {
        case "claude": .withTask
        case "codex": .browser
        default: nil
        }
    }

    /// What follows the agent's executable to start a cloud session.
    /// `claude --cloud <task>` creates one; `codex cloud` opens Codex's list
    /// of cloud tasks.
    static func arguments(for agentId: String, task: String?) -> [String]? {
        switch start(for: agentId) {
        case .withTask:
            guard let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else { return nil }
            return ["--cloud", task]
        case .browser:
            return ["cloud"]
        case nil:
            return nil
        }
    }

    /// `claude --teleport`: with no session, Claude lists its cloud sessions
    /// to bring one into this folder.
    static let teleportArguments = ["--teleport"]

    /// The tab's name: the task, shortened, marked as running in the cloud.
    static func tabLabel(agentName: String, task: String?) -> String {
        guard let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return "\(agentName) Cloud"
        }
        let line = task.split(separator: "\n").first.map(String.init) ?? task
        let short = line.count > 32 ? String(line.prefix(31)) + "…" : line
        return "☁ " + short
    }
}
