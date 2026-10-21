import Foundation

/// The Todos tab's one count, "3 of 7 tasks": the steps of the agents'
/// plans still under way, plus your list and the project's. A plan whose
/// turn has finished is left out, so a stale plan never counts toward the
/// work in front.
struct TodoSummary: Equatable {
    let done: Int
    let total: Int
    /// Each task's status in order, for the segmented bar.
    let statuses: [AgentTodo.Status]

    init(runningPlans: [[AgentTodo]], lists: [[AgentTodo.Status]]) {
        statuses = runningPlans.flatMap { $0.map(\.status) } + lists.flatMap { $0 }
        total = statuses.count
        done = statuses.filter { $0 == .completed }.count
    }

    var isComplete: Bool { total > 0 && done == total }
    /// The bar is cut into one segment a task when there are few enough to
    /// tell apart, after T3 Code's task badge.
    var segmented: Bool { (2...10).contains(total) }
    var text: String { total == 0 ? "" : "\(done) of \(total) \(total == 1 ? "task" : "tasks")" }
    /// The tab chip's short form.
    var badge: String { "\(done)/\(total)" }
    var spoken: String { total == 0 ? "No tasks" : "\(done) of \(total) \(total == 1 ? "task" : "tasks") complete" }
}
