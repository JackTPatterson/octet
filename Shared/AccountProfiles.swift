import Foundation

/// A second (or third) sign-in for an agent: a work and a personal Claude
/// account, say. Each lives in its own config folder, which the agent is
/// pointed at through its environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`),
/// so their logins, settings, history and limits never mix. A project uses
/// one by having its folder assigned to it.
struct AccountProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// "claude" or "codex".
    var agent: String
    /// The config folder, as written (`~` allowed).
    var home: String

    static let agents = ["claude", "codex"]

    var variable: String { Self.variable(for: agent) }

    static func variable(for agent: String) -> String { agent == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

    func expandedHome(userHome: String = NSHomeDirectory()) -> String {
        home.hasPrefix("~") ? userHome + home.dropFirst() : home
    }

    /// Where a new account's folder goes: `~/.claude-work`, `~/.codex-personal`.
    static func suggestedHome(agent: String, name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "~/.\(agent)-\(slug.isEmpty ? "account" : slug)"
    }
}

/// A folder (and everything under it) using an account.
struct AccountAssignment: Codable, Equatable {
    var folder: String
    var profileId: String
}

enum AccountProfiles {
    /// For each agent, the account `directory` uses: the one assigned to the
    /// deepest folder containing it, or containing its project `root` (a
    /// worktree's is its main checkout, wherever the worktree lives). Agents
    /// with none use their default.
    static func profiles(for directory: String, root: String? = nil, profiles: [AccountProfile],
                         assignments: [AccountAssignment]) -> [AccountProfile] {
        let byId = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [String: (depth: Int, profile: AccountProfile)] = [:]
        for assignment in assignments
        where contains(assignment.folder, directory) || root.map({ contains(assignment.folder, $0) }) == true {
            guard let profile = byId[assignment.profileId] else { continue }
            let depth = assignment.folder.count
            if (chosen[profile.agent]?.depth ?? -1) < depth { chosen[profile.agent] = (depth, profile) }
        }
        return chosen.values.map(\.profile).sorted { $0.agent < $1.agent }
    }

    /// The variables that point each agent at `directory`'s accounts.
    static func environment(for directory: String, root: String? = nil, profiles: [AccountProfile],
                            assignments: [AccountAssignment], userHome: String = NSHomeDirectory()) -> [String: String] {
        var environment: [String: String] = [:]
        for profile in self.profiles(for: directory, root: root, profiles: profiles, assignments: assignments) {
            environment[profile.variable] = profile.expandedHome(userHome: userHome)
        }
        return environment
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        let folder = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        return path == folder || path.hasPrefix(folder + "/")
    }

    // MARK: - Session server requests

    /// Adds `directory`'s account variables to a request that starts a
    /// shell: `workspace.create`, `tab.create`, `pane.split` and each pane of
    /// `layout.apply`. The session server gives a pane only the environment
    /// its own request carries, so every one of them needs it. `cwdOf`
    /// finds the folder a request without a `cwd` will open in.
    static func inject(_ method: String, _ params: [String: Any],
                       environment: (String) -> [String: String],
                       cwdOf: ([String: Any]) -> String? = { _ in nil }) -> [String: Any] {
        func merged(_ node: [String: Any], cwd: String?) -> [String: Any] {
            guard let cwd else { return node }
            let extra = environment(cwd)
            guard !extra.isEmpty else { return node }
            var node = node
            var env = node["env"] as? [String: String] ?? [:]
            // What the caller set on purpose wins.
            for (key, value) in extra where env[key] == nil { env[key] = value }
            node["env"] = env
            return node
        }
        switch method {
        case "workspace.create", "tab.create", "pane.split":
            return merged(params, cwd: params["cwd"] as? String ?? cwdOf(params))
        case "layout.apply":
            guard let root = params["root"] as? [String: Any] else { return params }
            var params = params
            params["root"] = layoutNode(root) { merged($0, cwd: $0["cwd"] as? String ?? cwdOf(params)) }
            return params
        default:
            return params
        }
    }

    private static func layoutNode(_ node: [String: Any], _ transform: ([String: Any]) -> [String: Any]) -> [String: Any] {
        if node["type"] as? String == "pane" { return transform(node) }
        var node = node
        for key in ["first", "second"] {
            if let child = node[key] as? [String: Any] { node[key] = layoutNode(child, transform) }
        }
        return node
    }

