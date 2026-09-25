import AppKit
import SwiftUI

/// One palette row.
struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case agent(AgentBrand)
        case state(EngineAgentStatus)
    }

    enum Effect {
        case run(() -> Void)
        /// Ask for text, then run with it (rename, new worktree, …).
        case prompt(title: String, placeholder: String, initial: String, submit: (String) -> Void)
        /// Replace the list with items loaded asynchronously (plugin logs, …).
        case list(title: String, load: (@escaping ([PaletteItem]) -> Void) -> Void)
    }

    let id: String
    let kind: PaletteKind
    let title: String
    var subtitle: String = ""
    var keywords: [String] = []
    var shortcut: String?
    var icon: Icon
    var effect: Effect

    var searchable: PaletteSearchable {
        PaletteSearchable(id: id, kind: kind, title: title, subtitle: subtitle, keywords: keywords)
    }
}

/// Builds every palette entry from live session state.
@MainActor
enum PaletteCatalog {
    /// Everything the palette offers, acting on the window it opened in.
    static func items(window: WindowContext) -> [PaletteItem] {
        actions(window: window)
            + discoveredAgents(window: window)
            + workspaces(window: window)
            + tabs(window: window)
            + agents(window: window)
            + projects(window: window)
            + plugins(window: window)
    }

    // MARK: Discovered agents

    /// One row per agent installed on this machine, opening a terminal tab
    /// already running it. The terminal is agent-agnostic, so this works for
    /// agents Octet has no driver for.
    static func discoveredAgents(window: WindowContext) -> [PaletteItem] {
        AgentDiscoveryStore.shared.agents.compactMap { agent in
            guard agent.executablePath != nil else { return nil }
            let brand = AgentBrand.forAgent(agent.id)
            return PaletteItem(
                id: "agent.tab.\(agent.id)",
                kind: .action,
                title: "New \(agent.displayName) Tab",
                subtitle: agent.version ?? agent.command,
                keywords: ["run", "terminal", "agent", agent.command],
                icon: brand.map { .agent($0) } ?? .symbol("terminal"),
                effect: .run { window.newTab(running: agent) }
            )
        }
    }

    // MARK: Actions

