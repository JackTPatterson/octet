import SwiftUI

/// What the focused pane's repository is: the toolchain version a command
/// there would run, the branch, and how much the working tree has changed.
/// Kept for one directory at a time; the branch and changes are re-read every
/// few seconds, the version once per repo and runtime.
@MainActor
final class RepoContextModel: ObservableObject {
    struct Context: Equatable {
        let root: String
        var branch: String?
        var runtime: ProjectRuntime?
        var version: String?
        var changes: WorkingTreeChanges?
    }

    @Published private(set) var context: Context?
    private var directory: String?
    private var timer: Timer?
    private var readingChanges = false
    /// Versions by runtime and repo root. A version manager can pick a
    /// different one per project, so a root is the smallest safe key.
    private static var versions: [String: String] = [:]
    private static var fetching: Set<String> = []

    func show(_ directory: String?) {
        guard directory != self.directory else { return }
        self.directory = directory
        guard let directory, let root = GitBranch.repositoryRoot(for: directory) else {
            context = nil
            timer?.invalidate()
            timer = nil
            return
        }
        let runtime = ProjectRuntime.detect(from: directory, root: root)
        context = Context(root: root, branch: GitBranch.current(in: directory), runtime: runtime,
                          version: runtime.flatMap { Self.versions[Self.key($0, root)] })
        loadVersion()
        readChanges()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        guard let directory, var context else { return }
        let branch = GitBranch.current(in: directory)
        if branch != context.branch {
            context.branch = branch
            self.context = context
        }
        readChanges()
    }

    private func readChanges() {
        guard let directory, !readingChanges else { return }
        readingChanges = true
        DispatchQueue.global(qos: .utility).async {
            let changes = WorkingTreeChanges.read(in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                readingChanges = false
                guard directory == self.directory, var context, context.changes != changes else { return }
                context.changes = changes
                self.context = context
            }
        }
    }

    private func loadVersion() {
        guard let context, let runtime = context.runtime, context.version == nil else { return }
        let root = context.root
        let key = Self.key(runtime, root)
        guard !Self.fetching.contains(key) else { return }
        Self.fetching.insert(key)
        let command = "cd \(PluginCLI.quote(root)) && " + runtime.versionCommand.map(PluginCLI.quote).joined(separator: " ")
        PluginCLI.runShell(command, timeout: 10) { [weak self] result in
            Self.fetching.remove(key)
            guard result.exitCode == 0, let version = ProjectRuntime.version(fromOutput: result.output) else { return }
            Self.versions[key] = version
            guard let self, var context = self.context, context.root == root, context.runtime == runtime else { return }
            context.version = version
            self.context = context
        }
    }

    private static func key(_ runtime: ProjectRuntime, _ root: String) -> String { runtime.id + "|" + root }
}

/// A strip under the terminal while the focused pane is inside a git repo.
struct RepoContextBar: View {
    let context: RepoContextModel.Context
    @ObservedObject private var plugins = OctetPluginHost.shared

    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 6) {
            if let runtime = context.runtime {
                chip(help: "\(runtime.name)\(context.version.map { " \($0)" } ?? "")") {
                    if let badge = plugins.runtimeBadge(id: runtime.id) {
                        RuntimeIcon(badge: badge, size: 11)
                    }
                    Text(context.version ?? runtime.name)
                }
            }
            if let branch = context.branch {
                chip(help: "Branch \(branch)") {
                    OctetIcon("arrow.triangle.branch", size: 10)
                        .foregroundStyle(Theme.textSecondary)
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let changes = context.changes, !changes.isEmpty {
                chip(help: "Working tree changes") {
                    if changes.added > 0 {
                        Text("+\(changes.added)").foregroundStyle(Color(hex: AgentStateColor.done))
                    }
                    if changes.removed > 0 {
                        Text("-\(changes.removed)").foregroundStyle(Color(hex: AgentStateColor.blocked))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Theme.terminalBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repository")
    }

    private func chip<Content: View>(help: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(Theme.monoFont.monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .help(help)
    }
}
