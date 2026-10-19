import Combine
import SwiftUI

/// Monitors, background tasks, agents and shells owned by the agent in front,
/// as sections of the right panel's Overview. The process-tree boundary is
/// important: a workspace can contain many agents and terminals, but this
/// describes only the session being viewed.
struct RuntimePanel: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    /// Observed here, so opening a row redraws the list.
    @ObservedObject var ui: UIState
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var claudeAgents = AgentsStore.shared
    @ObservedObject private var codexAgents = CodexAgentsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var flashingEntryIDs: Set<String> = []
    @State private var collapsedBranches: Set<String> = []
    /// Counts auto-close timers, so only the latest one closes the panel.
    @State private var autoCloseGeneration = 0
    /// How long a panel that opened itself stays open when not hovered.
    private static let autoCloseAfter: TimeInterval = 3
    /// Held in state: a new timer on every redraw would restart the count,
    /// and a panel redrawn more often than every 4s would never refresh.
    @State private var refresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var workspaceId: String? { window.focusedWorkspace?.workspaceId }
    private var activeSession: AgentSession? { center.active(in: workspaceId) }
    private var scopeID: String? {
        if let activeSession { return "conversation:\(activeSession.id)" }
        return window.displayedFocusedTabId.map { "tab:\($0)" }
    }
    private var targetPanes: [EnginePane] {
        guard activeSession == nil, let tabId = window.displayedFocusedTabId else { return [] }
        // Agent discovery can lag behind the process itself (and new Claude
        // versions do not always emit the same marker). Inspect every pane in
        // the selected tab, then root its descendants at Claude in reload().
        // The tab boundary still prevents runtimes from another tab leaking in.
        return store.snapshot.panes.filter { $0.tabId == tabId }
    }

    var body: some View {
        runtimeContent
        .onAppear {
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            reload()
        }
        .onChange(of: workspaceId) { _, _ in
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            flashingEntryIDs = []
            collapsedBranches = []
            ui.runtimeExpandedEntryIDs = []
            reload()
        }
        .onChange(of: scopeID) { _, _ in
            // Details belong to one tab/conversation. Never let a row opened
            // in the previous scope stay open while the new list loads.
            withoutLayoutAnimation { ui.runtimeExpandedEntryIDs = [] }
            flashingEntryIDs = []
            collapsedBranches = []
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            reload()
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            revealNewEntries(ids)
            let open = ui.runtimeExpandedEntryIDs
            if !open.isSubset(of: ids) { ui.runtimeExpandedEntryIDs = open.intersection(ids) }
        }
        .onChange(of: entries.isEmpty, initial: true) { _, empty in
            ui.runtimeHasEntries = !empty
        }
        .onReceive(refresh) { _ in reload() }
    }

    #if DEBUG
    nonisolated(unsafe) static var debugSample = false
    /// ":sample:<variant>": "empty" shows nothing running, "partial" only
    /// subagents and shells; anything else is the full set.
    nonisolated(unsafe) static var debugVariant: String?

    /// Made-up subagents, background tasks, monitors and shells.
    private static var sampleEntries: [RuntimeEntry] {
        func entry(_ id: String, _ kind: RuntimeKind, _ title: String, _ detail: String, location: String = "Fix the upload retry",
                   command: String? = nil, prompt: String? = nil, output: String? = nil, process: String? = nil,
                   depth: Int = 0, seed: Int = 0, agent: String? = nil, model: String? = nil,
                   since: TimeInterval? = nil, pid: Int? = nil, pane: String? = nil) -> RuntimeEntry {
            RuntimeEntry(id: id, kind: kind, title: title, detail: detail, location: location, command: command,
                         prompt: prompt, output: output, process: process, depth: depth, accentSeed: seed,
                         agentID: agent, modelName: model, paneId: pane,
                         liveSince: since.map { Date().addingTimeInterval(-$0) }, pid: pid, parentID: id == "s1a" || id == "s1b" ? "s1" : nil)
        }
        let agents = [
            entry("s1", .agent, "Explore the retry logic", "Working", command: nil,
                  prompt: "Find every place uploads are retried and report what backoff each one uses.",
                  output: "Found 3 call sites: Uploader.retry, Queue.drain and the share extension.",
                  process: "Reading Sources/App/Uploader.swift", seed: 0, agent: "claude", model: "Sonnet 5.5", since: 94, pane: "p1"),
            entry("s1a", .agent, "Trace Uploader.retry callers", "Working", prompt: "Who calls Uploader.retry, and with what limit?",
                  output: "Queue.drain and ShareViewController.", process: "Searching for \"retry(\"",
                  depth: 1, seed: 3, agent: "claude", model: "Haiku 5.5", since: 31, pane: "p2"),
            entry("s1b", .agent, "Read the queue drain loop", "Needs input", prompt: "Summarise Queue.drain.",
                  output: "Waiting for permission to read ~/Library/Caches.", process: "Waiting for permission",
                  depth: 1, seed: 2, agent: "claude", model: "Haiku 5.5", since: 22),
            entry("s2", .agent, "Write the backoff tests", "Working", prompt: "Cover the cap at 30 seconds and the jitter.",
                  output: "RetryTests.swift: 4 cases written, running them now.", process: "Running swift test",
                  depth: 0, seed: 1, agent: "claude", model: "Opus 5.5", since: 41, pid: 4242),
            entry("s3", .agent, "Check the share extension", "Finished", prompt: "Does the extension use the same retry path?",
                  output: "It does not: it has its own loop in ShareViewController.", process: "Finished",
                  depth: 0, seed: 2, agent: "claude", model: "Haiku 5.5"),
        ]
        let tasks = [
            entry("t1", .task, "swift test --parallel", "Running", command: "swift test --parallel",
                  output: "Test Suite 'All tests' started\nTest Case 'RetryTests.testCap' passed (0.002 seconds)",
                  process: "swift-test", since: 63, pid: 4243),
            entry("t2", .task, "xcodebuild archive", "Running", command: "xcodebuild -scheme App archive",
                  output: "Compiling 214 files…", process: "xcodebuild", since: 212, pid: 4244),
            entry("t3", .task, "Lint the sources", "Failed", command: "swiftlint --strict",
                  output: "Uploader.swift:88: error: line_length\nswiftlint exited with code 2", process: "swiftlint"),
        ]
        let monitors = [
            entry("m1", .monitor, "Watching build/ for changes", "Active", command: "fswatch -o build",
                  output: "3 events in the last minute", process: "fswatch", since: 1480),
            entry("m2", .monitor, "Tailing the dev server", "Active", command: "tail -f logs/dev.log",
                  output: "GET /api/upload 200 41ms\nPOST /api/upload 503 (retry 2 of 5)", process: "tail", since: 905),
            entry("m3", .monitor, "CI: Build and test on master", "Waiting", command: "gh run watch",
                  output: "Build and test in progress (2m 11s)", process: "gh", since: 130),
        ]
        let shells = [
            entry("h1", .shell, "zsh", "Active", location: "Fix the upload retry", command: "zsh"),
            entry("h2", .shell, "bash", "Active", location: "Dev server", command: "bash"),
            entry("h3", .shell, "fish", "Active", location: "Scratch", command: "fish"),
        ]
        switch debugVariant {
        case "empty": return []
        case "partial": return agents + shells
        default: return agents + tasks + monitors + shells
        }
    }
    #endif

    /// One stack, so the modifiers on it run once, not per section.
    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            runtimeList(entries, kinds: [.agent])
            let background = entries.filter { $0.kind != .agent }
            if !background.isEmpty {
                SidePanelSectionView(.activity, trailing: {
                    HStack(spacing: 4) {
                        activityChip(.task, title: "Tasks", icon: "checklist", entries: background)
                        activityChip(.monitor, title: "Monitors", icon: "eye", entries: background)
                        activityChip(.shell, title: "Shells", icon: "terminal", entries: background)
                    }
                }) {
                    runtimeList(background, kinds: [.task, .monitor, .shell])
                }
            }
        }
    }

    @ViewBuilder
    private func activityChip(_ kind: RuntimeKind, title: String, icon: String, entries: [RuntimeEntry]) -> some View {
        let count = entries.filter { $0.kind == kind }.count
        if count > 0 {
            Button {
                motion.perform(.sidebar) {
                    ui.setPanelSection(.activity, open: true)
                    ui.setPanelSection(kind.section, open: true)
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text(title)
                        Text("\(count)").monospacedDigit().foregroundStyle(Theme.textPrimary)
                    }.fixedSize()
                    HStack(spacing: 4) {
                        OctetIcon(icon, size: 10)
                        Text("\(count)").monospacedDigit().foregroundStyle(Theme.textPrimary)
                    }.fixedSize()
                }
                .font(Theme.interfaceFont(10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).frame(height: 19)
                .background(Theme.hover, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show \(count) \(title.lowercased())")
            .accessibilityLabel("\(title), \(count)")
        }
    }

    /// Every kind is a section so each stays discoverable: one with work
    /// shows its rows; one with none is a single quiet line ("None").
    private func runtimeList(_ current: [RuntimeEntry], kinds: [RuntimeKind]) -> some View {
        ForEach(kinds) { kind in
            let rows = current.filter { $0.kind == kind }
            let loading = PlaneLoadingPreview.shows("overview") || AgentPresentationLogic.showsInitialRuntimeLoading(
                rowCount: rows.count, scanning: store.loadingPaneProcesses,
                hasUnscannedPane: targetPanes.contains { !store.scannedRuntimePaneIDs.contains($0.paneId) },
                hasUnscannedNativeRoot: activeSession.map {
                    $0.conversation.isRunning && $0.runtimePID != nil && store.nativeRuntimeProcesses[$0.id] == nil
                } ?? false)
            if kind == .agent {
                if loading { OverviewRowsSkeleton(rows: 2, tree: true).padding(8) }
                else if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No subagents yet").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                        Text("Agents started by this tab will appear here with their progress and results.")
                            .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else { section(kind, rows: rows).padding(.vertical, 10).padding(.horizontal, 4) }
            } else if !OverviewSections.isQuiet(count: rows.count, loading: loading) {
                SidePanelSectionView(kind.section, count: loading ? nil : rows.count) {
                    if loading {
                        OverviewRowsSkeleton(rows: 2, tree: kind == .agent)
                    } else {
                        section(kind, rows: rows)
                    }
                }
            }
        }
    }

    /// Stops the process behind a row.
    private func stop(_ entry: RuntimeEntry) {
        guard let pid = entry.pid else { return }
        if kill(pid_t(pid), SIGTERM) != 0, errno != ESRCH {
            ToastCenter.shared.fail(nil, "Couldn't stop \(entry.title)", detail: String(cString: strerror(errno)))
        } else {
            ToastCenter.shared.info("Stopped \(entry.title)")
            reload()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardWatcher.shared.acknowledge()
    }

    /// The row's ⋯ menu, also its right-click menu.
    private func menu(for entry: RuntimeEntry) -> [OctetMenuItem] {
        var items: [OctetMenuItem] = []
        let expanded = ui.runtimeExpandedEntryIDs.contains(entry.id)
        items.append(.action(expanded ? "Hide details" : "Show details and output",
                             icon: expanded ? "chevron.down" : "chevron.right") { toggle(entry) })
        if let paneId = entry.paneId, entry.kind == .agent {
            items.append(.action("Show tab", icon: "arrow.right.square") { window.focusAgent(paneId: paneId) })
        }
        items.append(.divider)
        if let command = entry.command ?? entry.prompt, !command.isEmpty {
            items.append(.action(entry.kind == .agent ? "Copy prompt" : "Copy command", icon: "doc.on.doc") { copy(command) })
        }
        if let output = entry.output, !output.isEmpty {
            items.append(.action("Copy latest output", icon: "doc.on.doc") { copy(output) })
        }
        if entry.pid != nil, entry.state != .done {
            items.append(.divider)
            items.append(.action("Stop", icon: "xmark.octagon", destructive: true) { stop(entry) })
        }
        return items
    }

    /// Opens or closes a row in place.
    private func toggle(_ entry: RuntimeEntry) {
        motion.perform(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)) {
            if ui.runtimeExpandedEntryIDs.contains(entry.id) {
                ui.runtimeExpandedEntryIDs.remove(entry.id)
            } else {
                ui.runtimeExpandedEntryIDs.insert(entry.id)
            }
        }
    }

    private func withoutLayoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func section(_ kind: RuntimeKind, rows: [RuntimeEntry]) -> some View {
        // Keep ancestry correct even when process discovery returns children first.
        let ordered: [RuntimeEntry] = kind == .agent
            ? RuntimeTree.order(rows, id: { $0.id }, parent: { $0.parentID }).map { entry, depth in
                var row = entry; row.depth = depth; return row
            } : rows
        let visible = AgentPresentationLogic.visibleIDs(ordered.map { (id: $0.id, depth: $0.depth) }, collapsed: collapsedBranches)
        let shown = ordered.filter { visible.contains($0.id) }
        let guides = TreeGuides.compute(depths: kind == .agent ? shown.map(\.depth) : shown.map { _ in 0 })
        return VStack(alignment: .leading, spacing: 1) {
            if kind == .agent {
                HStack(spacing: 10) {
                    ForEach([RuntimeState.running, .waiting, .failed, .done], id: \.title) { state in
                        let count = rows.filter { $0.state == state }.count
                        if count > 0 {
                            Text("\(count) \(state == .waiting ? "need you" : state.title.lowercased())")
                                .foregroundStyle(state == .running ? Theme.textSecondary : state.color)
                        }
                    }
                    Spacer(minLength: 0)
                }.font(Theme.captionFont).padding(.horizontal, 8).padding(.bottom, 8)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                RuntimeRow(entry: row,
                           guide: guides[index],
                           flashes: flashingEntryIDs.contains(row.id),
                           expanded: ui.runtimeExpandedEntryIDs.contains(row.id),
                           toggle: { toggle(row) },
                           focus: row.kind == .agent ? row.paneId.map { paneId in { window.focusAgent(paneId: paneId) } } : nil,
                           stop: row.pid != nil && row.state != .done && row.kind != .shell ? { stop(row) } : nil,
                           menu: { menu(for: row) },
                           childCount: rows.filter { $0.parentID == row.id }.count,
                           branchCollapsed: collapsedBranches.contains(row.id),
                           toggleBranch: {
                               motion.perform(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)) {
                                   if !collapsedBranches.insert(row.id).inserted { collapsedBranches.remove(row.id) }
                               }
                           })
                    .id(row.id)
                    .transition(motion.animates(.sidebar)
                        ? .opacity.combined(with: .offset(y: 6)) : .identity)
            }
        }
        .animation(motion.animation(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)), value: shown.map(\.id))
    }

    private func revealNewEntries(_ ids: [String]) {
        let current = Set(ids)
        let revealable = Set(entries.filter(\.autoReveal).map(\.id))
        let added = current.subtracting(ui.seenRuntimeEntryIDs).intersection(revealable)
        ui.seenRuntimeEntryIDs.formUnion(current)
        flashingEntryIDs.formIntersection(current)
        guard !added.isEmpty else { return }
        // A new runtime opens the panel on its page, briefly, unless the
        // panel is already the person's.
        if !ui.sidePanelVisible {
            ui.addPlane(.overview)
            ui.sidePanelAutoOpened = true
        }
        if ui.sidePanelAutoOpened { scheduleAutoClose() }
        flashingEntryIDs.formUnion(added)
        DispatchQueue.main.asyncAfter(deadline: .now() + (motion.animates(.sidebar) ? 0.85 : 0.15)) {
            flashingEntryIDs.subtract(added)
        }
    }

    /// Closes a panel that opened itself once it has sat unhovered for
    /// `autoCloseAfter`; another new runtime starts the count again.
    private func scheduleAutoClose() {
        autoCloseGeneration += 1
        let generation = autoCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCloseAfter) {
            guard generation == autoCloseGeneration, ui.sidePanelAutoOpened else { return }
            ui.sidePanelVisible = false
        }
    }

    private var entries: [RuntimeEntry] {
        #if DEBUG
        // Verification and demos: "planes:overview:sample" shows made-up work.
        if Self.debugSample { return Self.sampleEntries }
        #endif
        let snapshot = store.snapshot
        var result: [RuntimeEntry] = []

        for pane in targetPanes {
            guard let info = store.paneProcesses[pane.paneId] else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let location = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal"
            var shownShells = Set<String>()
            for process in info.background where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                guard shownShells.insert(title.lowercased()).inserted else { continue }
                result.append(RuntimeEntry(id: "\(pane.paneId)-\(process.pid)", kind: .shell,
                                           title: title, detail: "Active",
                                           location: location, command: process.name,
                                           prompt: nil, output: nil, process: title,
                                           depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                           paneId: pane.paneId))
            }
            let spawned = store.spawnedRuntimeAgents.filter { $0.paneId == pane.paneId }
            result += processAgents(spawned, location: location, sessionId: nil)
            // Claude Code in the terminal: its log says what it has running.
            // Its subagents' own subagents, and what they run, sit under them.
            result += HandoffRuntime.nested(store.terminalRuntimes[pane.paneId] ?? []).map { node in
                entry(node.runtime, location: location, paneId: pane.paneId, session: nil, depth: node.depth)
            }
        }
        // Subagents the Subagent Tabs hook opened as tabs of their own,
        // launched from this tab's panes (or by those subagents).
        let launchers = Set(targetPanes.map(\.paneId))
        if !launchers.isEmpty {
            for viewer in snapshot.subagentViewers(launchedFrom: launchers) {
                let title = viewer.tab.map { TabAutoName.display(label: $0.label, number: $0.number) }
                    ?? viewer.agent.name ?? "Subagent"
                let status = viewer.agent.agentStatus
                result.append(RuntimeEntry(id: "subagent-tab-\(viewer.agent.paneId)", kind: .agent,
                                           title: title,
                                           detail: status == .unknown ? "Running" : stateLabel(status).capitalized,
                                           location: "Its own tab", command: nil,
                                           prompt: nil, output: nil,
                                           process: status == .done ? "Finished" : "Working in its tab",
                                           depth: viewer.depth, accentSeed: Self.seed(viewer.agent.paneId),
                                           agentID: viewer.agent.agent ?? "claude", modelName: nil,
                                           paneId: viewer.agent.paneId, autoReveal: true,
                                           parentID: viewer.agent.parentPaneId.map { "subagent-tab-" + $0 }))
            }
        }

        if let session = activeSession {
            result += carriedRuntimes(in: session)
            result += activeMonitors(in: session)
            result += activeBackgroundTasks(in: session)
            result += activeSubagents(in: session)
            var shownShells = Set<String>()
            for process in store.nativeRuntimeProcesses[session.id] ?? [] where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                guard shownShells.insert(title.lowercased()).inserted else { continue }
                result.append(RuntimeEntry(id: "\(session.id)-\(process.pid)", kind: .shell,
                                           title: title, detail: "Active",
                                           location: session.title, command: process.name,
                                           prompt: nil, output: nil, process: title,
                                           depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                           paneId: nil, sessionId: session.id, autoReveal: true))
            }
            let processes = store.nativeRuntimeProcesses[session.id] ?? []
            let spawned = processes.compactMap { process -> SpawnedRuntimeAgent? in
                guard let agent = Self.agentExecutable(process.name) else { return nil }
                return SpawnedRuntimeAgent(pid: process.pid, parentPid: process.parentPid, agent: agent,
                                           name: AgentBrand.forAgent(agent)?.displayName ?? agent,
                                           paneId: nil, tabId: nil, workspaceId: session.workspaceId, cwd: session.cwd)
            }
            result += processAgents(spawned, location: session.title, sessionId: session.id)
        }
        let scopeDirectories = Set((activeSession.map { [$0.cwd] }
            ?? targetPanes.flatMap(\.searchCwds)).map(Self.canonicalDirectory))
        result += backgroundTasks(in: scopeDirectories)
        return result
    }

    private func reload() {
        var roots: [String: Int] = [:]
        for session in center.sessions where session.conversation.isRunning {
            if let pid = session.runtimePID { roots[session.id] = pid }
        }
        store.refreshPaneProcesses(in: workspaceId, nativeRoots: roots)
    }

    private static func commandName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private static func agentExecutable(_ raw: String) -> String? {
        AgentBrand.runtimeAgentID(forExecutable: raw)
    }

    private func processAgents(_ agents: [SpawnedRuntimeAgent], location: String,
                               sessionId: String?) -> [RuntimeEntry] {
        let ids = Set(agents.map(\.pid))
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.pid, $0) })
        return agents.map { agent in
            var depth = 0
            var parent = agent.parentPid
            var visited = Set<Int>()
            while ids.contains(parent), let ancestor = byId[parent], visited.insert(parent).inserted {
                depth += 1
                parent = ancestor.parentPid
            }
            return RuntimeEntry(id: "process-agent-\(agent.pid)", kind: .agent,
                                title: agent.name, detail: "Model",
                                location: location, command: agent.agent,
                                prompt: "Started by another agent", output: nil,
                                process: Self.commandName(agent.agent), depth: depth,
                                accentSeed: Self.seed(agent.agent), agentID: agent.agent, modelName: nil,
                                paneId: agent.paneId,
                                sessionId: sessionId, autoReveal: true, pid: agent.pid,
                                parentID: ids.contains(agent.parentPid) ? "process-agent-\(agent.parentPid)" : nil)
        }
    }

    private func backgroundTasks(in directories: Set<String>) -> [RuntimeEntry] {
        guard !directories.isEmpty else { return [] }
        let claude = claudeAgents.agents.filter {
            $0.kind == .background && ($0.state == .working || $0.state == .needsInput)
                && directories.contains(Self.canonicalDirectory($0.cwd))
        }.map { agent in
            let job = BackgroundJob.load(id: agent.id)
            return RuntimeEntry(id: "background-claude-\(agent.id)", kind: .agent,
                                title: agent.name,
                                detail: agent.state == .needsInput ? "Needs input" : "Background",
                                location: abbreviateHome(agent.cwd), command: nil,
                                prompt: job?.needs ?? job?.detail,
                                output: claudeAgents.lastLines[agent.sessionId],
                                process: "Background task", depth: 0,
                                accentSeed: Self.seed(agent.id), agentID: "claude", modelName: nil,
                                paneId: nil, autoReveal: false)
        }
        let codex = codexAgents.agents.filter {
            ($0.state == .working || $0.state == .needsInput)
                && directories.contains(Self.canonicalDirectory($0.cwd))
        }.map { agent in
            RuntimeEntry(id: "background-codex-\(agent.id)", kind: .agent,
                         title: agent.name,
                         detail: agent.state == .needsInput ? "Needs input" : "Background",
                         location: abbreviateHome(agent.cwd), command: nil,
                         prompt: codexAgents.previews[agent.id], output: codexAgents.previews[agent.id],
                         process: "Background task", depth: 0,
                         accentSeed: Self.seed(agent.id), agentID: "codex", modelName: nil,
                         paneId: nil, autoReveal: false)
        }
        return claude + codex
    }

    private static func canonicalDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Work the terminal had running when this conversation took over,
    /// until the agent has started each again (its new call takes the row).
    private func carriedRuntimes(in session: AgentSession) -> [RuntimeEntry] {
        guard !session.carriedRuntimes.isEmpty else { return [] }
        let started = session.processStartedAt ?? .distantFuture
        let restarted = session.conversation.items.compactMap { item -> String? in
            guard item.createdAt >= started, case .tool(let call) = item.kind, let input = call.inputObject else { return nil }
            return (input["command"] as? String) ?? (input["description"] as? String) ?? (input["name"] as? String)
        }
        return session.carriedRuntimes.compactMap { runtime in
            let key = runtime.command ?? runtime.title
            guard !restarted.contains(key) else { return nil }
            return entry(runtime, location: session.title, paneId: nil, session: session, carried: true)
        }
    }

    /// A row for work a Claude Code session log reports: live in a terminal
    /// pane, or carried into a conversation that is starting it again.
    private func entry(_ runtime: HandoffRuntime, location: String, paneId: String?,
                       session: AgentSession?, carried: Bool = false, depth: Int = 0) -> RuntimeEntry {
        let now = Date()
        let kind: RuntimeKind
        let detail: String
        let process: String
        switch runtime.kind {
        case .task:
            kind = .task
            detail = "Running"
            process = runtime.command?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "Background command"
        case .monitor:
            kind = .monitor
            detail = runtime.expiresAt.map { Self.remaining(until: $0, now: now) } ?? "Watching"
            process = "Watching"
        case .agent:
            kind = .agent
            detail = runtime.startedAt.map { "\(max(0, Int(now.timeIntervalSince($0))))s" } ?? "Working"
            process = "Working"
        }
        return RuntimeEntry(id: (carried ? "carried-" : "log-") + runtime.id, kind: kind, title: runtime.title,
                            detail: carried ? "Restarting" : detail, location: location, command: runtime.command,
                            prompt: runtime.kind == .agent ? runtime.prompt : runtime.title, output: nil,
                            process: carried ? "Moving from the terminal" : process, depth: depth,
                            accentSeed: Self.seed(runtime.id),
                            agentID: runtime.kind == .agent ? "claude" : nil,
                            modelName: runtime.kind == .agent ? session.map(modelName(for:)) : nil,
                            paneId: paneId, sessionId: session?.id, autoReveal: true,
                            liveSince: carried || runtime.kind == .monitor ? nil : runtime.startedAt,
                            parentID: runtime.parentId.map { (carried ? "carried-" : "log-") + $0 })
    }

    private func activeMonitors(in session: AgentSession) -> [RuntimeEntry] {
        let now = Date()
        let started = session.processStartedAt ?? .distantFuture
        return session.conversation.items.compactMap { item in
            guard item.createdAt >= started,
                  case .tool(let call) = item.kind, call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
                  call.result?.localizedCaseInsensitiveContains("monitor started") == true,
                  let input = call.inputObject else { return nil }
            let timeout = (input["timeout_ms"] as? NSNumber)?.doubleValue ?? 120_000
            let expires = item.createdAt.addingTimeInterval(timeout / 1_000)
            guard expires > now else { return nil }
            let title = input["description"] as? String ?? call.summary
            return RuntimeEntry(id: "monitor-\(item.id)", kind: .monitor,
                                title: title.isEmpty ? "Monitor" : title,
                                detail: Self.remaining(until: expires, now: now),
                                location: session.title, command: input["command"] as? String,
                                prompt: input["description"] as? String, output: call.result,
                                process: "Watching", depth: 0, accentSeed: 0,
                                agentID: nil, modelName: nil,
                                paneId: nil, sessionId: session.id, autoReveal: true)
        }
    }

    /// Claude and compatible agents mark asynchronous shell calls in their
    /// tool input. Their shell may be re-parented immediately, so the stream
    /// is a more reliable ownership signal than the process tree alone.
    private func activeBackgroundTasks(in session: AgentSession) -> [RuntimeEntry] {
        session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind,
                  (call.name.caseInsensitiveCompare("Bash") == .orderedSame
                    || call.name.caseInsensitiveCompare("Shell") == .orderedSame),
                  let input = call.inputObject else { return nil }
            let requested = input["run_in_background"] as? Bool == true
                || input["background"] as? Bool == true
            let reported = call.result?.localizedCaseInsensitiveContains("background") == true
            guard requested || reported else { return nil }
            let command = input["command"] as? String ?? call.input
            let description = input["description"] as? String
            let executable = command.split(whereSeparator: \.isWhitespace).first
                .map { Self.commandName(String($0)) }
            let runningProcess = executable.flatMap { expected in
                (store.nativeRuntimeProcesses[session.id] ?? []).first {
                    Self.commandName($0.name).caseInsensitiveCompare(expected) == .orderedSame
                }
            }
            let hasProcess = runningProcess != nil
            // A replayed log is full of background calls from processes that
            // have since exited; only this process's own may still be running.
            let current = session.processStartedAt.map { item.createdAt >= $0 } ?? false
            guard hasProcess || (current && (call.result == nil || session.conversation.isRunning)) else { return nil }
            return RuntimeEntry(id: "task-\(item.id)", kind: .task,
                                title: description ?? (call.summary.isEmpty ? "Background command" : call.summary),
                                detail: call.result == nil ? "Running" : "Background",
                                location: session.title, command: command,
                                prompt: description, output: call.result,
                                process: command.split(whereSeparator: \.isWhitespace).first.map(String.init),
                                depth: 0, accentSeed: Self.seed(item.id),
                                agentID: nil, modelName: nil,
                                paneId: nil, sessionId: session.id, autoReveal: true,
                                pid: runningProcess?.pid)
        }
    }

    private func activeSubagents(in session: AgentSession) -> [RuntimeEntry] {
        let now = Date()
        let calls: [(item: AgentItem, call: AgentToolCall)] = session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind,
                  call.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || call.name.caseInsensitiveCompare("Task") == .orderedSame else { return nil }
            return (item, call)
        }
        let byId = Dictionary(uniqueKeysWithValues: calls.map { ($0.item.id, $0) })
        let childrenByParent = Dictionary(grouping: session.conversation.items.compactMap { item in
            item.parent.map { ($0, item) }
        }, by: \.0).mapValues { $0.map(\.1) }
        // Replayed launches without a result were cut off with an earlier
        // process, not running now.
        let started = session.processStartedAt ?? .distantFuture
        var visible = Set(calls.filter {
            $0.item.createdAt >= started && ($0.call.result != nil || session.conversation.isRunning)
        }.map { $0.item.id })
        // Keep the ownership chain visible even if an agent's launch call has
        // already returned while one of its descendants is still working.
        var frontier = Array(visible)
        while let id = frontier.popLast(), let parent = byId[id]?.item.parent,
              byId[parent] != nil, visible.insert(parent).inserted {
            frontier.append(parent)
        }

        // Each subagent with the ones it started under it, however deep.
        let shown = RuntimeTree.order(calls.filter { visible.contains($0.item.id) },
                                      id: { $0.item.id }, parent: { $0.item.parent })
        return shown.compactMap { node -> RuntimeEntry? in
            let (pair, depth) = node
            let item = pair.item
            let call = pair.call
            guard let input = call.inputObject else { return nil }
            let title = input["name"] as? String
                ?? input["description"] as? String
                ?? call.summary
            let prompt = input["prompt"] as? String
            let children = childrenByParent[item.id] ?? []
            let process = children.reversed().compactMap { child -> String? in
                guard case .tool(let childCall) = child.kind, childCall.result == nil else { return nil }
                if childCall.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || childCall.name.caseInsensitiveCompare("Task") == .orderedSame {
                    return "Managing subagent"
                }
                return childCall.summary.isEmpty ? childCall.displayName : "\(childCall.displayName)  \(childCall.summary)"
            }.first ?? (call.result == nil ? "Working" : "Finished")
            let output = children.reversed().compactMap { child -> String? in
                switch child.kind {
                case .text(let text) where !text.isEmpty: return text
                case .tool(let childCall) where childCall.result?.isEmpty == false: return childCall.result
                case .notice(let text) where !text.isEmpty: return text
                default: return nil
                }
            }.first ?? call.result
            let elapsed = max(0, Int(now.timeIntervalSince(item.createdAt)))
            return RuntimeEntry(id: "agent-\(item.id)", kind: .agent,
                                title: title.isEmpty ? "Subagent" : title,
                                detail: call.isError ? "Failed" : call.result == nil ? "\(elapsed)s" : "Finished",
                                location: session.title, command: prompt,
                                prompt: prompt, output: output, process: process,
                                depth: depth, accentSeed: Self.seed(item.id),
                                agentID: session.engine.agent, modelName: (input["model"] as? String) ?? modelName(for: session),
                                paneId: nil, sessionId: session.id, autoReveal: true,
                                liveSince: call.result == nil ? item.createdAt : nil,
                                parentID: item.parent.map { "agent-" + $0 })
        }
    }

    private func modelName(for session: AgentSession) -> String {
        switch session.engine {
        case .claude:
            return AgentSession.model(session.model)?.title ?? friendlyModelName(session.model)
        case .codex:
            return CodexCatalogStore.shared.model(session.model)?.displayName ?? friendlyModelName(session.model)
        case .pi:
            return session.piModels.first(where: { $0.id == session.model || $0.modelId == session.model })?.name
                ?? friendlyModelName(session.model)
        case .opencode:
            return session.openCodeModel?.name ?? friendlyModelName(session.model)
        case .qwen:
            return friendlyModelName(session.model)
        }
    }

    private func friendlyModelName(_ raw: String) -> String {
        TwinStyle.shortModel(raw).replacingOccurrences(of: "-", with: " ")
    }

    private static func seed(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 5 }
    }

    private static func isShell(_ raw: String) -> Bool {
        let command = commandName(raw).lowercased()
        return ShellPrompt.shells.contains(command) || ShellPrompt.shells.contains("-" + command)
    }

    private static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