    static func actions(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        let ui = window.ui
        let workspace = window.focusedWorkspace
        let tab = window.focusedWorkspaceTabs.first { $0.tabId == window.displayedFocusedTabId }
        func action(
            _ id: String, _ title: String, _ symbol: String, shortcut: String? = nil,
            keywords: [String] = [], _ run: @escaping () -> Void
        ) -> PaletteItem {
            PaletteItem(id: "action.\(id)", kind: .action, title: title, keywords: keywords,
                        shortcut: shortcut, icon: .symbol(symbol), effect: .run(run))
        }

        var items: [PaletteItem] = [
            action("newTab", "New Tab", "plus.square", shortcut: "⌘T", keywords: ["create", "terminal"]) { window.newTab() },
            action("closeTab", "Close Tab", "xmark.square", shortcut: "⌘W") { window.closeFocusedTab() },
            action("nextTab", "Next Tab", "arrow.right.square", shortcut: "⌘⇧]") { window.selectAdjacentTab(offset: 1) },
            action("previousTab", "Previous Tab", "arrow.left.square", shortcut: "⌘⇧[") { window.selectAdjacentTab(offset: -1) },
            action("moveTabLeft", "Move Tab Left", "arrow.left.to.line", keywords: ["reorder"]) { store.moveFocusedTab(by: -1) },
            action("moveTabRight", "Move Tab Right", "arrow.right.to.line", keywords: ["reorder"]) { store.moveFocusedTab(by: 1) },
            action("newWorkspace", "New Workspace", "rectangle.stack.badge.plus", shortcut: "⌘N", keywords: ["space"]) { window.newWorkspace() },
            action("openFile", "Open File…", "tool.edit", shortcut: "⌘O", keywords: ["code", "editor", "search"]) { window.showFilePicker() },
            action("openFolder", "Open Folder as Workspace…", "folder.badge.plus", shortcut: "⌘⇧O", keywords: ["project", "directory"]) { openFolder(window: window) },
            action("saveFile", "Save File", "tool.write", shortcut: "⌘S", keywords: ["code", "editor"]) { window.editor.save() },
            action("nextWorkspace", "Next Workspace", "chevron.down.square", shortcut: "⌃⌘↓") { window.selectAdjacentWorkspace(offset: 1) },
            action("previousWorkspace", "Previous Workspace", "chevron.up.square", shortcut: "⌃⌘↑") { window.selectAdjacentWorkspace(offset: -1) },
            action("splitRight", "Split Pane Right", "rectangle.split.2x1", shortcut: "⌘D", keywords: ["vertical"]) { window.splitPane(.right) },
            action("splitDown", "Split Pane Down", "rectangle.split.1x2", shortcut: "⌘⇧D", keywords: ["horizontal"]) { window.splitPane(.down) },
            action("zoomPane", "Toggle Pane Zoom", "arrow.up.left.and.arrow.down.right", shortcut: "⌘⇧↩", keywords: ["maximize"]) { window.toggleZoom() },
            action("closePane", "Close Pane", "xmark.rectangle") { window.closeFocusedPane() },
            action("newWindow", "New Window", "rectangle.on.rectangle", shortcut: "⌥⌘N",
                   keywords: ["window", "open"]) { WindowActions.newWindow(store: store) },
            action("tabToWindow", "Move Tab to New Window", "rectangle.on.rectangle",
                   keywords: ["window", "tear", "detach", "pop out"]) { WindowActions.moveFocusedTabToNewWindow(from: window) },
            action("mergeWindows", "Merge All Windows", "rectangle.on.rectangle",
                   keywords: ["window", "combine", "close"]) { WindowActions.mergeAllWindows() },
            action("paneToTab", "Move Pane to New Tab", "rectangle.on.rectangle",
                   keywords: ["break", "unsplit", "detach", "split", "pane", "tab"]) { window.moveFocusedPaneToNewTab() },
            action("focusLeft", "Focus Pane Left", "arrow.left", shortcut: "⌘⌥←") { window.focusPane(.left) },
            action("focusRight", "Focus Pane Right", "arrow.right", shortcut: "⌘⌥→") { window.focusPane(.right) },
            action("focusUp", "Focus Pane Up", "arrow.up", shortcut: "⌘⌥↑") { window.focusPane(.up) },
            action("focusDown", "Focus Pane Down", "arrow.down", shortcut: "⌘⌥↓") { window.focusPane(.down) },
            action("toggleSidebar", "Toggle Sidebar", "sidebar.left", shortcut: "⌘B") { ui.sidebarVisible.toggle() },
            action("reloadConfig", "Reload Terminal Config", "arrow.clockwise", keywords: ["settings"]) { store.reloadSessionConfig() },
            action("installHook", "Install Subagent Tabs Hook", "sparkles",
                   keywords: ["claude", "codex", "agent", "setup"]) { SubagentHookMenu.install() },
            action("removeHook", "Remove Subagent Tabs Hook", "sparkles",
                   keywords: ["claude", "codex", "agent"]) { SubagentHookMenu.uninstall() },
            action("revealConfig", "Reveal Terminal Config in Finder", "doc.text.magnifyingglass") {
                if let path = EngineSession.make()?.configPath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            },
        ]

        items.append(action("review", "Review Changes", "doc.text.magnifyingglass", shortcut: "⌘⇧R",
                            keywords: ["diff", "git", "changes", "comment", "code review", "agent"]) { window.toggleReview() })
        items += accountItems(window: window)
        if let item = checkpointItem(window: window) { items.append(item) }

        // Broadcast: the prompt's title names who receives it, so what's
        // about to be sent where is never a guess.
        for (scope, title, symbol) in [
            (Broadcast.Scope.tab, "Broadcast to Panes in This Tab…", "rectangle.split.2x1"),
            (.workspace, "Broadcast to Agents in This Workspace…", "tool.agent"),
            (.everywhere, "Broadcast to All Agents…", "tool.agent"),
        ] {
            let targets = Broadcast.targets(scope, in: store.snapshot,
                                            workspaceId: workspace?.workspaceId, tabId: tab?.tabId)
            // A tab with one pane has nothing to broadcast to.
            guard targets.count > (scope == .tab ? 1 : 0) else { continue }
            items.append(PaletteItem(
                id: "action.broadcast.\(scope.rawValue)", kind: .action, title: title,
                subtitle: Broadcast.summary(targets),
                keywords: ["send", "all", "prompt", "synchronize", "sync", "multiple", "compare"],
                icon: .symbol(symbol),
                effect: .prompt(title: "Send to \(Broadcast.summary(targets))", placeholder: "Prompt or command", initial: "") { text in
                    store.broadcast(text, to: targets)
                }
            ))
        }

        if let tab {
            items.append(PaletteItem(
                id: "action.renameTab", kind: .action, title: "Rename Tab…", keywords: ["label"],
                icon: .symbol("pencil"),
                effect: .prompt(title: "Rename Tab", placeholder: "Tab name", initial: tab.label) { label in
                    store.renameTab(tab.tabId, to: label)
                }
            ))
        }
        if let workspace {
            items.append(PaletteItem(
                id: "action.renameWorkspace", kind: .action, title: "Rename Workspace…", keywords: ["label", "space"],
                icon: .symbol("pencil.line"),
                effect: .prompt(title: "Rename Workspace", placeholder: "Workspace name", initial: workspace.label) { label in
                    store.renameWorkspace(workspace.workspaceId, to: label, from: workspace.label)
                }
            ))
            items.append(PaletteItem(
                id: "action.newWorktree", kind: .action, title: "New Worktree…", keywords: ["git", "branch"],
                icon: .symbol("arrow.triangle.branch"),
                effect: .prompt(title: "New Worktree", placeholder: "Branch name", initial: "") { branch in
                    window.createWorktree(branch: branch)
                }
            ))
            items.append(action("closeWorkspace", "Close Workspace", "xmark.bin") {
                store.closeWorkspace(workspace.workspaceId)
            })
            if store.isPinned(workspace.workspaceId) {
                items.append(action("unpinWorkspace", "Unpin Workspace", "pin.slash", keywords: ["idle", "keep"]) {
                    store.setPinned(workspace.workspaceId, false)
                })
            } else {
                items.append(action("pinWorkspace", "Pin Workspace to Keep in View", "pin", keywords: ["idle", "keep", "stale"]) {
                    store.setPinned(workspace.workspaceId, true)
                })
            }
            items.append(action("markIdle", "Move Workspace to Idle", "moon.zzz", keywords: ["stale", "archive", "hide"]) {
                store.markIdle(workspace.workspaceId)
            })
        }
        // Machines the engine can reach, each opening a session in a tab.
        for machine in store.remoteMachines where machine.enabled {
            items.append(action("remote.\(machine.id)", "Open \(machine.label)", "network",
                                keywords: ["remote", "ssh", "machine", machine.target]) {
                store.openRemote(machine, workspaceId: window.focusedWorkspace?.workspaceId)
            })
        }
        items.append(action("remoteAdd", "Add a Remote Machine…", "network.badge.shield.half.filled",
                            keywords: ["ssh", "remote", "machine", "connect"]) {
            PaletteCatalog.addRemoteMachine(store: store)
        })
        items.append(action("agentBoard", "Running Terminal Agents…", "square.grid.2x2",
                            keywords: ["board", "overview", "running", "status", "all"]) {
            AgentBoardWindow.open()
        })
        items.append(action("twin", window.twin.isVisible ? "Show the Terminal" : "Visual Twin",
                            "rectangle.on.rectangle.angled", shortcut: "⌘⇧V",
                            keywords: ["twin", "agent", "conversation", "native", "ui", "chat"]) {
            window.twin.toggle()
        })
        items.append(action("installSpecs", "Install Command Completion Specs", "square.and.arrow.down.on.square",
                            keywords: ["completion", "autocomplete", "subcommands", "flags", "specs"]) {
            SpecIngest.run { _ in } completion: { result in
                switch result {
                case .success(let outcome):
                    ToastCenter.shared.info("Installed \(outcome.commands) command specs",
                                            detail: SpecIngest.sourceName)
                case .failure(let error):
                    ToastCenter.shared.fail(nil, "Couldn't install the command specs",
                                            detail: String(describing: error))
                }
            }
        })
        for record in store.closedTabs.records.reversed() {
            items.append(action("reopen.\(record.terminalId)", "Reopen \(record.title)", "arrow.uturn.backward",
                                shortcut: record.terminalId == store.closedTabs.records.last?.terminalId
                                    ? OctetShortcut.reopenClosedTab.display : nil,
                                keywords: ["closed", "undo", "restore", "recent"] + (record.command.map { [$0] } ?? [])) {
                window.reopenClosedTab(record)
            })
        }
        items.append(action("recoverSessions", "Recover Agent Sessions…", "arrow.counterclockwise.circle",
                            keywords: ["resume", "restore", "claude", "codex", "crash", "restart", "history"]) {
            store.recovery.showHistory()
        })
        if !store.idleWorkspaces.isEmpty {
            let count = store.idleWorkspaces.count
            items.append(action("closeIdle", "Close \(count) Idle Workspace\(count == 1 ? "" : "s")…", "xmark.bin.fill",
                                keywords: ["stale", "cleanup", "unused"]) {
                ConfirmCenter.shared.ask(
                    title: "Close \(count) idle workspace\(count == 1 ? "" : "s")?",
                    message: "Their terminals and any processes running in them will end.",
                    items: store.idleWorkspaces.map(\.label),
                    confirmTitle: "Close",
                    destructive: true
                ) { _ in store.closeIdleWorkspaces() }
            })
        }
        items.append(PaletteItem(
            id: "action.idleThreshold", kind: .action, title: "Set Idle Threshold…",
            subtitle: "Now \(IdleDock.thresholdLabel(store.idleAfter)) · e.g. 30m, 2h, 1d",
            keywords: ["stale", "idle", "unused", "organize"],
            icon: .symbol("clock.arrow.circlepath"),
            effect: .prompt(title: "Move workspaces to Idle after", placeholder: "30m, 2h, 1d",
                            initial: IdleDock.thresholdLabel(store.idleAfter)) { text in
                guard let seconds = PaletteCatalog.parseDuration(text) else {
                    ToastCenter.shared.fail(nil, "Couldn't read \"\(text)\"", detail: "Use a number with m, h, or d, like 45m or 3h")
                    return
                }
                store.idleAfter = seconds
                ToastCenter.shared.info("Idle threshold set to \(IdleDock.thresholdLabel(seconds))")
            }
        ))
        return items
    }

