import Foundation

/// Which agent notices the person wants (Settings › Notifications): one
/// that finished, one waiting on them, one whose turn failed. A failure
/// arrives as a finish whose state is `.failed`, so it's told apart here
/// rather than at every place that raises a notice.
struct AgentNoticeFilter: Equatable {
    var finished = true
    var needsInput = true
    var failed = true

    enum Category: Equatable { case finished, needsInput, failed }

    static func category(of event: AgentEvent) -> Category {
        switch event.kind {
        case .needsInput: return .needsInput
        case .finished: return event.state == .failed ? .failed : .finished
        }
    }

    func allows(_ event: AgentEvent) -> Bool {
        switch Self.category(of: event) {
        case .finished: return finished
        case .needsInput: return needsInput
        case .failed: return failed
        }
    }
}
