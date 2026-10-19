import Foundation

struct WorkspaceSetupState: Codable, Equatable {
    enum Phase: String, Codable { case preparing, awaitingApproval, running, ready, failed, skipped }
    var checkout: String
    var phase: Phase
    var detail: String = ""
    var logPath: String? = nil
    var updatedAt = Date()
    var title: String {
        switch phase {
        case .preparing: "Preparing workspace"
        case .awaitingApproval: "Setup awaiting approval"
        case .running: "Running setup"
        case .ready: "Workspace ready"
        case .failed: "Setup failed"
        case .skipped: "Setup skipped"
        }
    }
    var active: Bool { [.preparing, .awaitingApproval, .running].contains(phase) }
}
