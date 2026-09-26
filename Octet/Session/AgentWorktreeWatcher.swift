import Foundation

/// Worktrees an agent makes itself (`claude --worktree`, Codex, a script)
/// get the same start as one made from Octet: when a pane first shows up in
/// a linked worktree made in the last half hour, the main checkout's env
/// files are copied in (never overwriting), and a project setup script is
/// offered in a tab of its own, since the agent has the pane.
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
                let copied = WorktreeSetup.copyEnvFiles(from: root, to: checkout)
                let script = WorktreeSetup.script(in: checkout,
                                                  isExecutable: { files.isExecutableFile(atPath: $0) },
                                                  read: { files.contents(atPath: $0) })
                DispatchQueue.main.async {
                    guard !self.handled.contains(checkout) else { return }
                    self.markHandled(checkout)
                    let name = URL(fileURLWithPath: checkout).lastPathComponent
                    let action = script.map { script in
                        ToastCenter.Action(title: "Run Setup") {
                            WorktreeSetupRunner.shared.runInNewTab(script, repoRoot: root, checkout: checkout, store: store)
                        }
                    }
                    if !copied.isEmpty || action != nil {
                        ToastCenter.shared.info(
                            copied.isEmpty ? "New worktree \(name)" : "Copied \(WorktreeSetupRunner.list(copied)) into \(name)",
                            detail: action == nil ? "An agent made this worktree." : "An agent made this worktree. It has a setup script.",
                            after: action == nil ? 5 : 15, action: action)
                    }
                }
            }
        }
    }
}
