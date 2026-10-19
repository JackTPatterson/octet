import Foundation

/// Fresh worktrees created by an external agent receive the same portable
/// configuration and tracked setup as worktrees created in the UI. An agent
/// already running in that worktree cannot be held back retroactively.
@MainActor
final class AgentWorktreeWatcher {
    static let shared = AgentWorktreeWatcher()
    private static let handledKey = "octet.worktreeSetup.handled"
    /// A worktree older than this was set up by whoever made it, or never will be.
    static let freshFor: TimeInterval = 30 * 60
    private var seen: Set<String> = []

    func markHandled(_ checkout: String) {
        let defaults = UserDefaults.standard
        let kept = (defaults.stringArray(forKey: Self.handledKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        defaults.set(Array(Set(kept + [checkout])).sorted(), forKey: Self.handledKey)
    }

    private var handled: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.handledKey) ?? []) }

    func observe(_ snapshot: EngineSnapshot, store: SessionStore) {
        guard SettingsStore.shared.values.worktreeSetup else { return }
        let fresh = Set(snapshot.panes.compactMap(\.effectiveCwd)).subtracting(seen)
        guard !fresh.isEmpty else { return }
        seen.formUnion(fresh)
        let handled = self.handled
        DispatchQueue.global(qos: .utility).async {
            let files = FileManager.default
            var found: [String: String] = [:]
            for cwd in fresh {
                guard let worktree = WorktreeSetup.linkedWorktree(
                    containing: cwd,
                    exists: { files.fileExists(atPath: $0) },
                    read: { try? String(contentsOfFile: $0, encoding: .utf8) }
                ), !handled.contains(worktree.checkout) else { continue }
                let made = (try? files.attributesOfItem(atPath: worktree.checkout + "/.git")[.creationDate] as? Date) ?? .distantPast
                guard Date().timeIntervalSince(made) < Self.freshFor else { continue }
                found[worktree.checkout] = worktree.repoRoot
            }
            for (checkout, root) in found {
                DispatchQueue.main.async {
                    guard !self.handled.contains(checkout) else { return }
                    self.markHandled(checkout)
                    // Use the same configuration and completion tracking as UI-created
                    // worktrees. An already-running external agent cannot be held back.
                    WorktreeSetupRunner.shared.run(after: ["workspace": ["worktree": [
                        "repo_root": root, "checkout_path": checkout
                    ]]], store: store)
                }
            }
        }
    }
}
