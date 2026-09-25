import Foundation

/// Where an agent is working when that is somewhere other than where it
/// started: another worktree, another repository, or a folder inside the
/// same one. Subagents `cd` and take worktrees of their own, so a
/// workspace's agents can be spread over several checkouts at once.
struct AgentLocation: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        /// A linked git worktree other than the one the agent started in.
        case worktree
        /// A different repository altogether.
        case repository
        /// A folder inside the repository (or folder) it started in.
        case subfolder
        /// A folder outside any repository.
        case folder
    }

    let kind: Kind
    /// The folder the agent is in.
    let path: String
    /// The checkout or folder it names: agents in one worktree share it.
    let root: String
    /// A short name: the worktree or repository folder, or the subfolder's
    /// path from where the agent started.
    let name: String
    /// The branch checked out there, for worktrees and other repositories.
    let branch: String?

    var icon: String {
        switch kind {
        case .worktree: return "square.stack.3d.up"
        case .repository: return "folder.badge.gearshape"
        case .subfolder, .folder: return "folder"
        }
    }

    /// "worktree agent-a84…", "repo web", "server/" — for a detail line.
    var phrase: String {
        switch kind {
        case .worktree: return "worktree \(name)"
        case .repository: return "repo \(name)"
        case .subfolder, .folder: return name.hasSuffix("/") ? name : name + "/"
        }
    }

    /// A full sentence for a tooltip.
    func help(abbreviate: (String) -> String = { $0 }) -> String {
        let place: String
        switch kind {
        case .worktree: place = "Working in worktree \(name)"
        case .repository: place = "Working in repository \(name)"
        case .subfolder, .folder: place = "Working in \(name)"
        }
        let branch = branch.map { " on \($0)" } ?? ""
        return "\(place)\(branch)\n\(abbreviate(path))"
    }
}

enum AgentLocations {
    typealias GitLocation = (gitDir: String, root: String, isLinkedWorktree: Bool)

    /// Where `cwd` is, seen from `home` (the folder the agent started in);
    /// nil when it is still there.
    static func locate(
        _ cwd: String,
        home: String?,
        gitLocation: (String) -> GitLocation? = GitBranch.location(for:),
        branch: (String) -> String? = GitBranch.current(in:)
    ) -> AgentLocation? {
        let cwd = standardized(cwd)
        let home = home.map(standardized)
        guard cwd != home else { return nil }
        let here = gitLocation(cwd)
        let there = home.flatMap(gitLocation)

        if let here, here.root != there?.root {
            let name = (here.root as NSString).lastPathComponent
            return AgentLocation(kind: here.isLinkedWorktree ? .worktree : .repository,
                                 path: cwd, root: here.root, name: name, branch: branch(here.root))
        }
        // Same checkout, or no checkout at all: name the folder by where it
        // sits relative to the start, or to the repository's root.
        let base = here?.root ?? home
        let name: String
        if let base, cwd == base {
            name = (base as NSString).lastPathComponent
        } else if let base, cwd.hasPrefix(base + "/") {
            name = String(cwd.dropFirst(base.count + 1))
        } else {
            name = (cwd as NSString).lastPathComponent
        }
        return AgentLocation(kind: here == nil ? .folder : .subfolder,
                             path: cwd, root: cwd, name: name, branch: nil)
    }

    /// Agents in the same place, grouped for one chip each: in the order
    /// first seen, with how many agents are there.
    static func grouped(_ locations: [AgentLocation]) -> [(location: AgentLocation, count: Int)] {
        var order: [String] = []
        var groups: [String: (location: AgentLocation, count: Int)] = [:]
        for location in locations {
            if let group = groups[location.root] {
                groups[location.root] = (group.location, group.count + 1)
            } else {
                order.append(location.root)
                groups[location.root] = (location, 1)
            }
        }
        return order.compactMap { groups[$0] }
    }

    private static func standardized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
