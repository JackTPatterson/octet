import Foundation

/// Palette › Clean Up Worktrees: the repository's worktrees with what each
/// holds, and removal of the ones that are merged and clean.
@MainActor
enum WorktreeCleanupActions {
    static func item(window: WindowContext) -> PaletteItem? {
        let snapshot = window.store.snapshot
        guard let directory = window.focusedWorkspace.flatMap({ snapshot.directory(ofWorkspace: $0.workspaceId) }) else { return nil }
        let project = URL(fileURLWithPath: AccountProfiles.projectRoot(of: directory) ?? directory).lastPathComponent
        return PaletteItem(
            id: "action.cleanWorktrees", kind: .action, title: "Clean Up Worktrees…",
            subtitle: "Merged, clean worktrees of \(project) and the disk they hold",
            keywords: ["worktree", "prune", "remove", "disk", "space", "merged", "delete", "git"],
            icon: .symbol("xmark.bin"),
            effect: .list(title: "Worktrees of \(project)") { deliver in
                DispatchQueue.global(qos: .userInitiated).async {
                    var worktrees = WorktreeCleanup.list(in: directory).filter { !$0.isMain }
                    for index in worktrees.indices { worktrees[index].bytes = WorktreeCleanup.measure(worktrees[index].path) }
                    DispatchQueue.main.async { deliver(items(worktrees, directory: directory, window: window)) }
                }
            }
        )
    }

    private static func items(_ worktrees: [WorktreeCleanup.Worktree], directory: String, window: WindowContext) -> [PaletteItem] {
        let removable = worktrees.filter(\.removable)
        var items: [PaletteItem] = []
        if removable.count > 1 {
            let bytes = removable.compactMap(\.bytes).reduce(0, +)
            items.append(PaletteItem(
                id: "worktrees.removeMerged", kind: .action, title: "Remove All \(removable.count) Merged Worktrees",
                subtitle: "Frees \(size(bytes)). Branches are kept.", icon: .symbol("xmark.bin"),
                effect: .run { confirm(removable, directory: directory, window: window) }
            ))
        }
        for worktree in worktrees.sorted(by: { ($0.removable ? 0 : 1, -($0.bytes ?? 0)) < ($1.removable ? 0 : 1, -($1.bytes ?? 0)) }) {
            let state = worktree.dirty ? "uncommitted changes" : worktree.merged ? "merged" : "not merged"
            items.append(PaletteItem(
                id: "worktree.\(worktree.path)", kind: .action,
                title: worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent,
                subtitle: [state, worktree.bytes.map(size), (worktree.path as NSString).abbreviatingWithTildeInPath]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: .symbol(worktree.removable ? "xmark.bin" : "arrow.triangle.branch"),
                effect: .run {
                    if worktree.removable {
                        confirm([worktree], directory: directory, window: window)
                    } else {
                        ToastCenter.shared.info("\(worktree.branch ?? "This worktree") isn't removed",
                                                detail: worktree.dirty ? "It has uncommitted changes." : "Its branch isn't merged yet.")
                    }
                }
            ))
        }
        if items.isEmpty {
            items.append(PaletteItem(id: "worktrees.none", kind: .action, title: "No worktrees besides the main checkout",
                                     icon: .symbol("arrow.triangle.branch"), effect: .run {}))
        }
        return items
    }

    private static func confirm(_ worktrees: [WorktreeCleanup.Worktree], directory: String, window: WindowContext) {
        let bytes = worktrees.compactMap(\.bytes).reduce(0, +)
        ConfirmCenter.shared.ask(
            title: worktrees.count == 1 ? "Remove the \(worktrees[0].branch ?? "") worktree?" : "Remove \(worktrees.count) merged worktrees?",
            message: "Their folders are deleted (\(size(bytes))); the branches and commits stay. Workspaces open on them close.",
            items: worktrees.map { ($0.path as NSString).abbreviatingWithTildeInPath },
            confirmTitle: "Remove",
            destructive: true
        ) { _ in remove(worktrees, directory: directory, window: window) }
    }

    private static func remove(_ worktrees: [WorktreeCleanup.Worktree], directory: String, window: WindowContext) {
        let store = window.store
        let snapshot = store.snapshot
        // A worktree with a workspace open is removed through the session
        // server, so the workspace goes with it.
        let open: [String: String] = Dictionary(snapshot.workspaces.compactMap { workspace in
            snapshot.directory(ofWorkspace: workspace.workspaceId).map { ($0, workspace.workspaceId) }
        }, uniquingKeysWith: { first, _ in first })
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for worktree in worktrees {
                do {
                    if let workspace = open.first(where: { AccountProfiles.contains(worktree.path, $0.key) })?.value {
                        _ = try client.call("worktree.remove", ["workspace_id": workspace])
                    } else {
                        try WorktreeCleanup.remove(worktree, in: directory)
                    }
                } catch {
                    failed.append("\(worktree.branch ?? worktree.path): \(error)")
                }
            }
            DispatchQueue.main.async {
                if failed.isEmpty {
                    ToastCenter.shared.succeed(nil, worktrees.count == 1 ? "Removed the worktree" : "Removed \(worktrees.count) worktrees")
                } else {
                    ToastCenter.shared.fail(nil, "Couldn't remove \(failed.count)", detail: failed.joined(separator: "\n"))
                }
                store.scheduleRefresh()
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
