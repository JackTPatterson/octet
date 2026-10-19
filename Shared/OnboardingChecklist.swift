import Foundation

/// Progress is explicitly marked by the person, not inferred from opening a screen.
enum OnboardingChecklistStep: String, CaseIterable, Identifiable {
    case project, agent, appearance, issues, notifications
    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Open your first project"
        case .agent: "Set up your agents"
        case .appearance: "Choose your appearance"
        case .issues: "Connect your issue tracker"
        case .notifications: "Set up notifications"
        }
    }
    var detail: String {
        switch self {
        case .project: "Choose a folder to work in."
        case .agent: "Check installed agents and sign-in options."
        case .appearance: "Choose a theme and text size."
        case .issues: "Connect GitHub, Linear or Jira."
        case .notifications: "Choose how Octet asks for your attention."
        }
    }
    static func valid(_ stored: [String]) -> Set<String> { Set(stored).intersection(Set(allCases.map(\.rawValue))) }
}
