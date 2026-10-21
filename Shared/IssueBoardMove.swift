import Foundation

enum IssueBoardMove {
    /// Jira transition IDs are actions, not status IDs. Never guess between actions.
    static func resolve(destination: String, current: String, allowed: [TrackerStatus]) throws -> TrackerStatus {
        guard destination != current else { throw IssueTrackerError.unreadable("This issue is already in that status.") }
        let matches = allowed.filter { $0.name == destination }
        guard !matches.isEmpty else { throw IssueTrackerError.unreadable("This issue cannot move to \(destination). Its allowed transitions may have changed.") }
        guard matches.count == 1 else { throw IssueTrackerError.unreadable("Several transitions lead to \(destination). Open the issue and choose a transition from its status menu.") }
        return matches[0]
    }
}
