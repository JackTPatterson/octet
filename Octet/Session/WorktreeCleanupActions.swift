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
        let worktrees = protected(worktrees, window: window)
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
            let state = !worktree.blockers.isEmpty ? worktree.blockers.joined(separator: ", ") : worktree.dirty ? "uncommitted changes" : worktree.merged ? "merged" : "not merged"
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
                                                detail: !worktree.blockers.isEmpty ? worktree.blockers.joined(separator: "\n") : worktree.dirty ? "It has uncommitted changes." : "Its branch isn't merged yet.")
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

    /// Open panes are protected even when process liveness is unknown. Close the
    /// workspace first; git cleanliness alone cannot certify that its work is disposable.
    private static func contains(_ root: String, _ path: String) -> Bool {
        AccountProfiles.contains(URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                                 URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
    static func protected(_ rows: [WorktreeCleanup.Worktree], window: WindowContext) -> [WorktreeCleanup.Worktree] {
        rows.map { row in
            var row = row
            let snapshot = window.store.snapshot
            if !window.store.isConnected { row.blockers.append("Terminal engine disconnected; session liveness is unknown") }
            if snapshot.panes.contains(where: { pane in pane.searchCwds.contains { contains(row.path, $0) } }) {
                row.blockers.append("Open terminal or agent; close its workspace first")
            }
            if WindowRegistry.shared.windows.contains(where: { context in
                context.allEditors.flatMap(\.dirtyDocuments).contains { contains(row.path, $0.url.path) }
            }) { row.blockers.append("Unsaved editor changes") }
            if BrowserDrafts.retained(in: row.path, directory: EngineSession.supportDirectory.appendingPathComponent("browser-drafts")) {
                row.blockers.append("Saved browser feedback; send or clear its annotations first")
            }
            if AgentCenter.shared.sessions.contains(where: { contains(row.path, $0.cwd) }) { row.blockers.append("Retained agent conversation; close it first") }
            if WorktreeSetupRunner.shared.state(for: row.path)?.active == true { row.blockers.append("Setup is running") }
            return row
        }
    }

    static func confirm(_ worktrees: [WorktreeCleanup.Worktree], directory: String, window: WindowContext) {
        let rows = protected(worktrees, window: window)
        guard rows.allSatisfy(\.removable) else {
            ToastCenter.shared.info("Worktree is protected", detail: rows.flatMap(\.blockers).joined(separator: "\n")); return
        }
        do {
            let configs = try Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.path, try ProjectConfiguration.load(checkout: row.path, root: ProjectActionsStore.root(of: directory)))
            })
            ConfirmCenter.shared.ask(title: "Remove \(rows.count) merged worktree(s)?",
                message: "Folders are deleted; branches stay. Configured archive commands run first. Failure keeps the worktree.",
                items: rows.map { row in row.path + (configs[row.path]?.archive.map { "\nArchive: " + $0 } ?? "") },
                confirmTitle: "Archive and remove", destructive: true) { _ in
                    Task { await remove(rows, configs: configs, directory: directory, window: window) }
                }
        } catch { ToastCenter.shared.fail(nil, "Couldn't read archive configuration", detail: error.localizedDescription) }
    }

    private static func remove(_ rows: [WorktreeCleanup.Worktree], configs: [String: ProjectConfiguration], directory: String, window: WindowContext) async {
        for row in rows {
            do {
                guard protected([row], window: window).allSatisfy(\.removable) else { throw CleanupFailure("Workspace became active. Close it and retry.") }
                let current = try ProjectConfiguration.load(checkout: row.path, root: ProjectActionsStore.root(of: directory))
                guard current == configs[row.path] else { throw CleanupFailure("Configuration changed. Review removal again.") }
                try await Task.detached {
                    guard let fresh = WorktreeCleanup.list(in: directory).first(where: { $0.path == row.path }), fresh.removable else { throw CleanupFailure("Worktree is no longer merged and clean.") }
                }.value
                try await ArchiveHook.run(current, checkout: row.path, root: ProjectActionsStore.root(of: directory))
                // Refresh both application and git evidence after the hook, immediately before removal.
                await withCheckedContinuation { continuation in window.store.refresh { continuation.resume() } }
                guard protected([row], window: window).allSatisfy(\.removable) else { throw CleanupFailure("Workspace became active during archive. Close it and retry.") }
                try await Task.detached {
                    guard let fresh = WorktreeCleanup.list(in: directory).first(where: { $0.path == row.path }), fresh.removable else {
                        throw CleanupFailure("Git state changed; worktree is no longer merged and clean.")
                    }
                    try WorktreeCleanup.remove(fresh, in: directory)
                }.value
                ToastCenter.shared.succeed(nil, "Removed worktree", detail: row.branch ?? row.path)
            } catch {
                ToastCenter.shared.fail(nil, "Worktree retained", detail: error.localizedDescription,
                    action: .init(title: "Retry") { confirm([row], directory: directory, window: window) })
            }
        }
        window.store.scheduleRefresh()
    }

    struct CleanupFailure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