    /// Parses `45m`, `2h`, `1d`, or a bare number of minutes.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let unit = trimmed.last.flatMap { "mhd".contains($0) ? $0 : nil }
        guard let value = Double(unit == nil ? trimmed : String(trimmed.dropLast())), value > 0 else { return nil }
        switch unit {
        case "h": return value * 3600
        case "d": return value * 86_400
        default: return value * 60
        }
    }

    // MARK: Navigation

    static func workspaces(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        return store.groups.flatMap { group in
            group.workspaces.map { workspace in
                let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspace.workspaceId))
                let branch = store.branches[workspace.workspaceId]
                let subtitle = [group.name, branch, agent.flatMap { a in
                    AgentBrand.forAgent(a.agent).map { "\($0.displayName) \(stateLabel(a.agentStatus))" }
                }].compactMap { $0 }.joined(separator: " · ")
                return PaletteItem(
                    id: "workspace.\(workspace.workspaceId)", kind: .workspace, title: workspace.label,
                    subtitle: subtitle,
                    keywords: [store.snapshot.directory(ofWorkspace: workspace.workspaceId) ?? ""],
                    icon: .state(agent?.agentStatus ?? workspace.agentStatus),
                    effect: .run { window.focusWorkspace(workspace.workspaceId) }
                )
            }
        }
    }

    static func tabs(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        let labels = Dictionary(uniqueKeysWithValues: store.snapshot.workspaces.map { ($0.workspaceId, $0.label) })
        return store.snapshot.tabs.sorted { ($0.workspaceId, $0.number) < ($1.workspaceId, $1.number) }.map { tab in
            let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tab.tabId))
            let brand = AgentBrand.forAgent(agent?.agent)
            return PaletteItem(
                id: "tab.\(tab.tabId)", kind: .tab,
                title: TabAutoName.display(label: tab.label, number: tab.number),
                subtitle: [labels[tab.workspaceId], "tab \(tab.number)"].compactMap { $0 }.joined(separator: " · "),
                icon: brand.map { .agent($0) } ?? .symbol("terminal"),
                effect: .run { window.focusTabAnywhere(tab) }
            )
        }
    }

    static func agents(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        let workspaceLabels = Dictionary(uniqueKeysWithValues: store.snapshot.workspaces.map { ($0.workspaceId, $0.label) })
        let tabLabels = Dictionary(uniqueKeysWithValues: store.snapshot.tabs.map { ($0.tabId, $0.label) })
        return store.snapshot.agents.map { agent in
            let brand = AgentBrand.forAgent(agent.agent)
            let name = agent.displayAgent ?? agent.name ?? brand?.displayName ?? agent.agent ?? "Agent"
            return PaletteItem(
                id: "agent.\(agent.paneId)", kind: .agent, title: name,
                subtitle: [stateLabel(agent.agentStatus), agent.workspaceId.flatMap { workspaceLabels[$0] },
                           agent.tabId.flatMap { tabLabels[$0] }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                keywords: [agent.agent ?? ""],
                icon: brand.map { .agent($0) } ?? .state(agent.agentStatus),
                effect: .run { window.focusAgent(paneId: agent.paneId) }
            )
        }
    }

    static func projects(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        return ProjectDirectories.list().map { path in
            let open = store.groups.contains { $0.id == path }
            return PaletteItem(
                id: "project.\(path)", kind: .project, title: URL(fileURLWithPath: path).lastPathComponent,
                subtitle: abbreviateHome(path) + (open ? " · open" : ""),
                icon: .symbol(open ? "folder.fill" : "folder"),
                effect: .run { window.openProject(path: path) }
            )
        }
    }

    // MARK: Plugins

    static func plugins(window: WindowContext) -> [PaletteItem] {
        let store = window.store
        var items: [PaletteItem] = []
        for plugin in store.plugins {
            let owner = [plugin.name, plugin.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " ")
            if plugin.enabled {
                for action in plugin.actions {
                    items.append(PaletteItem(
                        id: "plugin.\(plugin.pluginId).action.\(action.id)", kind: .plugin, title: action.title,
                        subtitle: [owner, action.description].compactMap { $0 }.joined(separator: " · "),
                        keywords: [plugin.pluginId, action.id],
                        icon: .symbol("puzzlepiece.extension"),
                        effect: .run { store.invokePluginAction(pluginId: plugin.pluginId, actionId: action.id, title: action.title) }
                    ))
                }
                for pane in plugin.panes {
                    items.append(PaletteItem(
                        id: "plugin.\(plugin.pluginId).pane.\(pane.id)", kind: .plugin, title: "Open \(pane.title)",
                        subtitle: [owner, pane.placement.map { "\($0) pane" }, pane.description]
                            .compactMap { $0 }.joined(separator: " · "),
                        keywords: [plugin.pluginId, pane.id, "pane"],
                        icon: .symbol("rectangle.on.rectangle"),
                        effect: .run { store.openPluginPane(pluginId: plugin.pluginId, paneId: pane.id, placement: pane.placement, title: pane.title) }
                    ))
                }
            }
            items.append(PaletteItem(
                id: "plugin.\(plugin.pluginId).toggle", kind: .plugin,
                title: "\(plugin.enabled ? "Disable" : "Enable") \(plugin.name)",
                subtitle: plugin.description ?? plugin.pluginId,
                keywords: [plugin.pluginId, "plugin"],
                icon: .symbol(plugin.enabled ? "pause.circle" : "play.circle"),
                effect: .run { store.setPluginEnabled(plugin.pluginId, !plugin.enabled) }
            ))
            items.append(PaletteItem(
                id: "plugin.\(plugin.pluginId).logs", kind: .plugin, title: "Show \(plugin.name) Logs",
                subtitle: "Recent action, event, and startup runs",
                keywords: [plugin.pluginId, "log", "output"],
                icon: .symbol("list.bullet.rectangle"),
                effect: logsEffect(store: store, pluginId: plugin.pluginId, title: "\(plugin.name) Logs")
            ))
            if plugin.isGitHubInstall, let engine = EngineSession.locateEngine() {
                items.append(PaletteItem(
                    id: "plugin.\(plugin.pluginId).uninstall", kind: .plugin, title: "Uninstall \(plugin.name)",
                    subtitle: plugin.pluginId, keywords: ["remove", "delete"],
                    icon: .symbol("trash"),
                    effect: .run {
                        PluginDialogs.confirmUninstall(name: plugin.name) { confirmed in
                            guard confirmed else {
                                ToastCenter.shared.info("Uninstall cancelled", detail: plugin.name)
                                return
                            }
                            store.uninstallPlugin(plugin.pluginId, enginePath: engine)
                        }
                    }
                ))
            } else {
                items.append(PaletteItem(
                    id: "plugin.\(plugin.pluginId).unlink", kind: .plugin, title: "Unlink \(plugin.name)",
                    subtitle: plugin.pluginId, keywords: ["remove", "local"],
                    icon: .symbol("link.badge.plus"),
                    effect: .run { store.unlinkPlugin(plugin.pluginId) }
                ))
            }
        }

        if let engine = EngineSession.locateEngine() {
            items.append(PaletteItem(
                id: "plugin.install", kind: .plugin, title: "Install Plugin from GitHub…",
                subtitle: "owner/repo[/subdir] · review the install preview before confirming",
                keywords: ["add", "marketplace"],
                icon: .symbol("square.and.arrow.down"),
                effect: .prompt(title: "Install Plugin", placeholder: "owner/repo", initial: "") { repo in
                    store.installPlugin(repo: repo, enginePath: engine, confirm: PluginDialogs.confirmInstall)
                }
            ))
        }
        items.append(PaletteItem(
            id: "plugin.link", kind: .plugin, title: "Link Local Plugin Folder…",
            subtitle: "A folder containing a plugin manifest", keywords: ["add", "develop"],
            icon: .symbol("folder.badge.gearshape"),
            effect: .run { linkPluginFolder(store: store) }
        ))
        items.append(PaletteItem(
            id: "plugin.logs", kind: .plugin, title: "Show All Plugin Logs",
            keywords: ["output", "debug"],
            icon: .symbol("list.bullet.rectangle"),
            effect: logsEffect(store: store, pluginId: nil, title: "Plugin Logs")
        ))
        return items
    }

    /// Restore a Checkpoint: the focused pane's working tree as it was
    /// before one of the agent turns in it.
    static func checkpointItem(window: WindowContext) -> PaletteItem? {
        let snapshot = window.store.snapshot
        guard let directory = window.focusedPaneId.flatMap({ snapshot.workingDirectory(ofPane: $0) })
                ?? window.focusedWorkspace.flatMap({ snapshot.directory(ofWorkspace: $0.workspaceId) }) else { return nil }
        let project = URL(fileURLWithPath: directory).lastPathComponent
        return PaletteItem(
            id: "action.restoreCheckpoint", kind: .action, title: "Restore a Checkpoint…",
            subtitle: "Undo agent turns in \(project)",
            keywords: ["undo", "rewind", "revert", "snapshot", "checkpoint", "rollback", "turn"],
            icon: .symbol("arrow.uturn.backward"),
            effect: .list(title: "Checkpoints in \(project)") { deliver in
                DispatchQueue.global(qos: .userInitiated).async {
                    let checkpoints = Checkpoints.list(in: directory)
                    let changes = Checkpoints.changes(since: checkpoints, in: directory)
                    let items = checkpoints.map { checkpoint in
                        let changed = changes[checkpoint.ref] ?? []
                        return PaletteItem(
                            id: "checkpoint.\(checkpoint.ref)", kind: .action,
                            title: "\(checkpoint.date.formatted(date: .abbreviated, time: .shortened)) · \(checkpoint.label)",
                            subtitle: changed.isEmpty ? "Same as now"
                                : "\(changed.count) \(changed.count == 1 ? "file differs" : "files differ") from now",
                            icon: .symbol("arrow.uturn.backward"),
                            effect: .run { CheckpointActions.confirmRestore(checkpoint, changed: changed, in: directory) }
                        )
                    }
                    DispatchQueue.main.async { deliver(items) }
                }
            }
        )
    }

    /// Accounts: add one, sign in to one, choose the project's.
    static func accountItems(window: WindowContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let profiles = SettingsStore.shared.values.accountProfiles
        for agent in AccountProfile.agents {
            let brand = AgentBrand.forAgent(agent)?.displayName ?? agent
            items.append(PaletteItem(
                id: "action.addAccount.\(agent)", kind: .action, title: "Add \(brand) Account…",
                subtitle: "Another sign-in, with its own settings and limits",
                keywords: ["account", "login", "sign in", "profile", "work", "personal", "switch"],
                icon: .symbol("tool.agent"),
                effect: .prompt(title: "Add \(brand) Account", placeholder: "Name, e.g. Work", initial: "") { name in
                    AccountActions.add(agent: agent, name: name, window: window)
                }
            ))
        }
        for profile in profiles {
            let brand = AgentBrand.forAgent(profile.agent)?.displayName ?? profile.agent
            items.append(PaletteItem(
                id: "action.signIn.\(profile.id)", kind: .action, title: "Sign In to \(brand) · \(profile.name)",
                subtitle: profile.home, keywords: ["account", "login", "auth"], icon: .symbol("tool.agent"),
                effect: .run { AccountActions.signIn(profile, window: window) }
            ))
        }
        guard !profiles.isEmpty, let folder = AccountActions.projectFolder(window: window) else { return items }
        let inUse = AccountProfiles.inForce(for: folder)
        let project = URL(fileURLWithPath: folder).lastPathComponent
        items.append(PaletteItem(
            id: "action.useAccount", kind: .action, title: "Use Account for This Project…",
            subtitle: inUse.isEmpty ? "\(project) uses the default accounts"
                : "\(project) uses " + inUse.map(\.name).joined(separator: ", "),
            keywords: ["account", "switch", "profile", "login", "work", "personal"],
            icon: .symbol("tool.agent"),
            effect: .list(title: "Account for \(project)") { deliver in
                var choices: [PaletteItem] = []
                for agent in AccountProfile.agents {
                    let own = profiles.filter { $0.agent == agent }
                    guard !own.isEmpty else { continue }
                    let brand = AgentBrand.forAgent(agent)?.displayName ?? agent
                    let current = inUse.first { $0.agent == agent }
                    choices.append(PaletteItem(
                        id: "account.default.\(agent)", kind: .action, title: "\(brand) · Default",
                        subtitle: current == nil ? "In use" : "Your usual sign-in", icon: .symbol("tool.agent"),
                        effect: .run { AccountActions.use(nil, agent: agent, for: folder) }
                    ))
                    for profile in own {
                        choices.append(PaletteItem(
                            id: "account.\(profile.id)", kind: .action, title: "\(brand) · \(profile.name)",
                            subtitle: current?.id == profile.id ? "In use" : profile.home, icon: .symbol("tool.agent"),
                            effect: .run { AccountActions.use(profile, agent: agent, for: folder) }
                        ))
                    }
                }
                deliver(choices)
            }
        ))
        return items
    }

    static func logsEffect(store: SessionStore, pluginId: String?, title: String) -> PaletteItem.Effect {
        .list(title: title) { deliver in
            store.pluginLogs(pluginId: pluginId) { logs in
                deliver(logs.sorted { $0.startedUnixMs > $1.startedUnixMs }.map(logItem))
            }
        }
    }

    static func logItem(_ log: EnginePluginLog) -> PaletteItem {
        let started = Date(timeIntervalSince1970: TimeInterval(log.startedUnixMs) / 1000)
        let what = log.actionId.map { "action \($0)" } ?? log.event.map { "event \($0)" } ?? "startup"
        let exit = log.exitCode.map { "exit \($0)" }
        let output = [log.stderr, log.stdout, log.error].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let symbol: String = switch log.status {
        case "succeeded": "checkmark.circle"
        case "failed": "xmark.octagon"
        default: "clock"
        }
        return PaletteItem(
            id: "pluginlog.\(log.logId)", kind: .plugin,
            title: "\(log.pluginId) · \(what)",
            subtitle: [log.status, exit, started.formatted(date: .omitted, time: .standard),
                       output.map { String($0.split(separator: "\n").first ?? "") }]
                .compactMap { $0 }.joined(separator: " · "),
            icon: .symbol(symbol),
            effect: .run {
                ConfirmCenter.shared.show(
                    title: "\(log.pluginId) · \(what)",
                    message: "Status: \(log.status)\(exit.map { " (\($0))" } ?? "") · started \(started.formatted())",
                    detail: """
                    stdout:
                    \(log.stdout?.isEmpty == false ? log.stdout! : "(empty)")

                    stderr:
                    \(log.stderr?.isEmpty == false ? log.stderr! : "(empty)")\(log.error.map { "\n\nerror: \($0)" } ?? "")
                    """
                )
            }
        )
    }

    static func linkPluginFolder(store: SessionStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a plugin folder (the one holding its manifest)"
        if panel.runModal() == .OK, let url = panel.url {
            store.linkPlugin(path: url.path)
        }
    }

    static func openFolder(window: WindowContext) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")
        if panel.runModal() == .OK, let url = panel.url {
            window.openProject(path: url.path)
        }
    }
}

