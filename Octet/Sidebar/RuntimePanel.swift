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
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var seen = RuntimeSeenStore.shared
    /// The entries, built once per change (not per redraw), and the scan's clock.
    @StateObject private var model: RuntimeModel
    @State private var flashingEntryIDs: Set<String> = []
    @State private var collapsedBranches: Set<String> = []
    /// Groups opened or closed by hand, over their defaults.
    @State private var groupOverrides: [String: Bool] = [:]
    /// Groups whose "Finished" fold is open.
    @State private var openFolds: Set<String> = []
    @AppStorage("agentsTab.scope") private var scopeModeRaw = RuntimeModel.Scope.Mode.workspace.rawValue
    @AppStorage("agentsTab.showsShells") private var showsShells = false
    @AppStorage("agentsTab.compactRows") private var compactRows = false
    @AppStorage("agentsTab.groupByKind") private var groupByKind = false
    @AppStorage("agentsTab.showsFinished") private var showsFinished = true
    /// The header's bucket filter: only what needs you, or is working, or done.
    @State private var bucketFilter: AgentState.Bucket?
    /// The needs-you card whose reply field is open.
    @State private var replying: String?
    @State private var showsAllNeeds = false
    /// The row the keyboard acts on; the pointer moves it too.
    @State private var selectedID: String?
    /// The row whose whole output is open in a sheet.
    @State private var outputEntry: RuntimeEntry?
    @FocusState private var listFocused: Bool
    private var scopeMode: RuntimeModel.Scope.Mode { RuntimeModel.Scope.Mode(rawValue: scopeModeRaw) ?? .workspace }
    /// Counts auto-close timers, so only the latest one closes the panel.
    @State private var autoCloseGeneration = 0
    /// How long a panel that opened itself stays open when not hovered.
    private static let autoCloseAfter: TimeInterval = 3

    init(store: SessionStore, ui: UIState) {
        self.store = store
        self.ui = ui
        _model = StateObject(wrappedValue: RuntimeModel(store: store))
    }

    private var entries: [RuntimeEntry] { model.entries }
    private var workspaceId: String? { window.focusedWorkspace?.workspaceId }
    private var activeSession: AgentSession? { model.activeSession }
    private var scopeID: String? {
        if let activeSession { return "conversation:\(activeSession.id)" }
        return window.displayedFocusedTabId.map { "tab:\($0)" }
    }
    private var scope: RuntimeModel.Scope {
        RuntimeModel.Scope(workspaceId: workspaceId, tabId: window.displayedFocusedTabId,
                           focusedPaneId: window.focusedPaneId, mode: scopeMode)
    }

    var body: some View {
        runtimeContent
        .sheet(item: $outputEntry) { entry in
            RuntimeOutputSheet(entry: entry) { outputEntry = nil }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear {
            model.setScope(scope)
            model.start()
            model.setPanelVisible(ui.sidePanelVisible)
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
        }
        .onDisappear { model.stop() }
        .onChange(of: model.groups) { _, _ in markVisibleRead() }
        .onReceive(NotificationCenter.default.publisher(for: RuntimePanel.nextNeedingYou)) { _ in
            // The palette's "Agents Tab: Next Needing You", in the window in front.
            guard window.isKey || WindowRegistry.shared.key === window,
                  let row = navigableRows.first(where: { $0.state.needsYou || $0.state == .planReady }) else { return }
            selectedID = row.id
            listFocused = true
        }
        .onChange(of: needsYou.map(\.id)) { old, new in
            // Said to VoiceOver when something new needs you.
            if let added = needsYou.first(where: { !old.contains($0.id) }), new.count >= old.count {
                AttentionRouter.announce("\(added.title) needs you")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in markVisibleRead() }
        .onChange(of: scope) { _, scope in model.setScope(scope) }
        .onChange(of: ui.sidePanelVisible) { _, visible in
            model.setPanelVisible(visible)
            markVisibleRead()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.debugSampleChanged)) { _ in model.rebuildNow() }
        .onChange(of: workspaceId) { _, _ in
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            flashingEntryIDs = []
            collapsedBranches = []
            groupOverrides = [:]
            openFolds = []
            ui.runtimeExpandedEntryIDs = []
        }
        .onChange(of: scopeID) { _, _ in
            // Details belong to one tab/conversation. Never let a row opened
            // in the previous scope stay open while the new list loads.
            // activateWorkspacePanel has usually emptied it already; writing
            // it again would redraw the window for nothing.
            if !ui.runtimeExpandedEntryIDs.isEmpty {
                withoutLayoutAnimation { ui.runtimeExpandedEntryIDs = [] }
            }
            flashingEntryIDs = []
            collapsedBranches = []
            ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            revealNewEntries(ids)
            let open = ui.runtimeExpandedEntryIDs
            if !open.isSubset(of: ids) { ui.runtimeExpandedEntryIDs = open.intersection(ids) }
        }
        .onChange(of: entries.isEmpty, initial: true) { _, empty in
            ui.runtimeHasEntries = !empty
        }
    }

    /// Asks the conversation `sessionId` to scroll to the transcript item
    /// `itemId` (a subagent's launch), after the panel has gone to it.
    /// ConversationView answers it.
    static let scrollToConversationItem = Notification.Name("octet.conversation.scrollToItem")

    /// Posted by the palette's "Agents Tab: Next Needing You": the window in
    /// front selects the first row waiting on you.
    static let nextNeedingYou = Notification.Name("octet.agentsTab.nextNeedingYou")

    /// The debug sample was switched on: rebuild with it.
    static let debugSampleChanged = Notification.Name("octet.agentsTab.debugSampleChanged")

    #if DEBUG
    nonisolated(unsafe) static var debugSample = false
    /// ":sample:<variant>": "empty" shows nothing running, "partial" only
    /// subagents and shells; anything else is the full set.
    nonisolated(unsafe) static var debugVariant: String?

    /// The made-up rows' states, by what they say.
    private static func sampleState(_ detail: String) -> AgentState {
        switch detail {
        case "Needs input": .needsInput
        case "Failed": .failed
        case "Finished": .done
        default: .working
        }
    }

    /// Made-up subagents, background tasks, monitors and shells.
    static var sampleEntries: [RuntimeEntry] {
        func entry(_ id: String, _ kind: RuntimeKind, _ title: String, _ detail: String, location: String = "Fix the upload retry",
                   command: String? = nil, prompt: String? = nil, output: String? = nil, process: String? = nil,
                   depth: Int = 0, seed: Int = 0, agent: String? = nil, model: String? = nil,
                   since: TimeInterval? = nil, pid: Int? = nil, pane: String? = nil) -> RuntimeEntry {
            RuntimeEntry(id: id, kind: kind, title: title, detail: detail, location: location, command: command,
                         prompt: prompt, output: output, process: process, depth: depth, accentSeed: seed,
                         agentID: agent, modelName: model, paneId: pane,
                         liveSince: since.map { Date().addingTimeInterval(-$0) }, pid: pid, parentID: id == "s1a" || id == "s1b" ? "s1" : nil,
                         state: Self.sampleState(detail), exitCode: detail == "Failed" ? 2 : nil)
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

    /// One stack, so the modifiers on it run once, not per group.
    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            needsYouStrip
            let groups = filteredGroups
            if PlaneLoadingPreview.shows("overview") {
                OverviewRowsSkeleton(rows: 2, tree: true).padding(Theme.Space.md)
            } else if model.groups.isEmpty {
                emptyState
            } else if groups.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Nothing matches this filter").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                    OctetButton(title: "Show All", kind: .ghost, compact: true) { bucketFilter = nil }
                }
                .padding(Theme.Space.xl)
            } else if groupByKind {
                kindSections(groups)
            } else {
                let defaults = RuntimeGrouping.initiallyExpanded(groups.map(\.id), focused: groups.first(where: \.focused)?.id)
                ForEach(groups) { group in
                    groupView(group, expanded: groupOverrides[group.id] ?? defaults.contains(group.id))
                }
            }
            if !model.folder.isEmpty {
                SidePanelSectionView(.folder, count: model.folder.count) {
                    section(.agent, rows: model.folder.filter { !seen.isDismissed($0) })
                }
            }
        }
        .animation(motion.animation(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)), value: model.groups.map(\.id))
    }

    /// Groups, and the rows in them, narrowed to the header's bucket.
    private var filteredGroups: [RuntimeGroup] {
        guard let bucketFilter else { return model.groups }
        return model.groups.compactMap { group in
            let rows = group.entries.filter { $0.state.bucket == bucketFilter }
            guard group.rootState.bucket == bucketFilter || !rows.isEmpty else { return nil }
            return RuntimeGroup(id: group.id, title: group.title, agentID: group.agentID, rootState: group.rootState,
                                state: group.state, paneId: group.paneId, sessionId: group.sessionId, tabId: group.tabId,
                                contextFraction: group.contextFraction, entries: rows, recency: group.recency,
                                focused: group.focused, loading: group.loading)
        }
    }

    /// The header: what needs you, what's working, what's done (each a
    /// filter), the scope, and the view menu.
    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            // "2 need you · 9 working · 1 done" where it fits; a coloured dot
            // and the count where it doesn't, never cut to "2 need…".
            ViewThatFits(in: .horizontal) {
                bucketCounts(short: false)
                bucketCounts(short: true)
            }
            .font(Theme.Text.captionMedium)
            .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            OctetSegmented(selection: Binding(get: { scopeMode }, set: { scopeModeRaw = $0.rawValue }),
                           items: [(.workspace, "Workspace"), (.tab, "This tab")])
                .fixedSize()
            OctetIconButton(icon: "ellipsis", help: "View options", compact: true) {
                OctetContextMenu.present(viewMenu)
            }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, Theme.Space.md)
    }

    private func bucketCounts(short: Bool) -> some View {
        let parts = RuntimeCount.buckets(model.groups.flatMap { [$0.rootState] + $0.entries.filter { $0.kind != .shell }.map(\.state) })
        return HStack(spacing: short ? Theme.Space.md : Theme.Space.sm) {
            ForEach(Array(parts.enumerated()), id: \.element.label) { index, part in
                if index > 0, !short { Text("·").foregroundStyle(Theme.textMuted).accessibilityHidden(true) }
                let color = part.bucket == .working ? Theme.textSecondary : part.state.color
                Button {
                    bucketFilter = bucketFilter == part.bucket ? nil : part.bucket
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        if short { Circle().fill(color).frame(width: 6, height: 6) }
                        Text(short ? "\(part.count)" : "\(part.count) \(part.label)")
                            .monospacedDigit()
                            .foregroundStyle(color)
                            .underline(bucketFilter == part.bucket)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help(short ? "\(part.count) \(part.label)" : bucketFilter == part.bucket ? "Show everything" : "Show only these")
                .accessibilityLabel("\(part.count) \(part.label)")
                .accessibilityAddTraits(bucketFilter == part.bucket ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var viewMenu: [OctetMenuItem] {
        func check(_ on: Bool) -> String? { on ? "checkmark" : nil }
        let finished = model.groups.flatMap(\.entries).filter { ($0.state == .done || $0.state == .failed) && !seen.isDismissed($0) }
        return [
            .action("Group by Agent", icon: check(!groupByKind)) { groupByKind = false },
            .action("Group by Kind", icon: check(groupByKind)) { groupByKind = true },
            .divider,
            .action("Show Finished", icon: check(showsFinished)) { showsFinished.toggle() },
            .action("Show Shells", icon: check(showsShells)) { showsShells.toggle() },
            .action("Compact Rows", icon: check(compactRows)) { compactRows.toggle() },
            .divider,
            .action("Mark All Read", icon: "checkmark.circle", enabled: finished.contains(where: seen.isUnread)) {
                seen.markRead(finished)
            },
            .action("Clear Finished", icon: "xmark.bin", enabled: !finished.isEmpty) { clearFinished(finished) },
        ]
    }

    /// What waits on you, above everything: a root or a subagent asking for
    /// approval or input, or with a plan to read. Each says what it wants,
    /// and opens or answers in place.
    @ViewBuilder private var needsYouStrip: some View {
        let needs = needsYou
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(showsAllNeeds ? needs : Array(needs.prefix(3))) { item in
                    RuntimeAttentionCard(item: item, replying: replying == item.id,
                                         reply: item.send == nil ? nil : {
                                             motion.perform(.sidebar) { replying = replying == item.id ? nil : item.id }
                                         },
                                         send: { text in
                                             item.send?(text)
                                             replying = nil
                                             ToastCenter.shared.info("Sent to \(item.title)")
                                         })
                }
                if needs.count > 3 {
                    OctetButton(title: showsAllNeeds ? "Show fewer" : "+\(needs.count - 3) more", kind: .ghost, compact: true) {
                        motion.perform(.sidebar) { showsAllNeeds.toggle() }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
        }
    }

    /// Roots and subagents waiting on you, loudest first.
    private var needsYou: [RuntimeAttentionItem] {
        var items: [RuntimeAttentionItem] = []
        for group in model.groups {
            let groupState = group.rootState
            if groupState.needsYou || groupState == .planReady {
                let session = group.sessionId.flatMap { id in AgentCenter.shared.sessions.first { $0.id == id } }
                var detail: String?
                if let session {
                    if let permission = session.pendingPermission {
                        detail = permission.toolName == "ExitPlanMode" ? "Wants to go ahead with its plan" : "Asks to use \(permission.toolName)"
                    } else {
                        detail = session.pendingQuestion != nil ? "Has a question for you" : session.lastReplyPreview
                    }
                } else if let pane = group.paneId {
                    detail = store.snapshot.agents.first { $0.paneId == pane }?.terminalId.flatMap { store.usageTracker.lastActivity[$0] }
                }
                let hub = AgentsHubList.agents(store: store).first { $0.id == group.id }
                let store = store
                items.append(RuntimeAttentionItem(
                    id: group.id, title: group.title, agentID: group.agentID, state: groupState, detail: detail,
                    open: { focusGroup(group) },
                    send: hub.flatMap { agent in agent.canSend ? { agent.send($0, store: store) } : nil }))
            }
            for entry in group.entries where entry.state.needsYou || entry.state == .planReady {
                let paneId = entry.paneId
                let store = store
                items.append(RuntimeAttentionItem(
                    id: entry.id, title: entry.title, agentID: entry.agentID, state: entry.state,
                    detail: entry.process ?? RuntimeText.firstLine(of: entry.output),
                    open: {
                        if let paneId { window.focusAgent(paneId: paneId) } else { focusGroup(group) }
                    },
                    send: paneId.map { pane in { text in Self.sendToPane(text, pane: pane, name: entry.title, store: store) } }))
            }
        }
        return items.sorted { $0.state.priority > $1.state.priority }
    }

    /// A prompt to the agent in a pane, as the hub and other Macs send one.
    private static func sendToPane(_ text: String, pane: String, name: String, store: SessionStore) {
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = Broadcast.deliver(text, to: [.init(paneId: pane, name: name, isAgent: true)]) { method, params in
                _ = try client.call(method, params)
            }
            if !failed.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { ToastCenter.shared.fail(nil, "Couldn't send to \(name)") } }
            }
        }
    }

    /// Group by Kind: every root's subagents, then background tasks, then
    /// monitors.
    @ViewBuilder
    private func kindSections(_ groups: [RuntimeGroup]) -> some View {
        let all = groups.flatMap(\.entries).filter { entry in
            !seen.isDismissed(entry) && (showsFinished || !((entry.state == .done || entry.state == .failed) && !seen.isUnread(entry)))
        }
        ForEach([RuntimeKind.agent, .task, .monitor]) { kind in
            let rows = all.filter { $0.kind == kind }
            if !rows.isEmpty {
                SidePanelSectionView(kind.section, count: rows.count) {
                    section(kind == .agent ? .agent : .task, rows: rows)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(scopeMode == .tab ? "No agents in this tab" : "No agents in this workspace")
                .font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
            Text("Start one and its subagents, background tasks and output show here.")
                .font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OctetButton(title: "New Agent", icon: "plus", kind: .secondary, compact: true) {
                window.newConversation(engine: .claude)
            }
            .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.xl)
    }

    /// A root agent's header, then (open) its tree, its background work, its
    /// shells on one line, and what has finished folded away at the end.
    @ViewBuilder
    private func groupView(_ group: RuntimeGroup, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            RuntimeGroupHeader(group: group, expanded: expanded,
                               focus: { focusGroup(group) },
                               toggle: {
                                   motion.perform(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)) {
                                       groupOverrides[group.id] = !expanded
                                   }
                               },
                               menu: { groupMenu(group) },
                               treeID: expanded ? Self.treeRootID(group) : nil)
            if expanded {
                groupBody(group)
                    .transition(motion.animates(.sidebar) ? .opacity : .identity)
            }
        }
        .treeEdges()
        .padding(.horizontal, Theme.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([group.title, group.state.title, group.summary].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Finished and read: into the fold. Unread stays out until seen.
    private func foldedIDs(_ work: [RuntimeEntry]) -> Set<String> {
        RuntimeGrouping.finished(work.map {
            .init(id: $0.id, parent: $0.parentID,
                  finished: ($0.state == .done || $0.state == .failed) && !seen.isUnread($0))
        })
    }

    @ViewBuilder
    private func groupBody(_ group: RuntimeGroup) -> some View {
        let shells = group.entries.filter { $0.kind == .shell }
        let work = group.entries.filter { $0.kind != .shell && !seen.isDismissed($0) }
        let folded = foldedIDs(work)
        let main = work.filter { !folded.contains($0.id) }
        let finished = work.filter { folded.contains($0.id) }
        if group.loading {
            OverviewRowsSkeleton(rows: 2, tree: true).padding(.leading, Theme.Space.xl)
        } else if work.isEmpty {
            Text("No subagents or background work")
                .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 30).padding(.vertical, Theme.Space.xs)
        } else {
            // Everything it started hangs off the root agent's mark in the
            // header, a vertical tree down to the deepest.
            groupTree(group, agents: main.filter { $0.kind == .agent },
                      background: main.filter { $0.kind == .task || $0.kind == .monitor })
        }
        if showsShells, !shells.isEmpty {
            Text("Shells: " + shells.map(\.title).joined(separator: ", "))
                .font(Theme.Text.micro).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 30).padding(.vertical, Theme.Space.xxs)
        }
        if showsFinished, !finished.isEmpty {
            let open = openFolds.contains(group.id)
            Button {
                motion.perform(.sidebar) { if open { openFolds.remove(group.id) } else { openFolds.insert(group.id) } }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    OctetIcon(open ? "chevron.down" : "chevron.right", size: 9)
                    Text("Finished (\(finished.count))")
                }
                .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 30).padding(.vertical, Theme.Space.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            // The group's edges cover these too: no layer of their own.
            if open { rowList(shownRows(.agent, rows: finished), all: finished, root: nil) }
        }
    }

    /// Hides a group's finished rows, with a way back (Orca's Clear completed).
    private func clearFinished(_ entries: [RuntimeEntry]) {
        let ids = entries.map(\.id)
        seen.dismiss(entries)
        ToastCenter.shared.info("Cleared \(ids.count) finished", action: ToastCenter.Action(title: "Undo") {
            RuntimeSeenStore.shared.restore(ids)
        })
    }

    /// What's on screen in the group in front is read: finishing while you
    /// watch isn't news (Warp's rule).
    private func markVisibleRead() {
        guard ui.sidePanelVisible, NSApp.isActive,
              let front = model.groups.first(where: \.focused) else { return }
        let defaults = RuntimeGrouping.initiallyExpanded(model.groups.map(\.id), focused: front.id)
        guard groupOverrides[front.id] ?? defaults.contains(front.id) else { return }
        seen.markRead(front.entries)
    }

    /// Goes to the root: its pane, or its conversation.
    private func focusGroup(_ group: RuntimeGroup) {
        guard let workspaceId else { return }
        if let session = group.sessionId {
            window.focusWorkspace(workspaceId)
            AgentCenter.shared.setActive(session, in: workspaceId)
        } else if let pane = group.paneId {
            AgentCenter.shared.setActive(nil, in: workspaceId)
            window.focusAgent(paneId: pane)
        }
    }

    private func groupMenu(_ group: RuntimeGroup) -> [OctetMenuItem] {
        var items: [OctetMenuItem] = [.action("Focus", icon: "arrow.right.square") { focusGroup(group) }]
        let finished = group.entries.filter { ($0.state == .done || $0.state == .failed) && !seen.isDismissed($0) }
        if finished.contains(where: seen.isUnread) {
            items.append(.action("Mark All Read", icon: "checkmark") { seen.markRead(group.entries) })
        }
        if !finished.isEmpty {
            items.append(.action("Clear Finished", icon: "xmark.bin") { clearFinished(finished) })
        }
        items.append(.divider)
        items.append(.action("Open in Agents Hub", icon: "brain") {
            AgentCenter.shared.setBoard(.all, in: workspaceId)
        })
        return items
    }

    /// Where Jump goes for a row: its own pane (a subagent in a tab of its
    /// own, an agent in a terminal), else its root agent.
    private func jump(for row: RuntimeEntry) -> (() -> Void)? {
        if let paneId = row.paneId, row.kind == .agent { return { window.focusAgent(paneId: paneId) } }
        guard let group = model.groups.first(where: { $0.id == row.rootID }) else { return nil }
        // A conversation's own subagent or task: to the call that started it.
        let item = ["agent-", "task-", "monitor-"].first(where: row.id.hasPrefix).map { String(row.id.dropFirst($0.count)) }
        return {
            focusGroup(group)
            guard let item, let session = row.sessionId else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: RuntimePanel.scrollToConversationItem, object: nil,
                                                userInfo: ["sessionId": session, "itemId": item])
            }
        }
    }

    private func toggleRead(_ row: RuntimeEntry) {
        if seen.isUnread(row) { seen.markRead([row]) } else { seen.markUnread(row) }
    }

    /// Every row the keyboard can reach, in the order drawn.
    private var navigableRows: [RuntimeEntry] {
        let groups = filteredGroups
        if groupByKind {
            let all = groups.flatMap(\.entries).filter { entry in
                !seen.isDismissed(entry) && (showsFinished || !((entry.state == .done || entry.state == .failed) && !seen.isUnread(entry)))
            }
            return shownRows(.agent, rows: all.filter { $0.kind == .agent })
                + shownRows(.task, rows: all.filter { $0.kind == .task })
                + shownRows(.task, rows: all.filter { $0.kind == .monitor })
        }
        let defaults = RuntimeGrouping.initiallyExpanded(groups.map(\.id), focused: groups.first(where: \.focused)?.id)
        var rows: [RuntimeEntry] = []
        for group in groups where groupOverrides[group.id] ?? defaults.contains(group.id) {
            let work = group.entries.filter { $0.kind != .shell && !seen.isDismissed($0) }
            let folded = RuntimeGrouping.finished(work.map {
                .init(id: $0.id, parent: $0.parentID,
                      finished: ($0.state == .done || $0.state == .failed) && !seen.isUnread($0))
            })
            let main = work.filter { !folded.contains($0.id) }
            rows += shownRows(.agent, rows: main.filter { $0.kind == .agent })
            rows += shownRows(.task, rows: main.filter { $0.kind == .task || $0.kind == .monitor })
            if showsFinished, openFolds.contains(group.id) {
                rows += shownRows(.agent, rows: work.filter { folded.contains($0.id) })
            }
        }
        return rows
    }

    /// The tab's keys, as the hub's: arrows move and fold, Return jumps,
    /// Space opens, ⌘. stops, R reads, ⌫ dismisses, ⌘C copies output.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let rows = navigableRows
        guard !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == selectedID }
        let row = index.map { rows[$0] }
        func select(_ offset: Int) {
            guard let index else { selectedID = (offset > 0 ? rows.first : rows.last)?.id; return }
            selectedID = rows[min(rows.count - 1, max(0, index + offset))].id
        }
        switch press.key {
        case .downArrow: select(1); return .handled
        case .upArrow: select(-1); return .handled
        case .rightArrow:
            guard let row else { return .ignored }
            if collapsedBranches.contains(row.id) {
                motion.perform(.sidebar) { _ = collapsedBranches.remove(row.id) }
            } else if !ui.runtimeExpandedEntryIDs.contains(row.id) { toggle(row) }
            return .handled
        case .leftArrow:
            guard let row else { return .ignored }
            if ui.runtimeExpandedEntryIDs.contains(row.id) {
                toggle(row)
            } else if rows.contains(where: { $0.parentID == row.id }), !collapsedBranches.contains(row.id) {
                motion.perform(.sidebar) { _ = collapsedBranches.insert(row.id) }
            } else if let parent = row.parentID, rows.contains(where: { $0.id == parent }) {
                selectedID = parent
            }
            return .handled
        case .return:
            guard let row, let jump = jump(for: row) else { return .ignored }
            jump()
            return .handled
        case .space:
            guard let row else { return .ignored }
            toggle(row)
            return .handled
        case .delete:
            guard let row, row.state == .done || row.state == .failed else { return .ignored }
            select(1)
            seen.dismiss([row])
            return .handled
        default:
            break
        }
        guard let row else { return .ignored }
        let command = press.modifiers.contains(.command)
        switch press.characters.lowercased() {
        case "." where command:
            guard row.pid != nil, row.state.bucket != .done, row.kind != .shell else { return .ignored }
            stop(row)
            return .handled
        case "c" where command:
            guard let output = row.output, !output.isEmpty else { return .ignored }
            copy(output)
            return .handled
        case "r" where !command:
            guard row.state == .done || row.state == .failed else { return .ignored }
            toggleRead(row)
            return .handled
        default:
            return .ignored
        }
    }

    /// Stops the process behind a row.
    private func stop(_ entry: RuntimeEntry) {
        guard let pid = entry.pid else { return }
        if kill(pid_t(pid), SIGTERM) != 0, errno != ESRCH {
            ToastCenter.shared.fail(nil, "Couldn't stop \(entry.title)", detail: String(cString: strerror(errno)))
        } else {
            ToastCenter.shared.info("Stopped \(entry.title)")
            model.reload()
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
        items.append(.divider)
        if let command = entry.command ?? entry.prompt, !command.isEmpty {
            items.append(.action(entry.kind == .agent ? "Copy prompt" : "Copy command", icon: "doc.on.doc") { copy(command) })
        }
        if let output = entry.output, !output.isEmpty {
            items.append(.action("Open output", icon: "arrow.up.left.and.arrow.down.right") { outputEntry = entry })
            items.append(.action("Copy latest output", icon: "doc.on.doc") { copy(output) })
        }
        if let jump = jump(for: entry) {
            items.insert(.action(entry.paneId != nil ? "Jump to tab" : "Jump to conversation", icon: "arrow.right.square", jump), at: 1)
        }
        if entry.state == .done || entry.state == .failed {
            items.append(.divider)
            if seen.isUnread(entry) {
                items.append(.action("Mark read", icon: "checkmark") { seen.markRead([entry]) })
            } else {
                items.append(.action("Mark unread", icon: "circle.dot") { seen.markUnread(entry) })
            }
            items.append(.action("Dismiss", icon: "xmark") { seen.dismiss([entry]) })
        }
        if entry.pid != nil, entry.state.bucket != .done {
            items.append(.divider)
            items.append(.action("Stop", icon: "xmark.octagon", destructive: true) { stop(entry) })
        }
        return items
    }

    /// Opens or closes a row in place.
    private func toggle(_ entry: RuntimeEntry) {
        selectedID = entry.id
        listFocused = true
        motion.perform(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)) {
            if ui.runtimeExpandedEntryIDs.contains(entry.id) {
                ui.runtimeExpandedEntryIDs.remove(entry.id)
            } else {
                ui.runtimeExpandedEntryIDs.insert(entry.id)
                // Opening a row is reading it.
                seen.markRead([entry])
            }
        }
    }

    private func withoutLayoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    /// A section's rows in drawing order, with folded branches left out.
    /// `rooted`: the rows hang off the group's header, one level in.
    private func shownRows(_ kind: RuntimeKind, rows: [RuntimeEntry], rooted: Bool = false) -> [RuntimeEntry] {
        let ordered: [RuntimeEntry] = kind == .agent
            ? treeOrdered(Self.louderFirst(rows), rooted: rooted)
            : rows.map { entry in var row = entry; row.depth = rooted ? 1 : 0; return row }
        return foldedAway(ordered)
    }

    /// Louder first (needs you, then working, then done), keeping each
    /// branch's own order; the tree then keeps children under parents.
    private static func louderFirst(_ rows: [RuntimeEntry]) -> [RuntimeEntry] {
        rows.enumerated().sorted { a, b in
            let (x, y) = (a.element.state, b.element.state)
            if x.bucket != y.bucket { return x.bucket < y.bucket }
            if x.priority != y.priority { return x.priority > y.priority }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Children under their parents, each a level in; ancestry holds even
    /// when process discovery returns children first.
    private func treeOrdered(_ rows: [RuntimeEntry], rooted: Bool) -> [RuntimeEntry] {
        RuntimeTree.order(rows, id: { $0.id }, parent: { $0.parentID }).map { entry, depth in
            var row = entry; row.depth = depth + (rooted ? 1 : 0); return row
        }
    }

    /// Leaves out the rows inside folded branches.
    private func foldedAway(_ ordered: [RuntimeEntry]) -> [RuntimeEntry] {
        let visible = AgentPresentationLogic.visibleIDs(ordered.map { (id: $0.id, depth: $0.depth) }, collapsed: collapsedBranches)
        return ordered.filter { visible.contains($0.id) }
    }

    private func section(_ kind: RuntimeKind, rows: [RuntimeEntry]) -> some View {
        rowList(shownRows(kind, rows: rows), all: rows, root: nil)
            .treeEdges()
    }

    /// A root agent's work as one tree hanging off its header: its
    /// subagents (however deep), then its background tasks and monitors.
    /// The group draws the edges, so they reach its header.
    private func groupTree(_ group: RuntimeGroup, agents: [RuntimeEntry], background: [RuntimeEntry]) -> some View {
        // One tree: a subagent's own background tasks sit under it, after
        // its subagents, rather than after every subagent with an edge
        // reaching back over them all. Tasks of the root agent come last.
        rowList(foldedAway(treeOrdered(Self.louderFirst(agents) + background, rooted: true)),
                all: agents + background, root: Self.treeRootID(group))
    }

    static func treeRootID(_ group: RuntimeGroup) -> String { "group:" + group.id }

    /// Rows in drawing order. Each names the mark its edge comes from: its
    /// parent's when that's shown, else the tree's root (the group header).
    private func rowList(_ shown: [RuntimeEntry], all rows: [RuntimeEntry], root: String?) -> some View {
        let shownIDs = Set(shown.map(\.id))
        return VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                RuntimeRow(entry: row,
                           flashes: flashingEntryIDs.contains(row.id),
                           expanded: ui.runtimeExpandedEntryIDs.contains(row.id),
                           toggle: { toggle(row) },
                           focus: jump(for: row),
                           stop: row.pid != nil && row.state.bucket != .done && row.kind != .shell ? { stop(row) } : nil,
                           menu: { menu(for: row) },
                           childCount: rows.filter { $0.parentID == row.id }.count,
                           compactRows: compactRows,
                           unread: seen.isUnread(row),
                           selected: selectedID == row.id,
                           select: { selectedID = row.id },
                           markRead: row.state == .done || row.state == .failed ? { toggleRead(row) } : nil,
                           copyOutput: row.output?.isEmpty == false ? { copy(row.output ?? "") } : nil,
                           openOutput: row.output?.isEmpty == false ? { outputEntry = row } : nil,
                           branchCollapsed: collapsedBranches.contains(row.id),
                           toggleBranch: {
                               motion.perform(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)) {
                                   if !collapsedBranches.insert(row.id).inserted { collapsedBranches.remove(row.id) }
                               }
                           },
                           treeParent: row.parentID.flatMap { shownIDs.contains($0) ? $0 : nil } ?? root,
                           treeOrder: index)
                    .id(row.id)
                    .transition(motion.animates(.sidebar) ? Self.rowTransition : .identity)
            }
        }
        .animation(motion.animation(.sidebar, .spring(response: 0.32, dampingFraction: 0.86)), value: shown.map(\.id))
    }

    /// A row rises into place as its edge draws out to it, and sinks away
    /// as the edge pulls back (AffectUI's agent tree).
    private static let rowTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98, anchor: .top))
            .animation(.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.36)),
        removal: .opacity.combined(with: .offset(y: 4)).combined(with: .scale(scale: 0.97, anchor: .top))
            .animation(.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.28)))

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

struct RuntimeEntry: Identifiable, Equatable {
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
    /// The group (root agent) it sits under.
    var rootID: String? = nil
    /// Where it stands, set by whatever built the row from real signals
    /// (a call's error and result, the session server's status), never
    /// read back from `detail`, which is only for showing.
    var state: AgentState = .working
    /// A finished background command's exit code, when its output said.
    var exitCode: Int? = nil
    /// When it started, and when it finished (roughly: its last word).
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    /// A subagent's own plan, as a meter.
    var todos: TodoMeter? = nil

    var tint: Color {
        guard kind == .agent else {
            return kind == .monitor ? Theme.accent : kind == .task ? Theme.palette.color(\.syntaxBuiltin) : Theme.textSecondary
        }
        let colors = [Theme.palette.syntaxBuiltin, Theme.palette.syntaxFlag, Theme.palette.syntaxString,
                      Theme.palette.syntaxPath, Theme.palette.syntaxVariable]
        return Color(hex: colors[accentSeed % colors.count])
    }
}