enum RuntimeKind: String, CaseIterable, Identifiable {
    case agent, task, monitor, shell
    var id: String { rawValue }
    var title: String { section.title }
    var singular: String { String(title.dropLast()) }
    var section: SidePanelSection {
        switch self {
        case .monitor: .monitors
        case .task: .tasks
        case .agent: .agents
        case .shell: .shells
        }
    }
    /// Said as a tooltip on a kind with nothing running.
    var emptyText: String {
        switch self {
        case .monitor: "No monitors. Builds and watchers the agent runs in the background show here."
        case .task: "No background tasks running."
        case .agent: "No subagents running. Ones this tab's agent starts show here."
        case .shell: "No shells started by the agent."
        }
    }
}

struct RuntimeEntry: Identifiable {
    let id: String
    let kind: RuntimeKind
    let title: String
    let detail: String
    let location: String
    let command: String?
    let prompt: String?
    let output: String?
    let process: String?
    var depth: Int
    let accentSeed: Int
    let agentID: String?
    let modelName: String?
    let paneId: String?
    var sessionId: String?
    /// Discovery can add account-wide background work to the requested panel,
    /// but only a child/event created by this tab's agent may open it.
    var autoReveal = false
    /// Still running since then: the row counts up each second in place of
    /// `detail`.
    var liveSince: Date? = nil
    /// The process behind it, when one can be named to stop.
    var pid: Int? = nil
    var parentID: String? = nil

    var state: RuntimeState { RuntimeState.classify(detail: detail) }

    var tint: Color {
        guard kind == .agent else {
            return kind == .monitor ? Theme.accent : kind == .task ? Theme.palette.color(\.syntaxBuiltin) : Theme.textSecondary
        }
        let colors = [Theme.palette.syntaxBuiltin, Theme.palette.syntaxFlag, Theme.palette.syntaxString,
                      Theme.palette.syntaxPath, Theme.palette.syntaxVariable]
        return Color(hex: colors[accentSeed % colors.count])
    }
}
