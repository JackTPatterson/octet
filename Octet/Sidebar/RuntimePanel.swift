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
            ui.runtimeExpandedEntryIDs = []
            reload()
        }
        .onChange(of: scopeID) { _, _ in
            // Details belong to one tab/conversation. Never let a row opened
            // in the previous scope stay open while the new list loads.
            withoutLayoutAnimation { ui.runtimeExpandedEntryIDs = [] }
            flashingEntryIDs = []
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

    /// One stack, so the modifiers on it run once, not per section.
    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 6) { runtimeList(entries) }
    }

    /// Every kind is a section, with 0 when it has nothing, so the page
    /// keeps its shape.
    private func runtimeList(_ current: [RuntimeEntry]) -> some View {
        ForEach(RuntimeKind.allCases) { kind in
            let rows = current.filter { $0.kind == kind }
            SidePanelSectionView(kind.section, count: rows.count) {
                if rows.isEmpty {
                    Text(kind.emptyText)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    section(kind, rows: rows)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                RuntimeRow(entry: row,
                           flashes: flashingEntryIDs.contains(row.id),
                           expanded: ui.runtimeExpandedEntryIDs.contains(row.id)) { toggle(row) }
                    .id(row.id)
            }
        }
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
            ui.sidePanelVisible = true
            ui.sidePanelAutoOpened = true
            ui.sidePanelTab = .overview
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
            result += (store.terminalRuntimes[pane.paneId] ?? []).map { runtime in
                entry(runtime, location: location, paneId: pane.paneId, session: nil)
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
                                           paneId: viewer.agent.paneId, autoReveal: true))
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
                                sessionId: sessionId, autoReveal: true)
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
                       session: AgentSession?, carried: Bool = false) -> RuntimeEntry {
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
                            process: carried ? "Moving from the terminal" : process, depth: 0,
                            accentSeed: Self.seed(runtime.id),
                            agentID: runtime.kind == .agent ? "claude" : nil,
                            modelName: runtime.kind == .agent ? session.map(modelName(for:)) : nil,
                            paneId: paneId, sessionId: session?.id, autoReveal: true)
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
            let hasProcess = executable.map { expected in
                (store.nativeRuntimeProcesses[session.id] ?? []).contains {
                    Self.commandName($0.name).caseInsensitiveCompare(expected) == .orderedSame
                }
            } ?? false
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
                                paneId: nil, sessionId: session.id, autoReveal: true)
        }
    }

    private func activeSubagents(in session: AgentSession) -> [RuntimeEntry] {
        guard session.conversation.isRunning else { return [] }
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
        var visible = Set(calls.filter { $0.call.result == nil && $0.item.createdAt >= started }.map { $0.item.id })
        // Keep the ownership chain visible even if an agent's launch call has
        // already returned while one of its descendants is still working.
        var frontier = Array(visible)
        while let id = frontier.popLast(), let parent = byId[id]?.item.parent,
              byId[parent] != nil, visible.insert(parent).inserted {
            frontier.append(parent)
        }

        return calls.compactMap { pair in
            let item = pair.item
            let call = pair.call
            guard visible.contains(item.id), let input = call.inputObject else { return nil }
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
            var depth = 0
            var parent = item.parent
            var visited = Set<String>()
            while let id = parent, let ancestor = byId[id], visited.insert(id).inserted {
                depth += 1
                parent = ancestor.item.parent
            }
            return RuntimeEntry(id: "agent-\(item.id)", kind: .agent,
                                title: title.isEmpty ? "Subagent" : title,
                                detail: call.result == nil ? "\(elapsed)s" : "Parent",
                                location: session.title, command: prompt,
                                prompt: prompt, output: output, process: process,
                                depth: depth, accentSeed: Self.seed(item.id),
                                agentID: session.engine.agent, modelName: modelName(for: session),
                                paneId: nil, sessionId: session.id, autoReveal: true)
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

private enum RuntimeKind: String, CaseIterable, Identifiable {
    case agent, task, monitor, shell
    var id: String { rawValue }
    var title: String { section.title }
    var section: SidePanelSection {
        switch self {
        case .monitor: .monitors
        case .task: .tasks
        case .agent: .agents
        case .shell: .shells
        }
    }
    var emptyText: String {
        switch self {
        case .monitor: "No monitors. Builds and watchers the agent runs in the background show here."
        case .task: "No background tasks running."
        case .agent: "No subagents running. Ones this tab's agent starts show here."
        case .shell: "No shells started by the agent."
        }
    }
}

private struct RuntimeEntry: Identifiable {
    let id: String
    let kind: RuntimeKind
    let title: String
    let detail: String
    let location: String
    let command: String?
    let prompt: String?
    let output: String?
    let process: String?
    let depth: Int
    let accentSeed: Int
    let agentID: String?
    let modelName: String?
    let paneId: String?
    var sessionId: String?
    /// Discovery can add account-wide background work to the requested panel,
    /// but only a child/event created by this tab's agent may open it.
    var autoReveal = false

    var tint: Color {
        guard kind == .agent else {
            return kind == .monitor ? Theme.accent : kind == .task ? Theme.palette.color(\.syntaxBuiltin) : Theme.textSecondary
        }
        let colors = [Theme.palette.syntaxBuiltin, Theme.palette.syntaxFlag, Theme.palette.syntaxString,
                      Theme.palette.syntaxPath, Theme.palette.syntaxVariable]
        return Color(hex: colors[accentSeed % colors.count])
    }
}

/// One runtime, as an accordion: the summary is always there, and a click
/// opens its details beneath it, inside the same card.
private struct RuntimeRow: View {
    let entry: RuntimeEntry
    let flashes: Bool
    let expanded: Bool
    let toggle: () -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.depth > 0 {
                Color.clear.frame(width: CGFloat(entry.depth - 1) * 12)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(entry.tint.opacity(0.72))
                    .frame(width: 22)
                    .padding(.top, 9)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                summary
                if expanded {
                    RuntimeDetails(entry: entry)
                        .transition(motion.animates(.sidebar)
                            ? .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
                            : .identity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(flashes ? entry.tint.opacity(0.22)
                        : expanded ? entry.tint.opacity(0.07)
                        : hovered ? Theme.hover : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(expanded ? entry.tint.opacity(0.42) : Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.55)), value: flashes)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.14)), value: hovered)
    }

    /// The row's always-visible line, which opens and closes it.
    private var summary: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                RuntimeGlyph(entry: entry, size: 14).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let modelName = entry.modelName, !modelName.isEmpty {
                            Text(modelName)
                                .font(Theme.captionFont)
                                .foregroundStyle(entry.tint)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(entry.detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Text(entry.location)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                OctetIcon("chevron.right", size: 11)
                    .foregroundStyle(expanded ? entry.tint : hovered ? Theme.textSecondary : Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(expanded ? "Hide details" : "Show details")
        .accessibilityLabel("\(entry.title), level \(entry.depth + 1), \(entry.detail), \(entry.location)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
    }
}

/// What a runtime row shows when open: its status, what it was asked or
/// runs, its latest output, and where it belongs.
private struct RuntimeDetails: View {
    let entry: RuntimeEntry
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(entry.tint.opacity(0.25)).frame(height: 1)
            if let paneId = entry.paneId, entry.kind == .agent {
                OctetButton(title: "Show Tab", kind: .secondary, compact: true) {
                    window.focusAgent(paneId: paneId)
                }
            }
            RuntimeDetailSection(title: "Status", tint: entry.tint) {
                HStack(spacing: 7) {
                    LoadingLine(width: 16, color: entry.tint)
                    Text(entry.process ?? (entry.kind == .monitor ? "Watching" : "Active"))
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            if let prompt = entry.prompt ?? entry.command, !prompt.isEmpty {
                RuntimeDetailSection(title: entry.kind == .agent ? "Assigned prompt" : "Command", tint: entry.tint) {
                    ExpandableText(text: prompt, font: entry.kind == .agent ? Theme.uiFont : Theme.monoFont)
                }
            }
            if let output = entry.output, !output.isEmpty {
                RuntimeDetailSection(title: "Latest output", tint: entry.tint) {
                    ExpandableText(text: output, font: Theme.uiFont)
                }
            }
            RuntimeDetailSection(title: "Context", tint: entry.tint) {
                VStack(alignment: .leading, spacing: 4) {
                    metadata("Session", entry.location)
                    metadata("Runtime", String(entry.kind.title.dropLast()))
                    if entry.kind == .agent { metadata("Hierarchy", "Level \(entry.depth + 1)") }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.textTertiary).frame(width: 62, alignment: .leading)
            Text(value).foregroundStyle(Theme.textPrimary).textSelection(.enabled).lineLimit(2)
        }
        .font(Theme.captionFont)
    }
}

private struct RuntimeDetailSection<Content: View>: View {
    let title: String
    let tint: Color
    let content: Content

    init(title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.35)
                .foregroundStyle(tint)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Long prompts and output start at a few lines, so one open row doesn't
/// push the rest of the list away; "Show all" opens the rest.
private struct ExpandableText: View {
    let text: String
    let font: Font
    static let collapsedLines = 6
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var showsAll = false

    private var isLong: Bool {
        text.count > 360 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= Self.collapsedLines
    }

    /// The opening lines, cut here rather than by a line limit: selectable
    /// text draws every line however few it was given room for, so a long
    /// prompt ran over the sections below it.
    private var collapsed: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.collapsedLines)
        var shown = lines.joined(separator: "\n")
        if shown.count > 360 { shown = String(shown.prefix(360)) }
        return shown.count < text.count ? shown.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsAll ? text : collapsed)
                .font(font)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button(showsAll ? "Show less" : "Show all") {
                    motion.perform(.sidebar, .smooth(duration: 0.2)) { showsAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

private struct RuntimeGlyph: View {
    let entry: RuntimeEntry
    let size: CGFloat

    var body: some View {
        Group {
            if entry.kind == .monitor {
                Image(systemName: "eye")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(entry.tint)
            } else if entry.kind == .task {
                OctetIcon("clock.arrow.circlepath", size: size).foregroundStyle(entry.tint)
            } else if entry.kind == .agent, let brand = AgentBrand.forAgent(entry.agentID) {
                AgentLogo(brand: brand, size: size)
            } else if entry.kind == .agent {
                OctetIcon("tool.agent", size: size).foregroundStyle(entry.tint)
            } else {
                OctetIcon("terminal", size: size).foregroundStyle(entry.tint)
            }
        }
        .accessibilityHidden(true)
    }
}