    /// Where each workspace and pane is, for requests that name one instead
    /// of a folder; kept current from the session's snapshots.
    nonisolated(unsafe) private static var places: [String: String] = [:]

    static func noteDirectories(_ snapshot: EngineSnapshot) {
        var places: [String: String] = [:]
        for pane in snapshot.panes { if let cwd = pane.effectiveCwd { places[pane.paneId] = cwd } }
        for workspace in snapshot.workspaces {
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { places[workspace.workspaceId] = cwd }
        }
        lock.withLock { self.places = places }
    }

    /// The folder a request opens in when it has no `cwd` of its own: the
    /// pane it splits, else its workspace's.
    static func folder(of params: [String: Any]) -> String? {
        let keys = ["target_pane_id", "pane_id", "workspace_id"]
        return lock.withLock { keys.lazy.compactMap { (params[$0] as? String).flatMap { places[$0] } }.first }
    }

    /// The accounts in force for `directory`, and the variables that select them.
    static func inForce(for directory: String) -> [AccountProfile] {
        let (profiles, assignments) = configured
        guard !assignments.isEmpty else { return [] }
        return self.profiles(for: directory, root: projectRoot(of: directory), profiles: profiles, assignments: assignments)
    }

    static func environment(for directory: String) -> [String: String] {
        Dictionary(inForce(for: directory).map { ($0.variable, $0.expandedHome()) }, uniquingKeysWith: { first, _ in first })
    }

    /// The request rewrite the app installs in `EngineClient.prepareRequest`.
    static func prepare(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let (profiles, assignments) = configured
        guard !assignments.isEmpty else { return params }
        return inject(method, params,
                      environment: { environment(for: $0, root: projectRoot(of: $0), profiles: profiles, assignments: assignments) },
                      cwdOf: folder(of:))
    }

    // MARK: - Where agents keep their files

    /// The accounts and assignments in force, set by the app whenever they
    /// change, for the code that reads agents' transcripts without being
    /// handed settings.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (profiles: [AccountProfile], assignments: [AccountAssignment]) = ([], [])

    static func configure(profiles: [AccountProfile], assignments: [AccountAssignment]) {
        lock.withLock { current = (profiles, assignments) }
    }

    static var configured: (profiles: [AccountProfile], assignments: [AccountAssignment]) {
        lock.withLock { current }
    }

    /// Claude's config folder for work in `cwd`: `~/.claude`, or the
    /// assigned account's.
    static func claudeHome(forCwd cwd: String?, home: String = NSHomeDirectory()) -> String {
        agentHome("claude", forCwd: cwd, home: home) ?? home + "/.claude"
    }

    /// Codex's, likewise: `~/.codex` or the assigned account's.
    static func codexHome(forCwd cwd: String?, home: String = NSHomeDirectory()) -> String {
        agentHome("codex", forCwd: cwd, home: home) ?? home + "/.codex"
    }

    /// Every Claude config folder in use, the default first, for lookups
    /// that don't know which project a session belongs to.
    static func allClaudeHomes(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.claude"] + configured.profiles.filter { $0.agent == "claude" }.map { $0.expandedHome(userHome: home) }
    }

    static func allCodexHomes(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.codex"] + configured.profiles.filter { $0.agent == "codex" }.map { $0.expandedHome(userHome: home) }
    }

    private static func agentHome(_ agent: String, forCwd cwd: String?, home: String) -> String? {
        guard let cwd else { return nil }
        let (profiles, assignments) = configured
        guard !assignments.isEmpty else { return nil }
        return self.profiles(for: cwd, root: projectRoot(of: cwd), profiles: profiles, assignments: assignments)
            .first { $0.agent == agent }?.expandedHome(userHome: home)
    }

    nonisolated(unsafe) private static var roots: [String: String?] = [:]

    /// The project `directory` belongs to, remembered: a worktree's main
    /// checkout, a repository's root.
    static func projectRoot(of directory: String) -> String? {
        if let cached = lock.withLock({ roots[directory] }) { return cached }
        let root = ProjectRootResolver.projectRoot(forDirectory: directory)
        lock.withLock { roots[directory] = root }
        return root
    }
}
