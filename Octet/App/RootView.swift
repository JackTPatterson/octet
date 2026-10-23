import SwiftUI

/// Window layout: title bar, sidebar, tab bar, and the session terminal.
struct RootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let session: EngineSession?
    @ObservedObject var prompt: PromptEditor
    @ObservedObject var twin: TwinSession
    var embedded = false
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var confirmations = ConfirmCenter.shared
    /// Held, not observed: it changes with every cursor move, and observing
    /// it here redrew the whole window (sidebar included) as output streamed.
    /// What draws from it observes it itself (FocusedGridReader, overlays).
    @State private var paneGeometry = PaneGeometry()
    @StateObject private var splash = NewTabSplashModel()
    @ObservedObject private var pathPicker = PathPickerCenter.shared
    @StateObject private var statusBar = StatusBarModel()
    @StateObject private var liveScroll = LiveScrollWatcher()
    /// The terminal client went away (a crash, the session server stopping):
    /// offer it back rather than quitting.
    @State private var terminalDisconnected = false
    /// When the disconnected card last reconnected, to tell a retry that failed.
    @State private var lastReconnect: Date?
    /// The connection card over the terminal, while it shows.
    @State private var connecting: SSHTarget?
    @ObservedObject private var tabDrag = TabDrag.shared
    @ObservedObject private var recapCenter = RecapCenter.shared
    /// The last terminal failure shown, so a repeat isn't shown again.
    private static var lastFailure: (message: String, at: Date)?
    /// The panes of the tab showing, fetched when a tab drag starts.
    /// A tab's panes fetched when a drag began, for when the snapshot has none.
    @State private var dropLayout: (tab: String, layout: PaneLayout)?
    /// How far a tab beside the terminal, on its left or above, pushes it
    /// from where it would start: what's drawn over the terminal from the
    /// root moves with it.
    @State private var terminalOffset: CGSize = .zero
    @ObservedObject private var agents = AgentCenter.shared
    @ObservedObject private var offers = AgentOfferCenter.shared
    @ObservedObject private var waitCenter = WaitCenter.shared
    @ObservedObject private var checkInCenter = CheckInCenter.shared
    /// This window: what it shows, and how it moves.
    @EnvironmentObject private var window: WindowContext

    /// The agents board over this window's terminal, if one is up.
    private var boardHere: AgentCenter.Board? { agents.board(in: window.focusedWorkspace?.workspaceId) }

    /// Where the terminal starts across the window.
    private var sidebarInset: CGFloat { ui.sidebarVisible ? ui.sidebarWidth + 1 : 0 }
    private var windowHeight: CGFloat { NSApp.keyWindow?.contentView?.bounds.height ?? 800 }
    private var windowWidth: CGFloat { NSApp.keyWindow?.contentView?.bounds.width ?? 1200 }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let _ = RenderCounter.note("RootView")
        Group {
            if embedded { embeddedWorkspaceSurface }
            else { layered }
        }
        .octetDropdownHost(window.chromeDropdowns)
        // Choosing files and folders, in Octet's own picker.
        .overlay { PathPickerHost(window: window.nsWindow) }
        .animation(.easeOut(duration: 0.15), value: pathPicker.request?.id)
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlay("palette", visible)
            if visible {
                store.refreshPlugins()
                palette.reset()
                palette.projectPaths = ProjectDirectories.list()
                let items = PaletteCatalog.items(window: window, projectPaths: palette.projectPaths)
                palette.reload(items: items)
                if let query = ui.paletteQuery {
                    ui.paletteQuery = nil
                    palette.query = query
                }
                // Opened for one action (a menu shortcut): go straight to it.
                if let start = ui.paletteStart {
                    ui.paletteStart = nil
                    if let item = start.lazy.compactMap({ id in items.first { $0.id == id } }).first {
                        _ = palette.activate(item)
                    } else {
                        ui.paletteVisible = false
                        if start.first?.hasPrefix("action.broadcast") == true {
                            ToastCenter.shared.info("Nothing to broadcast to", detail: "Start an agent, or split the tab into panes.")
                        } else {
                            ToastCenter.shared.info("That isn't available here")
                        }
                    }
                }
            } else {
                OctetTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: store.plugins) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(window: window, projectPaths: palette.projectPaths))
            }
        }
        .onChange(of: window.focusedPaneId) { _, _ in twin.snapshotChanged() }
        .onReceive(paneGeometry.$panes) { liveScroll.follow($0) }
        // Process discovery lands after the first grid reading. Recheck once
        // the shell is recognized so an untouched initial tab gets its splash.
        .onChange(of: window.focusedPaneAtPrompt) { _, _ in observeSplash(paneGeometry.focusedGrid) }
        // The engine went away under a working window; streams reconnect on
        // their own once it's back.
        .onChange(of: store.isConnected) { was, now in
            if was, !now { terminalDisconnected = true } else if now { terminalDisconnected = false }
        }
        .onChange(of: twin.isVisible) { _, visible in DebugSnapshot.overlay("twin", visible) }
        .onChange(of: window.editor.isPresented) { _, visible in
            if visible { window.containerLogs.activeID = nil }
            DebugSnapshot.overlay("editor", visible)
        }
        .onChange(of: agents.active(in: window.focusedWorkspace?.workspaceId)?.id) { _, id in
            if id != nil { window.containerLogs.activeID = nil }
        }
        .onChange(of: window.focusedWorkspace?.workspaceId, initial: true) { _, id in
            if embedded {
                ui.activateWorkspacePanel(id)
                if let parent = window.splitParent, parent.panelContext === window {
                    parent.ui.activateWorkspacePanel(id, preserveWindowState: true)
                }
            } else if window.panelContext === window {
                ui.activateWorkspacePanel(id, preserveWindowState: window.splitContext != nil)
            }
            window.migrateContainerLogPlanes()
        }
        .onChange(of: window.editor.filePickerVisible) { _, visible in DebugSnapshot.overlay("editor-picker", visible) }
        .onChange(of: settings.values.agentQuickAnswers) { _, _ in twin.snapshotChanged() }
        .onChange(of: store.snapshot) { _, snapshot in
            twin.snapshotChanged()
            if !snapshot.workspaces.isEmpty {
                AgentCenter.shared.restoreIfNeeded(
                    workspaceFor: { cwd in snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == cwd }?.workspaceId },
                    fallback: window.focusedWorkspace?.workspaceId
                )
            }
            // Snapshots come in bursts while agents work: one rebuild for
            // each quarter second, checked again when it runs.
            if ui.paletteVisible, palette.prompt == nil {
                palette.reloadSoon { [ui, palette, window] in
                    guard ui.paletteVisible, palette.prompt == nil else { return nil }
                    return PaletteCatalog.items(window: window, projectPaths: palette.projectPaths)
                }
            }
        }
        .background(settings.values.effectiveBackgroundOpacity < 1 ? Color.clear : Theme.terminalBackground)
        .background(WindowTransparency(
            opacity: settings.values.effectiveBackgroundOpacity,
            blur: settings.values.effectiveBackgroundBlur,
            themeName: settings.themeKey
        ))
        .ignoresSafeArea()
        .preferredColorScheme(Theme.colorScheme)
    }

    /// The window's layout with everything drawn over it; `body` adds what
    /// it reacts to. Two halves so the compiler can check each in time.
    /// The agent to offer Octet's view for: one running in its own interface
    /// in the tab showing, while the terminal is what's showing.
    private var agentOffer: EngineAgent? {
        guard settings.values.agentBanner, !twin.isVisible, boardHere == nil, window.activeContainerLog == nil,
              coveringConversation == nil,
              let tab = window.displayedFocusedTabId else { return nil }
        return AgentOffer.candidate(in: store.snapshot.agents(inTab: tab), dismissed: offers.dismissed)
    }

    /// The folder the focused pane is working in, for the repository bar.
    private var focusedPaneCwd: String? {
        guard let pane = window.focusedPaneId else { return nil }
        // A subagent's tab follows the subagent into its worktree.
        return store.snapshot.workingDirectory(ofPane: pane)
    }

    /// The agent running in the focused pane, if any.
    private var focusedAgent: EngineAgent? {
        guard let pane = window.focusedPaneId else { return nil }
        return store.snapshot.agents.first { $0.paneId == pane }
    }

    /// The Claude Code session in the focused pane, for its Remote Control
    /// chip: the session, where it runs, and its process.
    private var focusedClaude: FocusedClaude? {
        guard let agent = focusedAgent, AgentBrand.forAgent(agent.agent)?.id == "claude",
              let sessionId = store.recovery.sessionId(of: agent),
              let cwd = agent.cwd ?? focusedPaneCwd else { return nil }
        let pid = window.focusedProcess?.foreground.first { AgentBrand.forAgent(($0.name as NSString).lastPathComponent)?.id == "claude" }?.pid
        return FocusedClaude(sessionId: sessionId, cwd: cwd, pid: pid)
    }

    /// The machine the focused pane is logged into over SSH, if any.
    private var focusedSSH: SSHTarget? {
        window.focusedPaneId.flatMap { store.paneSSH[$0] }
    }

    /// A new connection in the focused pane gets the card; one that was
    /// already open when Octet started, or that focus merely moved to, doesn't.
    private func sshChanged(from old: [String: SSHTarget], to new: [String: SSHTarget]) {
        guard store.sshScans > 1, let pane = window.focusedPaneId, let target = new[pane], old[pane] != target,
              motion.animates(.connections) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { connecting = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard connecting == target else { return }
            withAnimation(.easeIn(duration: 0.25)) { connecting = nil }
        }
    }

    /// Where the terminal begins, under the title bar, tab bar and any banner.
    private var contentTop: CGFloat {
        Theme.titleBarHeight + Theme.tabBarHeight + (agentOffer == nil ? 0 : AgentOfferBanner.height)
    }

    private func turnOffAgentBanner() {
        settings.values.agentBanner = false
        ToastCenter.shared.info("Banner turned off", detail: "Settings › Agents & Recovery brings it back.")
    }

    private var layered: some View {
        VStack(spacing: 0) {
            // Chrome views are re-identified per theme so every color
            // re-resolves; the terminal keeps its identity (and its session client).
            TitleBar(store: store, ui: ui)
                .id(settings.themeKey)
            HStack(spacing: 0) {
                if ui.sidebarVisible {
                    HStack(spacing: 0) {
                        SidebarView(store: store, width: ui.sidebarWidth)
                        Rectangle().fill(Theme.divider).frame(width: 1)
                            .overlay { SidebarResizeHandle(ui: ui) }
                    }
                    .id(settings.themeKey)
                    .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        workspaceSurfaces
                            .overlay {
                                if let dragged = tabDrag.workspaceId {
                                    WorkspaceDropLayer(workspaceId: dragged, window: window,
                                                       animation: motion.animation(.tabs, .smooth(duration: 0.15)))
                                }
                            }
                        // Room for the panel, which draws over it from the overlay.
                        // It changes at once, never animated: the terminal then
                        // resizes and reflows its text one time, while the panel
                        // slides in over the room, instead of reflowing on every
                        // frame of the slide.
                        Color.clear
                            .frame(width: ui.sidePanelVisible && !ui.sidePanelMaximized ? ui.presentedSidePanelWidth : 0)
                            .transaction { $0.animation = nil }
                    }
                    // The right panel: a strip of planes over the one in front.
                    // In an overlay so that maximized it covers the terminal
                    // rather than squeezing it: a terminal resized to nothing
                    // reflows every agent's screen.
                    .overlay(alignment: .trailing) {
                        GeometryReader { proxy in
                            let width = ui.sidePanelMaximized ? proxy.size.width : min(proxy.size.width, ui.presentedSidePanelWidth)
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Theme.divider).frame(width: 1)
                                    .frame(maxHeight: .infinity, alignment: .leading)
                                // Not built until first opened: a panel left
                                // closed costs nothing at launch.
                                if ui.sidePanelEverShown {
                                    SidePanel(store: store, ui: ui)
                                        .environmentObject(window.panelContext)
                                        .frame(width: width - 1)
                                        .padding(.leading, 1)
                                }
                                if !ui.sidePanelMaximized { SidePanelResizeHandle(ui: ui) }
                            }
                            .frame(width: width, alignment: .leading)
                            .clipped()
                            .offset(x: ui.sidePanelVisible ? 0 : width)
                            .animation(motion.animation(.sidebar), value: ui.sidePanelVisible)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                ui.availablePanelWidth = width
                            }
                        }
                        .allowsHitTesting(ui.sidePanelVisible)
                        .accessibilityHidden(!ui.sidePanelVisible)
                    }
                    if settings.values.repoContextBar {
                        StatusBar(model: statusBar, store: store, ui: ui, ssh: focusedSSH, agent: focusedAgent,
                                  openOnOctetUI: { window.openOnOctetUI($0) })
                    }
                }
            }
            // Their drags are off under a page, which would otherwise lose
            // its own presses to the tab or card beneath.
            .environment(\.octetDragSourcesCovered, ui.settingsVisible || ui.marketplaceVisible || ui.usageBreakdownVisible
                         || ui.pullRequests != nil || boardHere != nil)
            // Settings as a page over the sidebar and content, as T3 Code's.
            .overlay {
                if ui.settingsVisible {
                    SettingsView(store: store, onClose: {
                        MotionPreferences.shared.perform(.palette, .easeOut(duration: 0.15)) { ui.settingsVisible = false }
                        OctetTerminalRuntime.focusTerminal()
                    })
                    .background(Theme.terminalBackground)
                    .transition(motion.animates(.palette) ? .opacity : .identity)
                    .onAppear { DebugSnapshot.overlay("settings", true) }
                    .onDisappear { DebugSnapshot.overlay("settings", false) }
                } else if ui.marketplaceVisible, let marketplace = MarketplaceWindow.store {
                    // The Marketplace too: a page of its own over everything.
                    MarketplaceView(store: marketplace, close: {
                        MotionPreferences.shared.perform(.palette, .easeOut(duration: 0.15)) { ui.marketplaceVisible = false }
                        OctetTerminalRuntime.focusTerminal()
                    })
                    .transition(motion.animates(.palette) ? .opacity : .identity)
                    .onAppear { DebugSnapshot.overlay("marketplace", true) }
                    .onDisappear { DebugSnapshot.overlay("marketplace", false) }
                } else if ui.usageBreakdownVisible {
                    // Pages about every workspace (Settings, Marketplace, Usage,
                    // Pull Requests, Agents) cover the sidebar and the tabs;
                    // a workspace's own (its review, a conversation, the
                    // editor) sits under them, in the terminal's place.
                    UsagePage {
                        MotionPreferences.shared.perform(.palette, .easeOut(duration: 0.15)) { ui.usageBreakdownVisible = false }
                        OctetTerminalRuntime.focusTerminal()
                    }
                    .transition(motion.animates(.palette) ? .opacity : .identity)
                    .onAppear { DebugSnapshot.overlay("usage", true) }
                    .onDisappear { DebugSnapshot.overlay("usage", false) }
                } else if let pullRequests = ui.pullRequests {
                    PullRequestsPage(model: pullRequests, store: store) { window.togglePullRequests() }
                        .transition(motion.animates(.palette) ? .opacity : .identity)
                        .onAppear { DebugSnapshot.overlay("pullRequests", true) }
                        .onDisappear { DebugSnapshot.overlay("pullRequests", false) }
                } else if boardHere != nil {
                    AgentsHub(store: store)
                        .background(Theme.terminalBackground)
                        .transition(motion.animates(.palette) ? .opacity : .identity)
                        .onAppear { DebugSnapshot.overlay("agents", true) }
                        .onDisappear { DebugSnapshot.overlay("agents", false) }
                }
            }
            .animation(motion.animation(.palette, .easeOut(duration: 0.15)), value: boardHere)
        }
        .overlay(alignment: .topTrailing) {
            AgentBannerStack(center: AgentBannerCenter.shared) { event in
                window.focus(event)
            }
            .padding(.top, contentTop)
        }
        .overlay(alignment: .top) {
            // Only the window in front shows it, once.
            if let recap = recapCenter.shown, recapCenter.showsIn(window) {
                RecapStrip(recap: recap)
                    .padding(.top, contentTop + 10)
                    .transition(motion.animates(.toasts) ? .move(edge: .top).combined(with: .opacity) : .identity)
            }
        }
        .animation(motion.animation(.toasts, .smooth(duration: 0.22)), value: recapCenter.shown)
        .animation(motion.animation(.toasts, .smooth(duration: 0.18)), value: recapCenter.expanded)
        .onAppear { appeared() }
        .modifier(TerminalWatchers(
            geometry: paneGeometry, tabDrag: tabDrag,
            focusedTab: window.displayedFocusedTabId, promptEmpty: prompt.line.text.isEmpty,
            observe: observeSplash, dragChanged: { loadDropLayout(dragging: $0) }
        ))
        .onChange(of: store.lastError) { _, error in
            guard let error else { return }
            store.lastError = nil
            // The same failure again soon after is the same news: once.
            let now = Date()
            if let last = Self.lastFailure, last.message == error, now.timeIntervalSince(last.at) < 60 { return }
            Self.lastFailure = (error, now)
            ToastCenter.shared.fail(nil, "Terminal request failed", detail: error)
        }
        .onChange(of: confirmations.request?.id) { _, id in DebugSnapshot.overlay("confirmation", id != nil) }
        // Hide the engine's chrome before drawing the prompt and completions;
        // bottom anchoring can move this cover through the completion menu.
        .overlay(alignment: .topLeading) { promptOverlay }
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        : .identity)
            }
        }
        .overlay {
            if ui.shortcutsVisible {
                ShortcutsCheatSheet { ui.shortcutsVisible = false }
                    .transition(motion.animates(.palette) ? .opacity : .identity)
            }
        }
        .animation(motion.animation(.palette, .easeOut(duration: 0.15)), value: ui.shortcutsVisible)
        .overlay {
            if window.editor.filePickerVisible {
                EditorFilePickerView(rootDirectory: window.editorRootDirectory, workspace: window.editor)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        : .identity)
            }
        }
        // Draw transient cards after the terminal chrome cover and prompt.
        // The hosted terminal needs those root overlays, but neither should
        // be able to paint a black strip through a toast or quick answer.
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                ToastStack(center: ToastCenter.shared)
                AgentQuickAnswerHost(
                    center: agents,
                    terminal: window.terminalQuestions,
                    frontTabId: window.displayedFocusedTabId,
                    workspaceId: window.focusedWorkspace?.workspaceId
                )
                RecoveryOverlay(center: store.recoveryCenter)
            }
            .id(settings.themeKey)
        }
        // A wait being written, in the window that asked for it.
        .sheet(item: Binding(
            get: { waitCenter.draft.flatMap { $0.windowId == nil || $0.windowId == window.id ? $0 : nil } },
            set: { if $0 == nil { waitCenter.draft = nil } })) { draft in
            WaitEditorSheet(draft: draft) { waitCenter.draft = nil }
                .environmentObject(window)
        }
        // A check-in being written, in the window that asked for it.
        .sheet(item: Binding(
            get: { checkInCenter.draft.flatMap { $0.windowId == nil || $0.windowId == window.id ? $0 : nil } },
            set: { if $0 == nil { checkInCenter.draft = nil } })) { draft in
            CheckInEditorSheet(draft: draft) { checkInCenter.draft = nil }
                .environmentObject(window)
        }
        // Above the palette, so a confirm raised while it's open isn't buried.
        .modifier(RootDialogHosts(ui: ui, store: store, confirmations: confirmations))
        .modifier(RootAnimations(ui: ui, boardShowing: boardHere != nil))
        .onAppear {
            window.todos.attach(window)
            window.projectAgent.attach(window)
            window.git.attach(window)
            window.pluginPanels.attach(window)
            window.terminalQuestions.attach(window)
        }
    }

    @ViewBuilder
    private var primaryWorkspaceSurface: some View {
        if window.editor.isPresented, window.editor.presentation == .split {
            HSplitView {
                terminalWorkspaceSurface.frame(minWidth: 260)
                CodeEditorView(workspace: window.editor, rootDirectory: window.editorRootDirectory,
                               revealFolder: revealInFiles)
                    .frame(minWidth: 260)
                    .simultaneousGesture(TapGesture().onEnded { window.activateSplitSurface() })
            }
        } else {
            terminalWorkspaceSurface
        }
    }

    private var terminalWorkspaceSurface: some View {
        VStack(spacing: 0) {
            TabBarView(store: store, ui: ui, focusOwner: window.splitParent ?? window).id(settings.themeKey)
            if let offer = agentOffer {
                AgentOfferBanner(agent: offer,
                                 open: { window.continueInOctet(offer) },
                                 dismiss: { offers.dismiss(offer) }, never: turnOffAgentBanner)
                    .id(AgentOffer.key(offer))
            }
            terminal.overlay { terminalOverlay }
                .overlay {
                    if terminalDisconnected && window.activeContainerLog == nil {
                        TerminalDisconnectedCard(
                            serverReachable: store.isConnected,
                            retryFailed: lastReconnect.map { Date().timeIntervalSince($0) < 10 } ?? false
                        ) {
                            lastReconnect = Date()
                            terminalDisconnected = false
                            session?.ensureServer()
                            store.scheduleRefresh()
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if ui.detailsVisible { DetailsCard(model: statusBar, store: store, ui: ui).padding(12) }
                }
                .animation(motion.animation(.sidebar, .easeOut(duration: 0.15)), value: ui.detailsVisible)
            TerminalDrawerHost(store: store, ui: ui)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { window.activateSplitSurface() })
    }

    @ViewBuilder
    private var workspaceSurfaces: some View {
        if let split = window.splitContext {
            let other = RootView(store: store, ui: split.ui, session: session, prompt: prompt,
                                 twin: split.twin, embedded: true)
                .environmentObject(split)
                .frame(minWidth: 260, minHeight: 220)
            let primary = primaryWorkspaceSurface.frame(minWidth: 260, minHeight: 220)
            if window.splitEdge == .top || window.splitEdge == .bottom {
                VSplitView {
                    if window.splitEdge == .top { other; primary }
                    else { primary; other }
                }
            } else {
                HSplitView {
                    if window.splitEdge == .left { other; primary }
                    else { primary; other }
                }
            }
        } else {
            primaryWorkspaceSurface
        }
    }

    private var embeddedWorkspaceSurface: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabBarView(store: store, ui: ui, focusOwner: window.splitParent ?? window, embedded: true)
                OctetIconButton(icon: "rectangle.on.rectangle", help: "Split workspace options", compact: true) {
                    OctetContextMenu.present([
                        .action("Move to New Window", icon: "rectangle.on.rectangle") { window.splitParent?.detachWorkspaceSplit() },
                        .action("Close Split", icon: "xmark") { window.splitParent?.closeWorkspaceSplit() }
                    ])
                }
                .frame(width: 32, height: Theme.tabBarHeight)
            }
            contentArea
            TerminalDrawerHost(store: store, ui: ui)
        }
        .background(Theme.terminalBackground)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { window.activateSplitSurface() })
        .onAppear {
            window.todos.attach(window)
            window.projectAgent.attach(window)
            window.git.attach(window)
            window.pluginPanels.attach(window)
            window.terminalQuestions.attach(window)
        }
        .modifier(TerminalWatchers(
            geometry: paneGeometry, tabDrag: tabDrag,
            focusedTab: window.displayedFocusedTabId, promptEmpty: prompt.line.text.isEmpty,
            observe: observeSplash, dragChanged: loadDropLayout
        ))
    }

    /// Once the window is up: the marketplace opener, clipboard watching, and
    /// the DEBUG verification hooks that open things without a click.
    #if DEBUG
    /// The key hook runs once, however many times a window appears.
    private static var debugKeysPressed = false
    private static var debugResizeStormed = false
    private static var debugHotkeyPressed = false
    #endif

    private func appeared() {
            MarketplaceWindow.opener = { openWindow(id: MarketplaceWindow.id) }
            HuggingFaceWindow.opener = { openWindow(id: HuggingFaceWindow.id) }
            PluginSettingsOpener.opener = { openSettings() }
            SettingsOpener.fallback = { openSettings() }
            ClipboardWatcher.shared.start()
            OctetContextMenu.installAppWide()
            #if DEBUG
            // Verification hook: "notch", "notch:collapsed", "notch:peek", "notch:tab=<name>".
            NotchDebug.runHook()
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "workspace-split",
               !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let cwd = ProcessInfo.processInfo.environment["OCTET_SPLIT_PREVIEW_CWD"]
                        ?? FileManager.default.currentDirectoryPath
                    store.call("workspace.create", ["focus": false, "cwd": cwd],
                               failure: "Couldn't preview the workspace split") { created in
                        guard let workspaceId = created.workspaceId else { return }
                        window.splitWorkspace(workspaceId, at: .right)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "tab-split",
               !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let workspaceId = window.focusedWorkspace?.workspaceId else { return }
                    store.call("tab.create", ["workspace_id": workspaceId, "focus": false],
                               failure: "Couldn't preview the tab split") { created in
                        guard let tabId = created.tabId else { return }
                        WindowActions.splitTab(tabId, beside: window, at: .right)
                    }
                }
            }
            // Verification hook: "conversation" opens a native conversation;
            // "conversation:model" also opens that dropdown.
            if let window = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], window.hasPrefix("conversation") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let parts = window.split(separator: ":").map(String.init)
                    ConversationDebug.openDropdown = parts.dropFirst().first
                    ConversationDebug.scrollToItem = parts.count > 2 ? Int(parts[2]) : nil
                    self.window.newConversation()
                }
            }
            // Verification hook: an engine name opens its native conversation;
            // "pi:<text>" also sends that first message.
            if let window = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"],
               window.hasPrefix("codex") || window.hasPrefix("opencode") || window.hasPrefix("pi") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let engine: AgentSession.Engine = window.hasPrefix("opencode") ? .opencode
                        : window.hasPrefix("pi") ? .pi : .codex
                    self.window.newConversation(engine: engine)
                    let text = window.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
                    guard let text, let session = AgentCenter.shared.sessions.last else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.send(text) }
                    // Verification hook: an OpenCode question, as the server sends one.
                    guard ProcessInfo.processInfo.environment["OCTET_OPENCODE_QUESTION"] != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        session.openCodeEvent(["type": "question.asked", "properties": [
                            "id": "que_debug", "sessionID": session.threadId ?? "",
                            "questions": [
                                ["header": "Database", "question": "Which database should the new service use?",
                                 "options": [["label": "Postgres", "description": "Matches the other services"],
                                             ["label": "SQLite", "description": "Simplest to run locally"]]],
                                ["header": "Extras", "question": "Anything else to set up?", "multiple": true,
                                 "options": [["label": "Migrations", "description": ""], ["label": "Seed data", "description": ""]]],
                            ],
                        ] as [String: Any]])
                    }
                }
            }
            // "arrange:<n>" picks the nth monitor arrangement, to watch new windows open.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("arrange:"),
               !Self.debugHotkeyPressed, let index = Int(open.dropFirst(8)) {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let screens = NSScreen.screens
                    let current = window.nsWindow?.screen.flatMap { screens.firstIndex(of: $0) } ?? 0
                    let all = MonitorArrangement.across(screens.map(\.visibleFrame), current: current)
                    if all.indices.contains(index) { PaneLayoutActions.arrange(all[index].frames, from: window) }
                }
            }
            // "newwindow" opens a plain new window, as ⌘N does.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "newwindow", !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { WindowActions.newWindow(store: store) }
            }
            // Verification hook: "peek" opens a second tab, then the first
            // workspace's hover card; "peek:<folder>" first cd's there.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open == "peek" || open.hasPrefix("peek:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.newTab() }
                if open.hasPrefix("peek:") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        window.runInFocusedPane("cd " + shellQuote(String(open.dropFirst(5))))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    NotificationCenter.default.post(name: WorkspacePeek.debugOpen, object: nil)
                }
            }
            // "rclick:<x>:<y>" right-clicks that point of the window (from
            // its top left), through the same path a real right-click takes.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("rclick:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let parts = open.split(separator: ":").dropFirst().compactMap { Double($0) }
                    guard parts.count == 2, let nsWindow = window.nsWindow,
                          let content = nsWindow.contentView else { return }
                    let location = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
                    let screen = nsWindow.convertPoint(toScreen: location)
                    guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: nsWindow.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    OctetContextMenu.openSystemMenu(for: event, at: screen)
                }
            }
            // "context-menu" opens the focused workspace's menu beside the
            // sidebar; "context-menu:<title>" also opens that submenu.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("context-menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard let workspace = window.focusedWorkspace, let frame = window.nsWindow?.frame else { return }
                    OctetContextMenu.present(WorkspaceMenu.items(store: store, workspace: workspace, window: window) {},
                                             at: NSPoint(x: frame.minX + 180, y: frame.maxY - 220))
                    let title = open.split(separator: ":").dropFirst().first.map(String.init)
                    if let title, let model = OctetContextMenu.debugModel,
                       let item = model.items.first(where: { $0.title == title }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.activate(item, level: 0) }
                    }
                }
            }
            // Verification hook: "newtab" opens a tab, to see its splash.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "newtab" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.newTab() }
            }
            // Presses keys in the terminal: OCTET_DEBUG_KEYS="a a shift+return b",
            // after OCTET_DEBUG_KEYS_AFTER seconds (default 10).
            if let keys = ProcessInfo.processInfo.environment["OCTET_DEBUG_KEYS"], !Self.debugKeysPressed {
                Self.debugKeysPressed = true
                let delay = Double(ProcessInfo.processInfo.environment["OCTET_DEBUG_KEYS_AFTER"] ?? "") ?? 10
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { OctetTerminalRuntime.debugPress(keys) }
            }
            #if DEBUG
            // Verification: OCTET_DEBUG_RESIZE_STORM=<seconds> resizes the
            // window 30 times, 30ms apart, as a fast drag does, then back.
            if let after = ProcessInfo.processInfo.environment["OCTET_DEBUG_RESIZE_STORM"].flatMap(Double.init),
               !Self.debugResizeStormed {
                Self.debugResizeStormed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    guard let nsWindow = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
                    let original = nsWindow.frame
                    for step in 0...30 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.03) {
                            var frame = original
                            if step < 30 { frame.size.width = 900 + CGFloat((step * 97) % 500) }
                            nsWindow.setFrame(frame, display: true)
                        }
                    }
                }
            }
            #endif
            // "bestofn:<task>" starts a best-of-N task in the focused workspace.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("bestofn:"),
               !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if let workspace = window.focusedWorkspace {
                        BestOfNCenter.shared.start(task: String(open.dropFirst(8)), in: workspace.workspaceId, store: store)
                    }
                }
            }
            // "popup" or "popup:<command>" opens the popup terminal.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("popup"),
               !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    PopupTerminal.open(open.hasPrefix("popup:") ? String(open.dropFirst(6)) : nil, store: store)
                }
            }
            // "hotkey" presses the global hotkey after 4 s, and again after 8 s.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "hotkey", !Self.debugHotkeyPressed {
                Self.debugHotkeyPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { GlobalHotkey.shared.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { GlobalHotkey.shared.toggle() }
            }
            // "hints" shows hint labels as ⌘⇧H does; "hints:<label>" also types one.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("hints") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    HintsSession.start(window: window)
                    if open.hasPrefix("hints:") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            ui.hints?.type(String(open.dropFirst(6)), copy: false, window: window)
                        }
                    }
                }
            }
            // "queue:<text>" queues a prompt for the agent in the focused pane.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("queue:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let pane = store.keyPaneId
                    if let agent = store.snapshot.agents.first(where: { $0.paneId == pane }) {
                        PromptQueueCenter.shared.add(String(open.dropFirst(6)), for: agent, name: "the agent", store: store)
                    }
                }
            }
            // "type-all" turns on typing into every pane of the tab, as ⌥⌘I does.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "type-all" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if !BroadcastMode.shared.isOn { BroadcastMode.shared.toggle(window: window) }
                }
            }
            // "find:<text>" finds text in the focused pane's output.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("find:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    window.findOutput(.showFindInterface)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.outputFind.debugFind(String(open.dropFirst(5))) }
                }
            }
            // "palette" opens the command palette as ⌘P does.
            // "project-search" opens Search in Project; "project-search:<text>"
            // with that typed (OCTET_SEARCH_ROOT: in that folder). "snooze-picker" opens Pick a Time… for the
            // workspace in front.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("project-search") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    ProjectSearchCenter.shared.open(in: window, query: open.hasPrefix("project-search:") ? String(open.dropFirst(15)) : nil,
                                                    root: ProcessInfo.processInfo.environment["OCTET_SEARCH_ROOT"])
                }
            }
            // "checkin-sample" fills the sidebar with made-up check-ins (nothing is
            // saved or scheduled); "checkin-composer" opens the sheet for a new one.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("checkin") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { CheckInDebug.open(open, window: window) }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "snooze-picker" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let workspace = window.focusedWorkspace { SnoozePickerCenter.shared.ask(store: store, workspaceId: workspace.workspaceId) }
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "palette" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ui.paletteVisible = true }
            }
            // "broadcast" opens the broadcast prompt as ⌘⇧I does.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "broadcast" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    ui.paletteStart = ["action.broadcast.workspace", "action.broadcast.everywhere", "action.broadcast.tab"]
                    ui.paletteVisible = true
                }
            }
            // "review" opens the changes review over the focused pane.
            // "review:<folder>" opens it on that folder instead.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("review") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if open.hasPrefix("review:") { ui.review = DiffReviewModel(directory: String(open.dropFirst(7))) }
                    else { window.toggleReview() }
                }
            }
            // "pull-requests" opens the Pull Requests page as the palette
            // does; "pull-requests:project" opens it on the focused folder,
            // and "pull-requests:<text>" with that search typed.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("pull-requests") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let argument = open.hasPrefix("pull-requests:") ? String(open.dropFirst(14)) : ""
                    window.togglePullRequests(scope: argument == "project" ? .project : .all)
                    if !argument.isEmpty, argument != "project" { ui.pullRequests?.queryText = argument }
                }
            }
            // Verification hook: "planes:empty" closes every plane (the
            // launcher), "planes:max" maximizes the panel, "planes:pr" or
            // "planes:pr:12" opens a pull request, "planes:prs" the list.
            // Append ":loading" to any kind (or details) to hold its skeleton.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("planes:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let parts = open.split(separator: ":").map(String.init)
                    switch parts.dropFirst().first {
                    case "empty": ui.closePlanes { _ in true }; ui.sidePanelVisible = true
                    case "max": ui.sidePanelVisible = true; ui.sidePanelMaximized = true
                    case "pr", "pullRequest":
                        #if DEBUG
                        // "planes:pr:sample" shows made-up stacked pull requests; nothing reads GitHub.
                        if parts.count > 2, parts[2] == "sample" { PullRequestPlaneModel.debugSample = true }
                        #endif
                        ui.showPlane(.pullRequest, number: parts.count > 2 ? Int(parts[2]) : nil)
                    case "prs", "pullRequests": ui.showPlane(.pullRequests)
                    case "todos":
                        ui.showPlane(.todos)
                        // ":sample:empty|partial|linked|done" for the other states.
                        if parts.count > 2, parts[2] == "sample" { window.todos.loadSample(variant: parts.count > 3 ? parts[3] : nil) }
                    case "overview":
                        ui.showPlane(.overview)
                        #if DEBUG
                        // ":sample" fills it with made-up work, to see it populated.
                        if parts.count > 2, parts[2] == "sample" {
                            RuntimePanel.debugSample = true
                            let variant = parts.count > 3 ? parts[3] : nil
                            RuntimePanel.debugVariant = variant
                            window.todos.loadSample(variant: variant)
                            if variant != "empty" { window.projectAgent.loadSample() }
                            // The panel may have built before the flag was set.
                            NotificationCenter.default.post(name: RuntimePanel.debugSampleChanged, object: nil)
                        }
                        #endif
                    case "git":
                        // "planes:git" opens the Git plane; ":sample" fills it
                        // with made-up checkouts, ":sample:open" with every
                        // folded section unfolded. Nothing reads a repository.
                        ui.showPlane(.git)
                        #if DEBUG
                        if parts.count > 2, parts[2] == "sample" { window.git.loadSample(opened: parts.count > 3) }
                        #endif
                    case "diff": ui.showPlane(.diff)
                    case "files": ui.showPlane(.files)
                    case "browser": ui.showPlane(.browser)
                    case "terminal": ui.showPlane(.terminal)
                    case "ci": ui.showPlane(.ci)
                    case "containers": ui.showPlane(.containers)
                    case "tickets": ui.showPlane(.tickets)
                    case "details": ui.detailsVisible = true
                    case "device":
                        // "planes:device:<id>" opens straight onto that device.
                        if parts.count > 2, parts[2] != "loading" {
                            let plane = Plane.make(.device, deviceId: parts[2...].joined(separator: ":"))
                            ui.planes.append(plane)
                            ui.activePlaneId = plane.id
                            ui.sidePanelVisible = true
                        } else {
                            ui.showPlane(.device)
                        }
                    case "devicefloat" where parts.count > 2 && DeviceFloat.debugClaimHook():
                        // "planes:devicefloat:<id>" opens that device, then
                        // hides the panel once it streams, which floats it.
                        let plane = Plane.make(.device, deviceId: parts[2...].joined(separator: ":"))
                        ui.planes.append(plane)
                        ui.activePlaneId = plane.id
                        ui.sidePanelVisible = true
                        DeviceFloat.debugWhenStreaming(planeId: plane.id) { ui.sidePanelVisible = false }
                    default: break
                    }
                }
            }
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("settings") {
                // "settings" or "settings:appearance" (a section's raw value).
                if open.hasPrefix("settings:") {
                    UserDefaults.standard.set(String(open.dropFirst(9)), forKey: SettingsView.sectionKey)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ui.settingsVisible = true }
            }
            // "update-preview" shows the update dialog with sample notes;
            // ":checking", ":downloading" or ":ready" opens it at that stage.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("update-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    OctetUpdateDriver.showPreview(stage: open.split(separator: ":").dropFirst().first.map(String.init))
                }
            }
            // "agent-updates-preview" shows the agent updates dialog with
            // sample updates; updating plays out sample results, never a
            // command. ":run" starts updating at once.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("agent-updates-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    AgentUpdateCenter.shared.showPreview(stage: open.split(separator: ":").dropFirst().first.map(String.init))
                }
            }
            // "recovery-preview" shows the recovery panel with sample rows
            // (":restoring", ":done", ":history" or ":empty" for that state).
            // Restoring them only pretends: nothing is run or reopened.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("recovery-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    store.recoveryCenter.showPreview(stage: open.split(separator: ":").dropFirst().first.map(String.init))
                }
            }
            // "status-preview" fills the status bar with sample items;
            // ":running" or ":failed" picks the CI state shown.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("status-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let overall: CIStatus.Overall = switch open.split(separator: ":").dropFirst().first {
                    case "running": .running
                    case "failed": .failed
                    default: .passed
                    }
                    statusBar.debugShowSample(ci: overall)
                }
            }
            // "picker" or "picker:folder" opens Octet's file picker on the repo.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("picker") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    PathPickerCenter.shared.pick(open == "picker:folder" ? "Open Folder as Workspace" : "Attach Files",
                                                 message: "Verification sample", mode: open == "picker:folder" ? .folder : .files(multiple: true),
                                                 start: NSHomeDirectory() + "/Developer/apps/herd", in: window.nsWindow) { _ in }
                }
            }
            // "footer:<awake|resources|ports|hosts>" opens that status popover.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("footer:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    window.chromeDropdowns.openId = "footer-" + open.dropFirst("footer:".count)
                }
            }
            // "usage" opens the usage page; "usage:tokens:week" also picks
            // its mode and period.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("usage") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ui.usageBreakdownVisible = true }
            }
            #if DEBUG
            // "account-card" opens the title bar's usage card;
            // "account-card:sample" fills it with sample readings first.
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("account-card") {
                if open == "account-card:sample" { AccountStore.shared.debugShowSample() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NotificationCenter.default.post(name: AccountChips.debugOpenCard, object: nil)
                }
            }
            #endif
            // "agents" opens the agents hub; "agents:down:return" and the
            // like also drive it (AgentsHub.applyDebugOptions).
            if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open == "agents" || open.hasPrefix("agents:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    // This window's own workspace: the app may not be in
                    // front, so "the key window" can be nobody.
                    AgentCenter.shared.setBoard(.all, in: window.focusedWorkspace?.workspaceId)
                }
            }
            // Verification hook: open a window at launch without a click.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == MarketplaceWindow.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MarketplaceWindow.open() }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "banner" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    AgentBannerCenter.shared.show([
                        AgentEvent(id: "sample-1", kind: .finished, agent: "claude", paneId: "w1:p1", tabId: "w1:t1",
                                   workspaceId: "w1", label: "migrate schema", workedFor: 134, at: Date()),
                        AgentEvent(id: "sample-2", kind: .needsInput, agent: "codex", paneId: "w1:p2", tabId: "w1:t2",
                                   workspaceId: "w1", label: "review auth flow", workedFor: 22, at: Date()),
                    ])
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "confirm" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ConfirmCenter.shared.ask(
                        title: "Quit Octet?",
                        message: "Your terminals and agents keep running in the background. Reopen Octet to pick up where you left off.",
                        confirmTitle: "Quit",
                        suppressTitle: "Don't ask again"
                    ) { _ in }
                }
            }
            // "delegation-approval" shows the approval dialog with a made-up request.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "delegation-approval" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    DelegationApprovalCenter.shared.ask(.init(
                        caller: "Claude Code", callerAgent: "claude", agent: "codex", agentName: "Codex", mode: .review,
                        task: "Review the uncommitted changes in this repo for correctness. Focus on the retry logic in Uploader.swift: does the backoff cap at 30 seconds, is the jitter bounded, and can a cancelled upload keep retrying? Report concrete problems with file and line, and say PASS or FAIL at the end.",
                        folder: NSHomeDirectory() + "/Developer/apps/herd", onAllow: { _ in }, onDeny: {}))
                }
            }
            // "paste-preview" shows the long-paste dialog with made-up text.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "paste-preview" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let sample = (1...48).map { "line \($0): let delay = min(base * pow(2, Double(attempt)), 30) + jitter()" }.joined(separator: "\n")
                    PastePreviewCenter.shared.request = .init(paneId: "w1:p1", target: "Claude Code", text: sample, window: NSApp.keyWindow)
                }
            }
            // "toast-all" shows one toast of each kind, held (no auto-dismiss in time to look).
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "toast-all" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let center = ToastCenter.shared
                    _ = center.progress("Updating Claude Code…", detail: "claude update")
                    center.succeed(nil, "Pushed 3 commits to origin/feat/t3-parity", detail: nil)
                    center.info("Closed the tab “Fix the upload retry”", after: 600,
                                action: .init(title: "Reopen") {})
                    center.fail(nil, "Couldn't open the page",
                                detail: "localhost:3000 refused to connect. Is the dev server running?")
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "toast" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ToastCenter.shared.info(
                        "Copied to clipboard",
                        detail: "A compact preview of the copied text",
                        after: 30
                    )
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "handoff" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    window.debugShowAgentUIHandoff()
                }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "editor" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    // OCTET_EDITOR_FILE opens that file instead.
                    let candidate = ProcessInfo.processInfo.environment["OCTET_EDITOR_FILE"].map { URL(fileURLWithPath: $0) }
                        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent("Octet/Editor/CodeEditorView.swift")
                    let split = ProcessInfo.processInfo.environment["OCTET_EDITOR_SPLIT"] != nil
                    window.openFile(candidate, presentation: split ? .split : .full)
                }
            }
            #endif
        }

    /// A breadcrumb's folder: the Files plane comes forward with it open.
    private func revealInFiles(_ folder: String) {
        window.editor.folderReveal = EditorWorkspace.FolderReveal(path: folder)
        ui.showPlane(.files)
    }

    private func closePalette() {
        ui.paletteVisible = false
    }

    /// Files opened from terminal context begin beside the live terminal, so
    /// commands and source stay in one flow. External “Open in Octet” requests
    /// use the full editor surface instead. A conversation or container logs
    /// dragged to the terminal's edge sit beside it the same way.
    private var contentArea: some View {
        let companion = shownCompanion
        return CompanionSplit(edge: companion?.edge, share: companion?.share ?? 0.5,
                              setShare: { share in companion.map { window.setShare(share, of: $0.stripId) } },
                              terminalMoved: { terminalOffset = $0 }) {
            terminalWithOverlay
        } companion: {
            // One view either way, so the layout's three places stay put.
            ZStack {
                if let companion { companionView(companion.stripId) } else { Color.clear }
            }
        }
    }

    /// What's beside the terminal. A file opened beside it (the editor's
    /// split) comes first, where the editor was last put; then whatever was
    /// dragged there, unless that's the editor and it's open over everything.
    private var shownCompanion: WindowContext.Companion? {
        let editorId = "editor:" + window.id.uuidString
        if window.editor.isPresented, window.editor.presentation == .split {
            let edge = window.companion?.stripId == editorId ? window.companion?.edge ?? .right : .right
            return WindowContext.Companion(stripId: editorId, edge: edge, share: window.share(of: editorId))
        }
        guard let companion = window.companion else { return nil }
        if companion.stripId == editorId, window.editor.isPresented, window.editor.presentation == .full { return nil }
        return companion
    }

    @ViewBuilder
    private func companionView(_ stripId: String) -> some View {
        if stripId.hasPrefix("conversation:"),
           let session = agents.sessions(in: window.focusedWorkspace?.workspaceId).first(where: { "conversation:" + $0.id == stripId }) {
            ConversationView(session: session, client: store.client)
                .id(session.id)
        } else if stripId.hasPrefix("editor:") {
            CodeEditorView(workspace: window.editor, rootDirectory: window.editorRootDirectory,
                           revealFolder: revealInFiles)
        } else if let log = window.workspaceContainerLogs.first(where: { $0.visualID == stripId }) {
            ContainerLogsPlane(context: log.context, containerID: log.containerID, name: log.name, visible: true)
        }
    }

    private var terminalWithOverlay: some View {
        terminal.overlay { terminalOverlay }
            .overlay {
                if terminalDisconnected && window.activeContainerLog == nil {
                    TerminalDisconnectedCard(
                        serverReachable: store.isConnected,
                        retryFailed: lastReconnect.map { Date().timeIntervalSince($0) < 10 } ?? false
                    ) {
                        lastReconnect = Date()
                        terminalDisconnected = false
                        session?.ensureServer()
                        store.scheduleRefresh()
                    }
                }
            }
    }

    /// The conversation in front of the terminal, unless it's beside it.
    private var coveringConversation: AgentSession? {
        guard let conversation = agents.active(in: window.focusedWorkspace?.workspaceId),
              !window.isBeside("conversation:" + conversation.id) else { return nil }
        return conversation
    }

    /// What covers the terminal: a board, a conversation, or a new tab's
    /// splash, plus drop zones while a tab is dragged. Clipped to the terminal
    /// area, so a board slides out from behind the sidebar, not over it.
    private var terminalOverlay: some View {
        ZStack {
                    if window.activeContainerLog != nil {
                        Theme.terminalBackground
                    } else if let agent = window.agentUIHandoff {
                        AgentUIHandoffView(agent: agent, toTerminal: window.agentUIHandoffToTerminal)
                    } else if let review = ui.review {
                        DiffReviewView(model: review, store: store) { window.toggleReview() }
                            .id(review.directory)
                            .onAppear { DebugSnapshot.overlay("review", true) }
                            .onDisappear { DebugSnapshot.overlay("review", false) }
                    } else if window.editor.isPresented, window.editor.presentation == .full {
                        CodeEditorView(workspace: window.editor, rootDirectory: window.editorRootDirectory,
                               revealFolder: revealInFiles)
                    } else if let conversation = coveringConversation {
                        ConversationView(session: conversation, client: store.client)
                            .id(conversation.id)
                            .onAppear { DebugSnapshot.overlay("conversation", true) }
                            .onDisappear { DebugSnapshot.overlay("conversation", false) }
                    } else if twin.isVisible {
                        TwinView(twin: twin, store: store)
                    } else if let hints = ui.hints {
                        HintsOverlay(session: hints, geometry: paneGeometry, window: window)
                        .id(hints.id)
                    } else {
                        FocusedGridReader(geometry: paneGeometry) { grid in
                            if let grid, let tab = splash.tabId,
                                      tab == window.displayedFocusedTabId {
                                newTabSplash(clearOf: grid)
                                    .id(tab)
                                    .transition(motion.animates(.tabs) ? .opacity : .identity)
                            } else {
                                let layout = store.snapshot.layouts.first { $0.tabId == window.displayedFocusedTabId }
                                ZStack {
                                    SearchHighlightView(geometry: paneGeometry)
                                    LiveScrollPills(watcher: liveScroll, geometry: paneGeometry)
                                    if let tab = window.displayedFocusedTabId, let layout = liveLayout(of: tab) {
                                        PaneCards(layout: layout, cells: cellGeometry, focusedPane: window.focusedPaneId)
                                        if tabDrag.item == nil {
                                            PaneDividers(layout: layout, cells: cellGeometry, move: { pane, sideBySide, cells in
                                                store.moveDivider(beside: pane, sideBySide: sideBySide, by: cells)
                                            }, equalize: { pane in
                                                store.call("pane.equalize", ["pane_id": pane], failure: "Couldn't make the panes equal") { _ in }
                                            })
                                        }
                                    }
                                    OutputFindHost(find: window.outputFind,
                                                   layout: window.displayedFocusedTabId.flatMap { liveLayout(of: $0) },
                                                   cells: cellGeometry)
                                }
                            }
                        }
                    }
                    // The one beside the terminal shows there instead.
                    ForEach(window.containerLogs.tabs.filter { !window.isBeside($0.visualID) }) { tab in
                        let shown = window.activeContainerLog?.id == tab.id
                        ContainerLogsPlane(context: tab.context, containerID: tab.containerID, name: tab.name, visible: shown)
                            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
                    }
                    dropLayers
                }
                .overlay { popupPane }
                .overlay(alignment: .top) { BroadcastBanner(mode: BroadcastMode.shared, tabId: window.displayedFocusedTabId) }
                .overlay(alignment: .bottomLeading) { HoverLinkPreview() }
                .overlay(alignment: .topTrailing) { SecureInputBadge() }
                .animation(motion.animation(.tabs, .smooth(duration: 0.2)), value: splash.tabId)
                // Full size even while empty, so the clip is a
                // fixed window the board slides through rather than
                // a box that grows with it from the center.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
    }

    /// A short visual bridge between an agent's terminal interface and the
    /// same saved session rendered as an Octet conversation.
    private struct AgentUIHandoffView: View {
        let agent: String
        /// Back out to the agent's own interface, rather than into Octet.
        var toTerminal = false

        private var destination: String {
            toTerminal ? AgentBrand.forAgent(agent)?.displayName ?? "the terminal" : "Octet"
        }

        var body: some View {
            VStack(spacing: 13) {
                if let brand = AgentBrand.forAgent(agent) {
                    AgentLogo(brand: brand, size: 30)
                }
                Text("Opening in \(destination)")
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                Capsule()
                    .fill(Theme.accent.opacity(0.55))
                    .frame(width: 44, height: 2)
                Text("Keeping the conversation and working directory")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(toTerminal ? "Opening in \(destination)"
                                : "Opening \(AgentBrand.forAgent(agent)?.displayName ?? "agent") in Octet")
        }
    }

    /// The maximized panel lies over the terminal; what's drawn on the
    /// terminal from the root would show through it.
    /// So do the pages over the terminal (Usage, Pull Requests, review,
    /// agents, a conversation, the full editor): the shell's prompt line
    /// mustn't show through them as a stray bar.
    private var panelCoversTerminal: Bool {
        (ui.sidePanelVisible && ui.sidePanelMaximized) || ui.settingsVisible || ui.marketplaceVisible
            || ui.usageBreakdownVisible || ui.pullRequests != nil || ui.review != nil
            || window.agentUIHandoff != nil || boardHere != nil || window.activeContainerLog != nil
            || coveringConversation != nil
            || (window.editor.isPresented && window.editor.presentation == .full)
    }

    /// Octet's own command line and its completions, drawn over the shell's prompt.
    @ViewBuilder
    private var promptOverlay: some View {
        ZStack(alignment: .topLeading) {
            // Octet's own command line, drawn over the shell's prompt.
            if prompt.isActive, !panelCoversTerminal, let anchor = prompt.anchor {
                PromptEditorView(editor: prompt)
                    .frame(width: max(120, CGFloat(anchor.columnsRemaining) * anchor.cellWidth))
                    .offset(x: sidebarInset + terminalOffset.width + anchor.origin.x,
                            y: contentTop + terminalOffset.height + anchor.origin.y)
                    .allowsHitTesting(false)
            }
            if prompt.isActive, prompt.menuShown, !panelCoversTerminal, let anchor = prompt.anchor {
                // Under the word being completed, or above it near the foot
                // of the window.
                let top = contentTop + terminalOffset.height + anchor.origin.y
                let below = top + anchor.cellHeight + 4
                let fitsBelow = below + 240 < windowHeight
                let left = sidebarInset + terminalOffset.width + anchor.origin.x + CGFloat(prompt.completionColumn) * anchor.cellWidth
                let room = windowWidth - left - 8
                if fitsBelow {
                    CompletionMenuView(editor: prompt, maxWidth: room)
                        .fixedSize(horizontal: true, vertical: true)
                        .offset(x: left, y: below)
                } else {
                    // The result count changes the menu's height. Anchor its
                    // bottom to the prompt instead of reserving the maximum
                    // height, so a short menu does not float above the cursor.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CompletionMenuView(editor: prompt, maxWidth: room)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .frame(width: CompletionMenuView.widest, height: max(0, top - 4), alignment: .bottomLeading)
                    .offset(x: left)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Splitting by drag

    /// Whether the tab in front has several panes.
    private var showingSplit: Bool {
        guard let tab = window.displayedFocusedTabId, let layout = liveLayout(of: tab) else { return false }
        return layout.panes.count > 1
    }

    /// The tab whose terminal is in view, which a drop splits: none while
    /// anything covers the terminal (logs, a board, a conversation, review,
    /// the full editor, Twin, hints, an agent's hand-off), since a split
    /// there would land out of sight.
    private var terminalShowing: String? {
        guard window.activeContainerLog == nil, boardHere == nil, coveringConversation == nil, ui.review == nil,
              !(window.editor.isPresented && window.editor.presentation == .full), !twin.isVisible,
              ui.hints == nil, window.agentUIHandoff == nil else { return nil }
        return window.displayedFocusedTabId
    }

    /// One of Octet's own tabs covering the terminal, which a terminal tab
    /// dropped by its edge goes beside.
    private var coveringStripTab: String? {
        if let conversation = coveringConversation { return "conversation:" + conversation.id }
        if window.editor.isPresented, window.editor.presentation == .full { return "editor:" + window.id.uuidString }
        return window.activeContainerLog?.visualID
    }

    /// Panes are placed by the layout scaled to the terminal area
    /// (`NativePaneGrid`), so the overlays scale it the same way.
    private var cellGeometry: CellGeometry { .scaled }

    /// A tab's panes as the snapshot has them, kept current as panes change;
    /// the layout fetched when the drag began while the snapshot has none.
    private func liveLayout(of tabId: String) -> PaneLayout? {
        store.snapshot.layouts.first { $0.tabId == tabId }.flatMap(PaneLayout.init)
            ?? (dropLayout?.tab == tabId ? dropLayout?.layout : nil)
    }

    /// The zones over the terminal for whatever is being dragged.
    @ViewBuilder
    private var dropLayers: some View {
        let animation = motion.animation(.tabs, .smooth(duration: 0.15))
        switch tabDrag.item {
        case .tab(let dragged)?:
            if let showing = terminalShowing {
                splitDropLayer(moving: dragged, into: showing)
            } else if let cover = coveringStripTab,
                      store.snapshot.tabs.first(where: { $0.tabId == dragged })?.workspaceId == window.focusedWorkspace?.workspaceId {
                // The terminal tab goes on that side; what covered it, beside.
                CompanionDropLayer(title: { "Terminal \($0.sideName)" }, animation: animation) { edge in
                    window.showBeside(cover, edge: edge.opposite)
                    window.focusTab(dragged)
                }
            }
        case .pane(let pane)?:
            if let showing = terminalShowing { paneDropLayer(moving: pane, into: showing) }
        case .stripTab(let id)?:
            // Over the terminal, or over itself where it covers the terminal:
            // either way, by an edge, it goes beside the terminal there.
            if tabDrag.sourceWindow === window, terminalShowing != nil || coveringStripTab == id {
                CompanionDropLayer(title: { "Show Beside, \($0.sideName)" }, animation: animation) { edge in
                    window.showBeside(id, edge: edge)
                }
            }
        case .workspace?:
            // The window's own overlay takes workspace drops, over every surface.
            EmptyView()
        case nil:
            EmptyView()
        }
    }

    private func splitDropLayer(moving dragged: String, into showing: String) -> some View {
        let fromElsewhere = dragged != showing
            && store.snapshot.tabs.first { $0.tabId == dragged }?.workspaceId != window.focusedWorkspace?.workspaceId
        let own = dragged == showing
        return SplitDropLayer(layout: liveLayout(of: showing), cells: cellGeometry, acceptsTab: fromElsewhere,
                              action: own ? .newShell : .split, wholeTab: store.hasOctetEngine,
                              animation: motion.animation(.tabs, .smooth(duration: 0.15))) { target in
            guard let edge = target.edge else {
                return WindowActions.moveTab(dragged, into: window, atStripGap: nil)
            }
            if own {
                // Its own edge: a fresh shell opens on the side shown, in the
                // folder of the pane beside it.
                let near = target.paneId ?? store.snapshot.panes.first { $0.tabId == showing && $0.focused }?.paneId
                let cwd = near.flatMap { pane in
                    store.snapshot.workingDirectory(ofPane: pane) ?? store.snapshot.panes.first { $0.paneId == pane }?.effectiveCwd
                }
                store.splitNewPane(beside: target.paneId, inTab: showing, edge: edge, cwd: cwd)
            } else if let moving = store.onlyPane(ofTab: dragged) {
                store.movePane(moving.paneId, into: showing, beside: target.paneId, edge: edge)
            } else {
                ToastCenter.shared.info("A split tab can't move in as one pane",
                                        detail: "Move its panes out first (Pane › Move Pane to New Tab), then drag each.")
            }
        }
    }

    /// A pane dragged by its handle, over the tab it's in or another.
    private func paneDropLayer(moving pane: String, into showing: String) -> some View {
        SplitDropLayer(layout: liveLayout(of: showing), cells: cellGeometry, moving: pane, wholeTab: store.hasOctetEngine,
                       animation: motion.animation(.tabs, .smooth(duration: 0.15))) { target in
            guard let edge = target.edge else { return }
            store.movePane(pane, into: showing, beside: target.paneId, edge: edge)
        }
    }

    /// Fetches the showing tab's panes when a drag starts, for its zones,
    /// in case the snapshot has none for it yet.
    private func loadDropLayout(dragging: Bool) {
        dropLayout = nil
        guard dragging, let showing = terminalShowing,
              !store.snapshot.layouts.contains(where: { $0.tabId == showing }) else { return }
        store.paneLayout(ofTab: showing) { layout in
            if tabDrag.item != nil, let layout { dropLayout = (showing, layout) }
        }
    }

    // MARK: - New tab splash

    /// Hands one grid reading to the splash, for the tab in front. It only
    /// counts while the terminal area is the tab's own: no conversation or
    /// board over it, one pane, and no program known to be running in it.
    private func observeSplash(_ grid: TerminalGrid?) {
        let tabId = window.displayedFocusedTabId
        let tab = window.displayedTabs.first { $0.tabId == tabId }
        let eligible = settings.values.newTabSplash
            && boardHere == nil
            && coveringConversation == nil
            && tab?.paneCount == 1
            // Unknown counts as a shell: a new tab's first look is still coming.
            && (window.focusedProcess == nil || window.focusedPaneAtPrompt)
        splash.observe(tab: tabId, grid: grid, eligible: eligible,
                       typing: prompt.isActive && !prompt.line.text.isEmpty)
    }

    /// The splash, in whichever blank stretch of the pane is taller: above a
    /// bottom-anchored prompt, or below a top one. It keeps a margin off the
    /// prompt so the line being typed is never covered.
    private func newTabSplash(clearOf grid: TerminalGrid) -> some View {
        GeometryReader { proxy in
            let margin: CGFloat = 20
            let above = grid.cursorTop - margin
            let below = proxy.size.height - grid.cursorBottom - margin
            let top = above >= below ? 0 : grid.cursorBottom + margin
            let height = max(0, max(above, below))
            NewTabSplash(
                currentDirectory: store.snapshot.panes.first { $0.paneId == window.focusedPaneId }?.effectiveCwd,
                hostWindow: window.nsWindow,
                runAgent: { window.startAgent($0) },
                openFolder: { window.runInFocusedPane("cd " + shellQuote($0)) },
                runCommand: { window.runInFocusedPane($0) },
                shortcuts: [
                    .init(title: "Command Palette", keys: OctetShortcut.palette.keys) { ui.paletteVisible = true },
                    .init(title: "New Claude Conversation", keys: OctetShortcut.newConversation.keys, agent: "claude") {
                        window.newConversation(replacingStarterTab: window.displayedFocusedTabId)
                    },
                    .init(title: "New Codex Conversation", agent: "codex") {
                        window.newConversation(engine: .codex, replacingStarterTab: window.displayedFocusedTabId)
                    },
                    .init(title: "New Claude Cloud Session", agent: "claude") {
                        ui.paletteStart = [PaletteCatalog.claudeCloudItemId]
                        ui.paletteVisible = true
                    },
                    .init(title: "New Pi Conversation", agent: "pi") {
                        window.newConversation(engine: .pi, replacingStarterTab: window.displayedFocusedTabId)
                    },
                    .init(title: "New Qwen Conversation", agent: "qwen") {
                        window.newConversation(engine: .qwen, replacingStarterTab: window.displayedFocusedTabId)
                    },
                    .init(title: "Split Right", keys: OctetShortcut.splitRight.keys) { window.splitPane(.right) },
                    .init(title: "Agents", keys: OctetShortcut.agents.keys) { window.toggleAgentsBoard() },
                ]
            )
            .frame(width: proxy.size.width, height: height)
            .offset(y: top)
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            sessionTerminal(session)
                .overlay(alignment: .top) {
                    if let connecting {
                        SSHConnectCard(target: connecting)
                            .padding(.top, 18)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: focusedClaude, initial: true) { _, claude in
                    statusBar.watchRemoteControl(sessionId: claude?.sessionId, cwd: claude?.cwd, claudePid: claude?.pid)
                }
                .onChange(of: StatusBarFocus(pane: window.focusedPaneId, directory: focusedPaneCwd, ssh: focusedSSH), initial: true) { _, focus in
                    statusBar.show(pane: focus.pane, directory: focus.directory, ssh: focus.ssh, client: store.client)
                }
                .onChange(of: store.paneSSH) { old, new in sshChanged(from: old, to: new) }
        } else {
            missingEngine
        }
    }

    /// The tab in front, each pane a terminal of its own, drawn from the
    /// engine's stream of it.
    private func sessionTerminal(_ session: EngineSession) -> some View {
        NativePaneGrid(layout: window.displayedFocusedTabId.flatMap { liveLayout(of: $0) },
                       livePanes: Set(store.snapshot.panes.map(\.paneId)),
                       tabId: window.displayedFocusedTabId,
                       focusedPaneId: window.focusedPaneId,
                       socketPath: session.socketPath,
                       gutter: PaneCards.gutter,
                       geometry: paneGeometry,
                       viewport: { tab, columns, rows in store.setViewport(tab: tab, columns: columns, rows: rows) }) { pane in
            // A pane takes focus while the grid is being updated: publishing
            // then would make SwiftUI draw everything again inside this draw.
            DispatchQueue.main.async { window.activateSplitSurface() }
            guard pane != window.focusedPaneId else { return }
            store.call("pane.focus", ["pane_id": pane], failure: "Couldn't focus the pane") { _ in }
        }
        .background(Theme.terminalBackground.opacity(settings.values.effectiveBackgroundOpacity))
        .onAppear {
            // No terminal client starts the server any more, and none has to
            // be waited for before the window goes where it was opened for.
            session.ensureServer()
            window.terminalReady()
        }
    }

    /// A popup pane, floating over the terminal at the size its plugin asks
    /// for. It goes when its program exits, or when closed here.
    @ViewBuilder
    private var popupPane: some View {
        if let pane = window.popupPaneId, let session {
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    PaneTerminal(paneId: pane, socketPath: session.socketPath) {
                        if window.popupPaneId == pane { window.popupPaneId = nil }
                        OctetTerminalRuntime.focusTerminal()
                    }
                    .id(pane)
                    .clipShape(RoundedRectangle(cornerRadius: PaneCards.radius))
                    OctetIconButton(icon: "xmark", help: "Close the popup", compact: true) {
                        store.call("pane.close", ["pane_id": pane], failure: "Couldn't close the popup") { _ in }
                        window.popupPaneId = nil
                        OctetTerminalRuntime.focusTerminal()
                    }
                    .padding(Theme.Space.sm)
                }
                .background(RoundedRectangle(cornerRadius: PaneCards.radius).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: PaneCards.radius).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                .frame(width: proxy.size.width * 0.8, height: proxy.size.height * 0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
        }
    }

    private var missingEngine: some View {
        VStack(spacing: 8) {
            Text("Terminal engine missing").font(Theme.Text.title3)
            Text("The terminal engine is missing from this copy of Octet. Reinstall Octet.")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }
}

/// Makes the window see-through when the terminal background is translucent,
/// and applies the renderer's background blur.
private struct WindowTransparency: NSViewRepresentable {
    let opacity: Double
    let blur: Bool
    let themeName: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let translucent = opacity < 1
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
            OctetTerminalRuntime.applyBackgroundBlur(to: window)
        }
    }
}

final class UIState: ObservableObject {
    @Published var panelWorkspaceID: String?
    var panelTerminalExited: Set<String> = []
    var panelTerminalSurfaces: [String: TerminalEngine.SurfaceView] = [:]
    var panelBrowserPages: [String: BrowserPage] = [:]
    var workspaceClosedPlanes: [String: [Plane]] = [:]
    var restoringWorkspacePanel = false
    var panelDefaults = UserDefaults.standard
    @Published var additionalPlaneShortcuts = UserDefaults.standard.string(forKey: "octet.additionalPlaneShortcuts") ?? "" {
        didSet { saveWorkspacePanel() }
    }
    @Published var planeSplitWeights: [String: CGFloat] = [:] { didSet { saveWorkspacePanel() } }
    @Published var panelFolded: Set<String> = [] { didSet { saveWorkspacePanel() } }
    @Published var panelOpened: Set<String> = [] { didSet { saveWorkspacePanel() } }

    /// Hint labels over the terminal, while they're up.
    @Published var hints: HintsSession?
    /// Palette items to open straight into, the first that exists.
    var paletteStart: [String]?
    /// What the palette's field holds as it opens: ">" for Show All Commands.
    var paletteQuery: String?
    /// The keyboard cheat sheet over the window (Help › Keyboard Shortcuts).
    @Published var shortcutsVisible = false
    /// The changes review over the terminal, while it's open.
    @Published var review: DiffReviewModel?
    /// The Pull Requests page over the terminal, while it's open.
    @Published var pullRequests: PullRequestsPageModel?
    /// Bumped to put the keyboard in the sidebar's search field.
    @Published var sidebarSearchRequest = 0
    /// The usage breakdown sheet.
    @Published var usageBreakdownVisible = false
    /// The Marketplace, as a page over the content area.
    @Published var marketplaceVisible = false
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "octet.sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "octet.sidebarVisible") }
    }
    /// The right panel, with every section (`SidePanel`).
    @Published var sidePanelVisible = UserDefaults.standard.bool(forKey: "octet.sidePanelVisible") {
        didSet {
            if sidePanelVisible && !sidePanelEverShown { sidePanelEverShown = true }
            saveWorkspacePanel()
            if !sidePanelVisible && !restoringWorkspacePanel {
                // T3 Code: hiding the panel over a streaming device floats
                // it over the terminal. Said before the plane hears it's
                // hidden, so the stream is handed over, not restarted.
                if let plane = activePlane, plane.kind == .device {
                    MainActor.assumeIsolated { DeviceFloat.shared.panelHiding(planeId: plane.id) }
                }
                sidePanelAutoOpened = false
                sidePanelMaximized = false
            }
        }
    }
    /// The panel opened itself for a new runtime, and nobody has pointed
    /// at it since: it closes again after a few seconds.
    var sidePanelAutoOpened = false
    /// A request to open a section and scroll to it; a new value each
    /// time, so asking for the same section twice works.
    struct SidePanelJump: Equatable {
        let section: SidePanelSection
        let at = Date()
    }
    @Published var sidePanelJump: SidePanelJump?
    /// The Device plane whose Set Up Devices dialog is up (or was last),
    /// drawn over the window; it shows while the model's `setupShowing` is.
    @Published var deviceSetup: DeviceHubModel?

    // MARK: Planes

    /// The panel's planes, left to right, kept across launches.
    @Published var planes: [Plane] = UIState.savedPlanes() {
        didSet {
            saveWorkspacePanel()
        }
    }
    /// The plane in front, by id.
    @Published var activePlaneId: String? = UserDefaults.standard.string(forKey: "octet.activePlane").map(Plane.migratedID) {
        didSet {
            saveWorkspacePanel()
            if !restoringWorkspacePanel, let activePlaneId, splitPlaneIds.count > 1, !splitPlaneIds.contains(activePlaneId) {
                let index = oldValue.flatMap { splitPlaneIds.firstIndex(of: $0) } ?? (splitPlaneIds.count - 1)
                splitPlaneIds[index] = activePlaneId
            }
        }
    }
    @Published var splitPlaneIds = UserDefaults.standard.stringArray(forKey: "octet.splitPlanes") ?? [] {
        didSet { saveWorkspacePanel() }
    }
    @Published var splitSideBySide = UserDefaults.standard.bool(forKey: "octet.splitSideBySide") {
        didSet { saveWorkspacePanel() }
    }

    /// What planes say about themselves on their tabs, e.g. "#12" in green.
    @Published var planeBadges: [String: PlaneBadge] = [:]
    /// Whether the panel has been open this launch. It's built only from
    /// then on, and kept, so what its planes loaded survives closing it.
    @Published private(set) var sidePanelEverShown = UserDefaults.standard.bool(forKey: "octet.sidePanelVisible")
    /// The panel over the whole window's content, the terminal left as it is
    /// underneath. Restored with this workspace’s other panel settings.
    @Published var sidePanelMaximized = false { didSet { saveWorkspacePanel() } }

    private static func savedPlanes() -> [Plane] {
        // Before planes the panel had fixed pages; start from the usual two.
        // Closing the last plane closes the panel, so an empty list is only
        // ever the last session's end: start from the usual two again.
        guard let data = UserDefaults.standard.data(forKey: "octet.planes"),
              let planes = try? JSONDecoder().decode([Plane].self, from: data), !planes.isEmpty else { return Plane.defaults }
        return Plane.consolidated(planes, active: UserDefaults.standard.string(forKey: "octet.activePlane"))
    }

    /// The plane in front: the chosen one, else the first.
    var activePlane: Plane? { planes.first { $0.id == activePlaneId } ?? planes.first }

    /// Whether a plane of this kind is in front of a visible panel.
    func showing(_ kind: PlaneKind) -> Bool { sidePanelVisible && planes.contains { $0.kind == kind && visiblePlaneIds.contains($0.id) } }

    /// Adds a plane, or brings forward the one there, and shows it.
    func addPlane(_ kind: PlaneKind, number: Int? = nil) {
        let plane = Plane.make(kind, number: number)
        if plane.kind == .pullRequests, let index = planes.firstIndex(where: { $0.id == plane.id }) {
            planes[index] = plane
            planeBadges[plane.id] = nil
        } else if !planes.contains(where: { $0.id == plane.id }) { planes.append(plane) }
        activePlaneId = plane.id
        sidePanelVisible = true
    }

    /// Shows the panel on a plane of this kind, adding it if it's closed.
    func showPlane(_ kind: PlaneKind, number: Int? = nil) {
        addPlane(kind, number: number)
        sidePanelAutoOpened = false
    }

    /// A page for the Browser plane to load, e.g. a dev server from the
    /// status bar. The plane owns its web view, so it's asked through here
    /// and takes the request (clearing it) once it's on screen.
    struct BrowserRequest: Equatable {
        let url: URL
        let at = Date()
    }
    @Published var browserRequest: BrowserRequest?

    /// One agent turn for the Diff plane to show, from a conversation's
    /// changed-files card: the plane works out the turn's comparison from
    /// the checkpoint taken as it started, and opens on `path` when given.
    struct DiffRequest: Equatable {
        let directory: String
        let promptAt: Date?
        let nextPromptAt: Date?
        let path: String?
        let at = Date()
    }
    @Published var diffRequest: DiffRequest?

    /// Shows the Diff plane on the turn begun by the prompt sent at `promptAt`.
    func openTurnDiff(directory: String, promptAt: Date?, nextPromptAt: Date?, path: String?) {
        diffRequest = DiffRequest(directory: directory, promptAt: promptAt, nextPromptAt: nextPromptAt, path: path)
        showPlane(.diff)
    }

    /// Shows the Browser plane on `url`.
    func openInBrowserPlane(_ url: URL) {
        browserRequest = BrowserRequest(url: url)
        showPlane(.browser)
    }

    /// Closes a plane; the one beside it comes forward, and closing the last
    /// closes the panel.
    func closePlane(_ id: String) {
        closePlanes { $0.id == id }
    }

    /// Planes closed this session, newest last, for Reopen Closed Plane.
    var closedPlanes: [Plane] = []

    /// Brings back the plane closed last, where it was.
    func reopenClosedPlane() {
        guard let plane = closedPlanes.popLast() else { return }
        if !planes.contains(where: { $0.id == plane.id }) { planes.append(plane) }
        activePlaneId = plane.id
        sidePanelVisible = true
    }

    func closePlanes(where shouldClose: (Plane) -> Bool) {
        let activeIndex = planes.firstIndex { $0.id == activePlane?.id }
        let closingActive = activePlane.map(shouldClose) ?? false
        closedPlanes.append(contentsOf: planes.filter(shouldClose))
        closedPlanes = Array(closedPlanes.suffix(20))
        for plane in planes.filter(shouldClose) {
            panelTerminalSurfaces.removeValue(forKey: plane.id)
            panelTerminalExited.remove(plane.id)
            if plane.kind == .browser, let workspace = panelWorkspaceID {
                panelBrowserPages.removeValue(forKey: workspace)
            }
        }
        planes.removeAll(where: shouldClose)
        splitPlaneIds = splitPlaneIds.filter { id in planes.contains { $0.id == id } }
        if splitPlaneIds.count < 2 { splitPlaneIds = [] }
        planeBadges = planeBadges.filter { id, _ in planes.contains { $0.id == id } }
        // An empty panel stays open: the launcher is its getting-started view.
        if !planes.isEmpty, closingActive, let activeIndex {
            activePlaneId = splitPlaneIds.first ?? planes[min(activeIndex, planes.count - 1)].id
        }
    }

    /// A device plane's device, once picked; its tab keeps its identity, so
    /// the stream that started for it carries on.
    func setPlaneDevice(_ id: String, deviceId: String?) {
        guard let index = planes.firstIndex(where: { $0.id == id }) else { return }
        planes[index].deviceId = deviceId
    }

    /// Drag and drop in the strip: `id` goes just before `target`.
    func movePlane(_ id: String, before target: String) {
        guard id != target, let from = planes.firstIndex(where: { $0.id == id }) else { return }
        let plane = planes.remove(at: from)
        let to = planes.firstIndex { $0.id == target } ?? planes.count
        planes.insert(plane, at: to)
    }

    /// Shows the panel with `section` open and in view, on its plane.
    func showSidePanel(_ section: SidePanelSection) {
        showPlane(section == .todos ? .todos : section == .files ? .git : .overview)
        sidePanelJump = SidePanelJump(section: section)
    }

    /// Settings as a page over the window's content, as T3 Code's are.
    @Published var settingsVisible = false

    /// The details card over the terminal (⌘⇧B), after T3 Code's thread details.
    @Published var detailsVisible = UserDefaults.standard.bool(forKey: "octet.detailsVisible") {
        didSet { UserDefaults.standard.set(detailsVisible, forKey: "octet.detailsVisible") }
    }

    // MARK: Terminal drawer

    /// The shell under the terminal, after T3 Code's drawer (⌘J).
    @Published var terminalDrawerVisible = UserDefaults.standard.bool(forKey: "octet.terminalDrawer.visible") {
        didSet { UserDefaults.standard.set(terminalDrawerVisible, forKey: "octet.terminalDrawer.visible") }
    }
    @Published var terminalDrawerHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "octet.terminalDrawer.height")
        return saved > 0 ? CGFloat(saved) : UIState.terminalDrawerDefaultHeight
    }() {
        didSet { UserDefaults.standard.set(Double(terminalDrawerHeight), forKey: "octet.terminalDrawer.height") }
    }
    static let terminalDrawerDefaultHeight: CGFloat = 280
    static let terminalDrawerMinHeight: CGFloat = 180
    /// Runtime identities already announced in this window. Views are rebuilt
    /// during tab switches, but old processes must not look newly created.
    var seenRuntimeEntryIDs: Set<String> = []
    /// Whether the agent in front has any runtimes, set by the Runtime panel
    /// (which works them out); the tab bar hides its button when it has none.
    @Published var availablePanelWidth: CGFloat = 1200
    var presentedSidePanelWidth: CGFloat {
        AgentPresentationLogic.panelWidth(normal: sidePanelWidth, available: availablePanelWidth)
    }
    @Published var runtimeHasEntries = false
    /// Runtimes opened in place in the list, to show their details.
    @Published var runtimeExpandedEntryIDs: Set<String> = []
    @Published var paletteVisible = false
    /// Drag the sidebar's edge to resize it (200pt up to half the window).
    @Published var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "octet.sidebarWidth")
        return saved > 0 ? CGFloat(saved) : Theme.sidebarWidth
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "octet.sidebarWidth") }
    }
    static let sidebarMinWidth: CGFloat = 200

    /// Drag the right panel's edge to resize it (its default width up to
    /// half the window).
    @Published var sidePanelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "octet.sidePanelWidth")
        return saved > 0 ? max(UIState.sidePanelMinWidth, CGFloat(saved)) : SidePanel.width
    }() {
        didSet { saveWorkspacePanel() }
    }
    static let sidePanelMinWidth: CGFloat = 260
}

