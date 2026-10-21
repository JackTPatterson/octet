import Foundation

/// What starting a workspace from an issue does besides making it.
struct IssueWorkspaceOptions {
    /// Start an agent on the issue once the worktree is up.
    var startAgent = true
    /// Which agent, by id ("claude", "codex"); nil is Claude Code, else Codex.
    var agentId: String?
}

/// "Start a workspace from an issue": a worktree on a branch named for the
/// issue, set up like New Worktree, opened in the window, with the agent
/// started on the issue. An existing worktree for that branch is opened
/// as it is; a branch with no worktree gets a numbered name.
@MainActor
enum IssueWorkspaceStarter {
    static func start(issue: TrackerIssue, tracker: IssueTracker, connectionId: String? = nil, projectDirectory: String, window: WindowContext,
                      options: IssueWorkspaceOptions = .init()) {
        let resolvedConnection: String?
        do { resolvedConnection = tracker == .github ? nil : try IssueService.connection(tracker, connectionId).id }
        catch { ToastCenter.shared.fail(nil, "Couldn't resolve issue connection", detail: error.localizedDescription); return }
        let link = WorkspaceIssueLink(tracker: tracker.rawValue, connectionId: resolvedConnection, issueId: issue.id, key: issue.key, title: issue.title, url: issue.url)
        let wanted = IssueWorkspace.branchName(key: issue.key, title: issue.title, tracker: tracker)
        let toast = ToastCenter.shared.progress("Starting a workspace for \(issue.key)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Git()
            // The main checkout, even from inside one of its worktrees.
            let common = try? git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: projectDirectory)
            let top = common.flatMap { $0.hasSuffix("/.git") ? String($0.dropLast(5)) : nil } ?? git.topLevel(projectDirectory)
            let branches = top.flatMap { try? git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: $0) }
            let worktrees = top.flatMap { try? git.run(["worktree", "list", "--porcelain"], in: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let top, let branches else {
                        ToastCenter.shared.fail(toast, "\(issue.key) needs a git repository",
                                                detail: "\((projectDirectory as NSString).abbreviatingWithTildeInPath) isn't in one.")
                        return
                    }
                    if let path = worktrees.flatMap({ IssueWorkspace.worktreePath(forBranch: wanted, porcelain: $0) }),
                       FileManager.default.fileExists(atPath: path) {
                        do {
                            if let existing = try WorkspaceIssueLink.read(in: path), existing.issueId != link.issueId || existing.connectionId != link.connectionId || existing.tracker != link.tracker {
                                throw IssueTrackerError.unreadable("This branch is already linked to another issue or connection.")
                            }
                            try link.save(in: path)
                        } catch { ToastCenter.shared.fail(toast, "Couldn't link workspace", detail: error.localizedDescription); return }
                        window.openProject(path: path)
                        ToastCenter.shared.succeed(toast, "Opened the workspace for \(issue.key)", detail: wanted)
                        return
                    }
                    let taken = Set(branches.split(separator: "\n").map(String.init))
                    ToastCenter.shared.dismiss(handleId: toast)
                    create(IssueWorkspace.uniqueBranch(wanted, existing: taken), issue: issue, link: link, root: top,
                           window: window, options: options)
                }
            }
        }
    }

    private static func create(_ branch: String, issue: TrackerIssue, link: WorkspaceIssueLink, root: String, window: WindowContext,
                               options: IssueWorkspaceOptions) {
        let store = window.store
        // By the repository's folder: the session server makes worktrees
        // only from the main checkout, and the window may be in a worktree.
        let params: [String: Any] = ["branch": branch, "cwd": root, "focus": false]
        store.call("worktree.create", params, failure: "Couldn't create worktree \(branch)", result: { result in
            do {
                guard let created = WorktreeSetup.parse(result) else { throw IssueTrackerError.unreadable("No checkout path returned.") }
                try link.save(in: created.checkoutPath)
            } catch { ToastCenter.shared.fail(nil, "Workspace created but issue link failed", detail: error.localizedDescription); return }
            WorktreeSetupRunner.shared.run(after: result, store: store, whenReady: {
                store.refresh {
                    launch(EngineCreated(result: result), branch: branch, issue: issue, window: window, options: options)
                }
            })
        }, then: { _ in })
    }

    private static func launch(_ created: EngineCreated, branch: String, issue: TrackerIssue,
                               window: WindowContext, options: IssueWorkspaceOptions) {
            let store = window.store
            guard let workspace = created.workspaceId else { return }
            window.focusWorkspace(workspace)
            guard options.startAgent else {
                return ToastCenter.shared.succeed(nil, "Created worktree \(branch)")
            }
            guard let agent = IssueWorkspace.agent(preferred: options.agentId, among: AgentDiscoveryStore.shared.agents),
                  let tab = store.agentTabParams(agent, workspaceId: workspace, arguments: [IssueWorkspace.prompt(for: issue)],
                                                 label: "\(agent.displayName) · \(issue.key)") else {
                ToastCenter.shared.info("Created worktree \(branch)",
                                        detail: "No Claude Code or Codex was found to start on \(issue.key).")
                return
            }
            window.applyLayout(tab, failure: "Couldn't start \(agent.displayName) on \(issue.key)")
            ToastCenter.shared.succeed(nil, "Started \(agent.displayName) on \(issue.key)", detail: branch)
    }
}
