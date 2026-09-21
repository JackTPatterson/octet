import Foundation

/// A sidebar section: one project (git repository or project folder) and the
/// workspaces that belong to it.
struct ProjectGroup: Equatable, Identifiable {
    /// Project root path, or `ProjectGroup.otherId` for unaffiliated workspaces.
    let id: String
    let name: String
    let workspaces: [EngineWorkspace]

    static let otherId = "herd.other"
}

enum ProjectGrouping {
    static let defaultParentDirectories = ["~/Developer", "~/Projects", "~/code", "~/src"]

    /// Groups workspaces by project, keeping the session server's workspace order: a group
    /// appears where its first workspace appears.
    static func groups(
        snapshot: EngineSnapshot,
        resolveRoot: (String) -> String?
    ) -> [ProjectGroup] {
        var order: [String] = []
        var members: [String: [EngineWorkspace]] = [:]
        for workspace in snapshot.workspaces.sorted(by: { $0.number < $1.number }) {
            let root = workspace.worktree?.repoRoot
                ?? snapshot.directory(ofWorkspace: workspace.workspaceId).flatMap(resolveRoot)
                ?? ProjectGroup.otherId
            if members[root] == nil { order.append(root) }
            members[root, default: []].append(workspace)
        }
        return order.map { root in
            ProjectGroup(
                id: root,
                name: root == ProjectGroup.otherId ? "Other" : URL(fileURLWithPath: root).lastPathComponent,
                workspaces: members[root] ?? []
            )
        }
    }

    /// Filesystem-backed resolver with a per-directory cache.
    final class CachedResolver {
        private var cache: [String: String?] = [:]
        private let parents: [String]

        init(parents: [String] = ProjectGrouping.defaultParentDirectories) {
            self.parents = parents
        }

        func root(for directory: String) -> String? {
            if let cached = cache[directory] { return cached }
            let root = ProjectRootResolver.projectRoot(forDirectory: directory, projectParentDirectories: parents)
            cache[directory] = root
            return root
        }
    }
}