/// An invisible strip along the right panel's left edge: drag to resize,
/// double-click to go back to the default width.
private struct SidePanelResizeHandle: View {
    @ObservedObject var ui: UIState
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    private var maxWidth: CGFloat {
        max(SidePanel.width, (NSApp.keyWindow?.frame.width ?? 1280) / 2)
    }

    var body: some View {
        Color.clear
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? ui.sidePanelWidth
                        if startWidth == nil { ResizeCancel.shared.begin { ui.sidePanelWidth = start } }
                        startWidth = start
                        guard ResizeCancel.shared.isLive else { return }
                        // Kept while dragging, even where the pointer outruns the strip.
                        NSCursor.resizeLeftRight.set()
                        ui.sidePanelWidth = min(maxWidth, max(UIState.sidePanelMinWidth, (start - drag.translation.width).rounded()))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        ResizeCancel.shared.end()
                    }
            )
            .onDisappear {
                if startWidth != nil { ResizeCancel.shared.end() }
                startWidth = nil
            }
            .onTapGesture(count: 2) { ui.sidePanelWidth = SidePanel.width }
            .help("Drag to resize the panel. Double-click to reset.")
            .accessibilityLabel("Panel width")
            .accessibilityValue("\(Int(ui.sidePanelWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 16 : -16
                ui.sidePanelWidth = min(maxWidth, max(UIState.sidePanelMinWidth, ui.sidePanelWidth + delta))
            }
    }
}

