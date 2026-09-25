import Foundation

/// Adding an agent account, signing in to it, and choosing which one a
/// project uses. Accounts live in settings; `AccountProfiles` applies them.
@MainActor
enum AccountActions {
    private static var settings: SettingsStore { .shared }

    /// A new account with its own config folder, then a tab to sign in.
    static func add(agent: String, name: String, window: WindowContext) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, AccountProfile.agents.contains(agent) else { return }
        let brand = AgentBrand.forAgent(agent)?.displayName ?? agent
        if settings.values.accountProfiles.contains(where: { $0.agent == agent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            ToastCenter.shared.fail(nil, "There's already a \(brand) account called \(name)")
            return
        }
        var home = AccountProfile.suggestedHome(agent: agent, name: name)
        // Never share a folder with an existing account.
        var suffix = 2
        while settings.values.accountProfiles.contains(where: { $0.home == home }) {
            home = AccountProfile.suggestedHome(agent: agent, name: "\(name) \(suffix)")
            suffix += 1
        }
        let profile = AccountProfile(id: UUID().uuidString, name: name, agent: agent, home: home)
        try? FileManager.default.createDirectory(atPath: profile.expandedHome(), withIntermediateDirectories: true)
        settings.values.accountProfiles.append(profile)
        signIn(profile, window: window)
    }

    /// A tab running the agent against the account's folder, where its own
    /// sign-in flow runs.
    static func signIn(_ profile: AccountProfile, window: WindowContext) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let login = profile.agent == "codex" ? "codex login" : "claude"
        let cwd = window.focusedWorkspace.flatMap { window.store.snapshot.directory(ofWorkspace: $0.workspaceId) }
            ?? NSHomeDirectory()
        let title = "Sign in · \(profile.name)"
        let params: [String: Any] = [
            "tab_label": title,
            "root": ["type": "pane", "label": title, "cwd": cwd,
                     // Set here on purpose, so it wins over the folder's own account.
                     "env": [profile.variable: profile.expandedHome()],
                     "command": [shell, "-lic", "\(login); exec \(shell) -l"]] as [String: Any],
        ]
        window.applyLayout(params, failure: "Couldn't open a tab to sign in")
    }

    /// The folder the account choice applies to: the project in front (a
    /// worktree's main checkout), else the workspace's folder.
    static func projectFolder(window: WindowContext) -> String? {
        guard let workspace = window.focusedWorkspace,
              let directory = window.store.snapshot.directory(ofWorkspace: workspace.workspaceId) else { return nil }
        return AccountProfiles.projectRoot(of: directory) ?? directory
    }

    /// Makes `folder` use `profile` for its agent, or the default when nil.
    static func use(_ profile: AccountProfile?, agent: String, for folder: String) {
        let ids = Set(settings.values.accountProfiles.filter { $0.agent == agent }.map(\.id))
        var assignments = settings.values.accountAssignments.filter { !($0.folder == folder && ids.contains($0.profileId)) }
        if let profile { assignments.append(AccountAssignment(folder: folder, profileId: profile.id)) }
        settings.values.accountAssignments = assignments
        let brand = AgentBrand.forAgent(agent)?.displayName ?? agent
        let project = URL(fileURLWithPath: folder).lastPathComponent
        ToastCenter.shared.succeed(nil, "\(project) uses \(profile.map { "\(brand) · \($0.name)" } ?? "the default \(brand) account")",
                                   detail: "New tabs and conversations sign in with it. Agents already running keep the account they started with.")
    }

    /// Forgets an account and where it was used. Its folder, and the sign-in
    /// in it, stay on disk.
    static func remove(_ profile: AccountProfile) {
        settings.values.accountAssignments.removeAll { $0.profileId == profile.id }
        settings.values.accountProfiles.removeAll { $0.id == profile.id }
    }
}
