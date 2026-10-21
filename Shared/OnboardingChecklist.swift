import Foundation

/// The getting-started steps. Each one notices itself where Octet can tell
/// it's done (an agent on the PATH, a project open, notifications allowed),
/// and can still be checked off by hand, since opening a screen proves
/// nothing and not every setup can be seen.
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

/// What Octet can see of the person's setup, for the steps that check
/// themselves.
struct OnboardingSignals: Equatable {
    /// A workspace in a project folder, not just the home folder.
    var openedProject = false
    /// An agent CLI on this Mac Octet can run.
    var agentInstalled = false
    /// A theme, font or size other than the one Octet started with.
    var appearanceChanged = false
    /// A Linear or Jira connection saved, or GitHub CLI signed in.
    var trackerConnected = false
    /// macOS lets Octet post notifications.
    var notificationsAllowed = false
    /// How Octet notifies was changed in its own Settings: a choice made,
    /// even one that doesn't need macOS's permission.
    var notificationsChosen = false

    /// Whether `directory` is somewhere a project lives: not home, not the
    /// root, not a system folder a fresh terminal starts in.
    static func isProject(_ directory: String, home: String) -> Bool {
        let path = (directory as NSString).standardizingPath
        let homePath = (home as NSString).standardizingPath
        guard !path.isEmpty, path != "/", path != homePath, path.hasPrefix("/") else { return false }
        return !["/tmp", "/private/tmp", "/Users", "/Applications"].contains(path)
    }

    /// Where GitHub CLI keeps its signed-in hosts, as gh itself looks:
    /// `GH_CONFIG_DIR`, then `XDG_CONFIG_HOME/gh`, then `~/.config/gh`.
    static func githubHostsPath(home: String, environment: [String: String]) -> String {
        if let dir = environment["GH_CONFIG_DIR"], !dir.isEmpty { return dir + "/hosts.yml" }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/gh/hosts.yml" }
        return home + "/.config/gh/hosts.yml"
    }

    /// Whether a gh `hosts.yml` lists a host, which it does once signed in
    /// (the token itself may be in the Keychain). Hosts are its top-level keys.
    static func githubSignedIn(hostsYAML: String) -> Bool {
        hostsYAML.components(separatedBy: .newlines).contains { line in
            guard let first = line.first, !first.isWhitespace, first != "#" else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(":") && trimmed.count > 1
        }
    }
}

extension OnboardingChecklistStep {
    /// The steps the signals show are done.
    static func detected(_ signals: OnboardingSignals) -> Set<String> {
        var done = Set<String>()
        if signals.openedProject { done.insert(Self.project.rawValue) }
        if signals.agentInstalled { done.insert(Self.agent.rawValue) }
        if signals.appearanceChanged { done.insert(Self.appearance.rawValue) }
        if signals.trackerConnected { done.insert(Self.issues.rawValue) }
        if signals.notificationsAllowed || signals.notificationsChosen { done.insert(Self.notifications.rawValue) }
        return done
    }
}

/// The two lines of a Ghostty config the first-run flow can carry over
/// besides colours: `font-family` and `font-size`. The last of each wins,
/// as in Ghostty; an empty `font-family =` resets it.
enum GhosttyFontConfig {
    static func parse(_ text: String) -> (family: String?, size: Double?) {
        var family: String?
        var size: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "font-family": family = value.isEmpty ? nil : value
            case "font-size": size = Double(value).flatMap { $0 > 0 ? $0 : nil } ?? size
            default: continue
            }
        }
        return (family, size)
    }
}