/// An invisible strip over the sidebar's divider: drag to resize, double-click
/// to go back to the default width.
private struct SidebarResizeHandle: View {
    @ObservedObject var ui: UIState
    @State private var startWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? ui.sidebarWidth
                        if startWidth == nil { ResizeCancel.shared.begin { ui.sidebarWidth = start } }
                        startWidth = start
                        guard ResizeCancel.shared.isLive else { return }
                        NSCursor.resizeLeftRight.set()
                        let maxWidth = max(UIState.sidebarMinWidth, (NSApp.keyWindow?.frame.width ?? 1280) / 2)
                        ui.sidebarWidth = min(maxWidth, max(UIState.sidebarMinWidth, (start + drag.translation.width).rounded()))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        ResizeCancel.shared.end()
                    }
            )
            .onDisappear {
                if startWidth != nil { ResizeCancel.shared.end() }
                startWidth = nil
            }
            .onTapGesture(count: 2) { ui.sidebarWidth = Theme.sidebarWidth }
            .help("Drag to resize the sidebar. Double-click to reset.")
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(ui.sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 16 : -16
                let maxWidth = max(UIState.sidebarMinWidth, (NSApp.keyWindow?.frame.width ?? 1280) / 2)
                ui.sidebarWidth = min(maxWidth, max(UIState.sidebarMinWidth, ui.sidebarWidth + delta))
            }
    }
}