/// Candidate project folders: children of the project parent directories,
/// most recently modified first.
enum ProjectDirectories {
    static func list(parents: [String] = ProjectGrouping.defaultParentDirectories) -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var entries: [(path: String, modified: Date)] = []
        for parent in parents {
            let base = parent.hasPrefix("~") ? home + parent.dropFirst() : parent
            guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = base + "/" + name
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      values.isDirectory == true else { continue }
                entries.append((path, values.contentModificationDate ?? .distantPast))
            }
        }
        return entries.sorted { $0.modified > $1.modified }.map(\.path)
    }
}

/// Native confirmation dialogs for plugin changes.
@MainActor
extension PaletteCatalog {
    /// Prepares a machine through the engine, which sets up the far side over
    /// ssh — so it only ever runs when the user asks for it by name.
    @MainActor
    static func addRemoteMachine(store: SessionStore) {
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Add a remote machine",
            message: "Octet asks the engine to prepare the far side over ssh, then lists it here. Enter the ssh target, e.g. user@host.",
            confirmTitle: "Continue",
            onConfirm: { _ in
                PaletteCatalog.promptForTarget(store: store)
            }
        ))
    }

    @MainActor
    private static func promptForTarget(store: SessionStore) {
        let alert = NSAlert()
        alert.messageText = "ssh target"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "user@host"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        store.addRemoteMachine(target: target)
    }
}

@MainActor
enum PluginDialogs {
    /// Shows the session server's install preview; returns true when the user confirms.
    static func confirmInstall(preview: String, answer: @escaping (Bool) -> Void) {
        let name = PluginCLI.previewField("name", in: preview) ?? "this plugin"
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Install \(name)?",
            message: "Plugins run as your user and are not sandboxed. Review the commands they will run:",
            detail: preview,
            confirmTitle: "Install",
            onConfirm: { _ in answer(true) },
            onCancel: { answer(false) }
        ))
    }

    static func confirmUninstall(name: String, answer: @escaping (Bool) -> Void) {
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Uninstall \(name)?",
            message: "The plugin's files are removed. Its config directory is kept.",
            confirmTitle: "Uninstall",
            destructive: true,
            onConfirm: { _ in answer(true) },
            onCancel: { answer(false) }
        ))
    }
}