private struct TitleBar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var agents = AgentCenter.shared
    /// Redraws the key hints when a shortcut is rebound.
    @ObservedObject private var shortcuts = ShortcutOverrides.shared
    @State private var isFullScreen = false
    /// The bar and its two side groups, so the centred search fits between
    /// them instead of sitting on top of them in a narrow window.
    @State private var barWidth: CGFloat = 0
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    /// As wide as the room either side of centre allows, up to 420.
    private var searchWidth: CGFloat {
        min(420, barWidth - 2 * max(leadingWidth, trailingWidth) - 16)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) { leadingControls }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
            Spacer()
            HStack(spacing: 8) { trailingControls }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        // Centered on the window, not between the uneven side groups.
        .overlay {
            if searchWidth >= 44 { searchButton }
        }
        .frame(height: Theme.titleBarHeight)
        .background {
            ZStack {
                Theme.chrome
                TitleBarDragArea()
                TrafficLightAligner(height: Theme.titleBarHeight)
                WindowObserver(title: titleText, isFullScreen: $isFullScreen)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    @ViewBuilder
    private var leadingControls: some View {
        // Room for the traffic lights, which hide in full screen.
        Color.clear.frame(width: isFullScreen ? 4 : 70)
        Button {
            ui.sidebarVisible.toggle()
        } label: {
            OctetIcon("sidebar.left", size: 18)
                .foregroundStyle(ui.sidebarVisible ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 24)
                .background(ui.sidebarVisible ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .help(OctetShortcut.toggleSidebar.help("Toggle Sidebar"))
        .accessibilityLabel(ui.sidebarVisible ? "Hide sidebar" : "Show sidebar")
        // Pane layouts from plugins (Pane Layouts ships with Octet).
        LayoutPickerButton()
        // Whether Octet or an agent tool has an update waiting.
        UpdatesButton().padding(.leading, 4)
    }

    @ViewBuilder
    private var trailingControls: some View {
        // A connected engine is the normal state and says nothing worth a
        // badge; only the wait for one does.
        if !store.isConnected { connectingIndicator }
        // Every tab's agents, wherever they run.
        AgentsHubButton(store: store)
            .environmentObject(window.panelContext)
        // The Usage page, then what the agents have left: its chips open
        // their card on hover.
        OctetIconButton(icon: "chart.bar.xaxis", help: "Usage", active: ui.usageBreakdownVisible) {
            MotionPreferences.shared.perform(.palette, .easeOut(duration: 0.15)) {
                ui.usageBreakdownVisible.toggle()
            }
        }
        AccountChips(runningAgents: runningAgents) { ui.usageBreakdownVisible = true }
            .padding(.trailing, 2)
        // The window's right panel, its toggle mirroring the sidebar's.
        Button {
            ui.sidePanelVisible.toggle()
        } label: {
            OctetIcon("sidebar.right", size: 18)
                .foregroundStyle(ui.sidePanelVisible ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 24)
                .background(ui.sidePanelVisible ? Theme.cardSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .help(OctetShortcut.togglePanel.help(ui.sidePanelVisible ? "Hide the panel" : "Show the panel"))
        .accessibilityLabel(ui.sidePanelVisible ? "Hide panel" : "Show panel")
        .padding(.trailing, 8)
    }

    private var searchButton: some View {
        Button {
            ui.paletteVisible = true
        } label: {
            HStack(spacing: 8) {
                OctetIcon("magnifyingglass", size: 15)
                if searchWidth >= 120 {
                    Text(titleText).font(Theme.uiFontMedium).lineLimit(1)
                }
                Spacer(minLength: 0)
                if searchWidth >= 240, let keys = OctetShortcut.palette.keys { KeyCombo(keys: keys) }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(width: searchWidth, height: 26)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .help(OctetShortcut.palette.help("Command Palette"))
        .accessibilityLabel("Search, \(titleText)")
    }

    private var runningAgents: Set<String> {
        let terminal = store.snapshot.agents.compactMap { agent -> String? in
            guard agent.agentStatus == .working else { return nil }
            return AgentBrand.forAgent(agent.agent ?? agent.displayAgent ?? agent.name)?.id
        }
        let native = agents.sessions.compactMap { session in
            session.conversation.isRunning ? session.engine.agent : nil
        }
        return Set(terminal + native)
    }

    private var titleText: String {
        guard let workspace = window.focusedWorkspace else { return "Octet" }
        if window.editor.isPresented, let document = window.editor.activeDocument {
            return [workspace.label, document.name].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        // A conversation in front names itself, not the terminal behind it.
        if let conversation = agents.active(in: workspace.workspaceId) {
            return [workspace.label, conversation.title].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let tab = window.focusedWorkspaceTabs.first { $0.tabId == window.displayedFocusedTabId }
        let tabName = tab.map { TabAutoName.display(label: $0.label, number: $0.number) }
        return [workspace.label, tabName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var connectingIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text("connecting")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.trailing, 4)
    }
}

/// Shows the recovery panel in the window's corner while it's presented.
private struct RecoveryOverlay: View {
    @ObservedObject var center: RecoveryCenter
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if center.isPresented {
                RecoveryPanel(center: center)
                    .padding(.trailing, 12)
                    // Clear of the status bar.
                    .padding(.bottom, 12 + StatusBar.height)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .offset(y: 8))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.18)), value: center.isPresented)
        .onChange(of: center.isPresented, initial: true) { _, shown in
            DebugSnapshot.overlay("recovery", shown)
        }
    }
}

/// What the terminal area reacts to beyond the view tree: each grid reading
/// and anything else that changes whether a tab is fresh, and a tab drag
/// starting. Kept apart so the window's own view stays small enough to
/// type-check.
/// The dialogs and pickers drawn over the whole window, above the palette.
/// A modifier of its own so the window's body stays quick to type-check.
private struct RootDialogHosts: ViewModifier {
    @ObservedObject var ui: UIState
    let store: SessionStore
    let confirmations: ConfirmCenter

    func body(content: Content) -> some View {
        content
            .overlay { AgentUpdateDialog(center: AgentUpdateCenter.shared) }
            .overlay { ConfirmDialog(center: confirmations) }
            .overlay { DelegationApprovalDialog(center: DelegationApprovalCenter.shared) }
            // Set Up Devices, over the whole window rather than the panel.
            .overlay { if let model = ui.deviceSetup { DeviceSetupSheet(model: model) } }
            .overlay { PastePreviewDialog(center: PastePreviewCenter.shared, store: store) }
            .overlay { ProjectSearchHost() }
            .overlay { SnoozePickerHost() }
            .overlay { FirstRunFlow(center: FirstRunCenter.shared) }
            // The welcome, on a first launch only, once the window has settled.
            .task {
                try? await Task.sleep(for: .seconds(1))
                FirstRunCenter.shared.presentIfFirstLaunch()
            }
    }
}

/// What animates when the window's chrome changes.
private struct RootAnimations: ViewModifier {
    @ObservedObject var ui: UIState
    let boardShowing: Bool
    @ObservedObject private var motion = MotionPreferences.shared

    func body(content: Content) -> some View {
        content
            .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: ui.paletteVisible)
            .animation(motion.animation(.sidebar), value: ui.sidebarVisible)
            .animation(motion.animation(.sidebar), value: ui.sidePanelMaximized)
            .animation(motion.animation(.sidebar), value: boardShowing)
    }
}

private struct TerminalWatchers: ViewModifier {
    @ObservedObject var geometry: PaneGeometry
    @ObservedObject var tabDrag: TabDrag
    let focusedTab: String?
    let promptEmpty: Bool
    let observe: (TerminalGrid?) -> Void
    let dragChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(geometry.$focusedGrid) { observe($0) }
            .onChange(of: focusedTab) { _, _ in
                observe(geometry.focusedGrid)
                // A drag that brought another tab forward needs its panes.
                if tabDrag.item != nil { dragChanged(true) }
            }
            .onChange(of: promptEmpty) { _, _ in observe(geometry.focusedGrid) }
            .onChange(of: tabDrag.item != nil) { _, dragging in dragChanged(dragging) }
    }
}

/// What the status bar follows: which pane, where it is, and whether it's
/// logged in elsewhere.
private struct StatusBarFocus: Equatable {
    let pane: String?
    let directory: String?
    let ssh: SSHTarget?
}

/// The Claude Code session in the focused pane, as the status bar follows it.
private struct FocusedClaude: Equatable {
    let sessionId: String
    let cwd: String
    let pid: Int?
}

/// Reads the focused pane's grid for what's drawn from it (the new-tab
/// splash), so only this redraws as the cursor moves, not the window.
private struct FocusedGridReader<Content: View>: View {
    @ObservedObject var geometry: PaneGeometry
    @ViewBuilder let content: (TerminalGrid?) -> Content

    var body: some View { content(geometry.focusedGrid) }
}
