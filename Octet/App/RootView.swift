import SwiftUI

/// Window layout: title bar, sidebar, tab bar, and the session terminal.
struct RootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let session: EngineSession?
    @ObservedObject var prompt: PromptEditor
    @ObservedObject var twin: TwinSession
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var confirmations = ConfirmCenter.shared
    @StateObject private var terminalAnchor = TerminalAnchor()
    @StateObject private var splash = NewTabSplashModel()
    @ObservedObject private var tabDrag = TabDrag.shared
    /// The panes of the tab showing, fetched when a tab drag starts.
    @State private var dropLayout: PaneLayout?
    @ObservedObject private var agents = AgentCenter.shared
    @ObservedObject private var offers = AgentOfferCenter.shared
    /// This window: what it shows, and how it moves.
    @EnvironmentObject private var window: WindowContext

    /// The agents board over this window's terminal, if one is up.
    private var boardHere: AgentCenter.Board? { agents.board(in: window.focusedWorkspace?.workspaceId) }

    /// Where the terminal starts across the window.
    private var sidebarInset: CGFloat { ui.sidebarVisible ? ui.sidebarWidth + 1 : 0 }
    private var windowHeight: CGFloat { NSApp.keyWindow?.contentView?.bounds.height ?? 800 }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        layered
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlay("palette", visible)
            if visible {
                store.refreshPlugins()
                store.refreshRemoteMachines()
                palette.reset()
                palette.reload(items: PaletteCatalog.items(window: window))
            } else {
                OctetTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: store.plugins) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(window: window))
            }
        }
        .onChange(of: store.remoteMachines) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(window: window))
            }
        }
        .onChange(of: window.focusedPaneId) { _, _ in twin.snapshotChanged() }
        .onChange(of: twin.isVisible) { _, visible in DebugSnapshot.overlay("twin", visible) }
        .onChange(of: settings.values.agentQuickAnswers) { _, _ in twin.snapshotChanged() }
        .onChange(of: store.snapshot) { _, snapshot in
            twin.snapshotChanged()
            if !snapshot.workspaces.isEmpty {
                AgentCenter.shared.restoreIfNeeded(
                    workspaceFor: { cwd in snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == cwd }?.workspaceId },
                    fallback: window.focusedWorkspace?.workspaceId
                )
            }
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(window: window))
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
        guard settings.values.agentBanner, !twin.isVisible, boardHere == nil,
              agents.active(in: window.focusedWorkspace?.workspaceId) == nil,
              let tab = window.displayedFocusedTabId else { return nil }
        return AgentOffer.candidate(in: store.snapshot.agents(inTab: tab), dismissed: offers.dismissed)
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
                    TabBarView(store: store)
                        .id(settings.themeKey)
                    if let offer = agentOffer {
                        AgentOfferBanner(agent: offer,
                                         open: { window.continueInOctet(offer) },
                                         dismiss: { offers.dismiss(offer) },
                                         never: turnOffAgentBanner)
                            // Keyed by agent, so each one's banner arrives afresh.
                            .id(AgentOffer.key(offer))
                    }
                    terminal
                        .overlay { terminalOverlay }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            AgentBannerStack(center: AgentBannerCenter.shared) { event in
                window.focus(event)
            }
            .padding(.top, contentTop)
        }
        .onAppear { appeared() }
        .modifier(TerminalWatchers(
            anchor: terminalAnchor, tabDrag: tabDrag,
            focusedTab: window.displayedFocusedTabId, promptEmpty: prompt.line.text.isEmpty,
            observe: observeSplash, dragChanged: loadDropLayout,
            ready: { window.clientReady() }
        ))
        .onChange(of: store.lastError) { _, error in
            guard let error else { return }
            ToastCenter.shared.fail(nil, "Terminal request failed", detail: error)
            store.lastError = nil
        }
        .onChange(of: confirmations.request?.id) { _, id in DebugSnapshot.overlay("confirmation", id != nil) }
        // Hide the engine's chrome before drawing the prompt and completions;
        // bottom anchoring can move this cover through the completion menu.
        .overlay(alignment: .topLeading) { chromeCover }
        .overlay(alignment: .topLeading) { promptOverlay }
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
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
                    twin: twin,
                    workspaceId: window.focusedWorkspace?.workspaceId
                )
                RecoveryOverlay(recovery: store.recovery)
            }
            .id(settings.themeKey)
        }
        // Above the palette, so a confirm raised while it's open isn't buried.
        .overlay { ConfirmDialog(center: confirmations) }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: ui.paletteVisible)
        .animation(motion.animation(.sidebar), value: ui.sidebarVisible)
        .animation(motion.animation(.sidebar), value: boardHere)
    }

    /// Once the window is up: the marketplace opener, clipboard watching, and
    /// the DEBUG verification hooks that open things without a click.
    private func appeared() {
            AgentBoardWindow.opener = { openWindow(id: AgentBoardWindow.id) }
            MarketplaceWindow.opener = { openWindow(id: MarketplaceWindow.id) }
            ClipboardWatcher.shared.start()
            #if DEBUG
            let readmeDemo = ProcessInfo.processInfo.environment["OCTET_README_DEMO"] != nil
            if readmeDemo {
                let projects = ["web-app", "api-service", "design-system", "mobile-app"]
                for (index, project) in projects.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + Double(index) * 0.8) {
                        self.window.openProject(path: "/private/tmp/octet-readme-projects/" + project)
                    }
                }
            }
            // Verification hook: "conversation" opens a native conversation;
            // "conversation:model" also opens that dropdown.
            if let window = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], window.hasPrefix("conversation") {
                DispatchQueue.main.asyncAfter(deadline: .now() + (readmeDemo ? 5.0 : 2.0)) {
                    self.window.newConversation()
                    let parts = window.split(separator: ":").map(String.init)
                    ConversationDebug.openDropdown = parts.dropFirst().first
                    ConversationDebug.scrollToItem = parts.count > 2 ? Int(parts[2]) : nil
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
            // Verification hook: "newtab" opens a tab, to see its splash.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "newtab" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.newTab() }
            }
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "agents" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AgentCenter.shared.showingBoard = true }
            }
            // Verification hook: open a window at launch without a click.
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == MarketplaceWindow.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MarketplaceWindow.open() }
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
            if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "toast" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ToastCenter.shared.info(
                        "Copied to clipboard",
                        detail: "A compact preview of the copied text",
                        after: 30
                    )
                }
            }
            #endif
        }

    private func closePalette() {
        ui.paletteVisible = false
    }

    /// What covers the terminal: a board, a conversation, or a new tab's
    /// splash, plus drop zones while a tab is dragged. Clipped to the terminal
    /// area, so a board slides out from behind the sidebar, not over it.
    private var terminalOverlay: some View {
        ZStack {
                    if boardHere == .claude {
                        AgentsBoard(store: store)
                            .transition(motion.animates(.sidebar) ? .move(edge: .leading).combined(with: .opacity) : .identity)
                    } else if boardHere == .codex {
                        CodexBoard(store: store)
                            .transition(motion.animates(.sidebar) ? .move(edge: .leading).combined(with: .opacity) : .identity)
                    } else if let conversation = agents.active(in: window.focusedWorkspace?.workspaceId) {
                        ConversationView(session: conversation, client: store.client)
                            .id(conversation.id)
                    } else if twin.isVisible {
                        TwinView(twin: twin, store: store)
                    } else if let grid = terminalAnchor.grid, let tab = splash.tabId,
                              tab == window.displayedFocusedTabId {
                        newTabSplash(clearOf: grid)
                            .id(tab)
                            .transition(motion.animates(.tabs) ? .opacity : .identity)
                    }
                    if let dragged = tabDrag.tabId, let showing = splitTargetTab(for: dragged) {
                        splitDropLayer(moving: dragged, into: showing)
                    }
                }
                .animation(motion.animation(.tabs, .smooth(duration: 0.2)), value: splash.tabId)
                // Full size even while empty, so the clip is a
                // fixed window the board slides through rather than
                // a box that grows with it from the center.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
    }

    /// Octet's own command line and its completions, drawn over the shell's prompt.
    @ViewBuilder
    private var promptOverlay: some View {
            // Octet's own command line, drawn over the shell's prompt.
            if prompt.isActive, let anchor = prompt.anchor {
                PromptEditorView(editor: prompt)
                    .frame(width: max(120, CGFloat(anchor.columnsRemaining) * anchor.cellWidth))
                    .offset(x: sidebarInset + anchor.origin.x,
                            y: contentTop + anchor.origin.y)
                    .allowsHitTesting(false)
            }
            if prompt.isActive, prompt.completionsOpen, let anchor = prompt.anchor {
                // Under the word being completed, or above it near the foot
                // of the window.
                let top = contentTop + anchor.origin.y
                let below = top + anchor.cellHeight + 4
                let fitsBelow = below + 240 < windowHeight
                CompletionMenuView(editor: prompt)
                    .offset(x: sidebarInset + anchor.origin.x + CGFloat(prompt.completionColumn) * anchor.cellWidth,
                            y: fitsBelow ? below : max(0, top - 244))
            }
        }

    @ViewBuilder
    private var chromeCover: some View {
            // The engine's chrome row travels down with bottom-anchored
            // content. Only a root-level overlay paints above the hosted
            // terminal view, so the cover lives here rather than on it.
            let _ = { DebugSnapshot.coverActive = terminalAnchor.chromeCover != nil || prompt.isActive }()
            // A conversation covers the terminal, so the patch over the engine's
            // tab row would only show through it.
            if let cover = terminalAnchor.chromeCover, !twin.isVisible, agents.active(in: window.focusedWorkspace?.workspaceId) == nil, boardHere == nil {
                Color(hex: TerminalTheme.named(settings.values.themeName).background)
                    .frame(width: cover.width, height: cover.height)
                    .offset(x: sidebarInset + cover.minX,
                            y: contentTop + cover.minY)
                    .allowsHitTesting(false)
            }
        }

    // MARK: - Splitting by drag

    /// The tab a dragged tab would split into: the one showing, when the
    /// terminal is what's showing. Only a single-pane tab can move in, and not
    /// into itself.
    private func splitTargetTab(for dragged: String) -> String? {
        guard boardHere == nil, agents.active(in: window.focusedWorkspace?.workspaceId) == nil,
              let showing = window.displayedFocusedTabId, showing != dragged,
              store.onlyPane(ofTab: dragged) != nil else { return nil }
        return showing
    }

    private func splitDropLayer(moving dragged: String, into showing: String) -> some View {
        SplitDropLayer(layout: dropLayout, animation: motion.animation(.tabs, .smooth(duration: 0.15))) { target in
            store.splitTab(dragged, into: showing, beside: target.paneId, edge: target.edge)
        }
    }

    /// Fetches the showing tab's panes when a tab drag starts, for its zones.
    private func loadDropLayout(for dragged: String?) {
        dropLayout = nil
        guard let dragged, let showing = splitTargetTab(for: dragged) else { return }
        store.paneLayout(ofTab: showing) { layout in
            if tabDrag.tabId == dragged { dropLayout = layout }
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
            && agents.active(in: window.focusedWorkspace?.workspaceId) == nil
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
                runAgent: { window.startAgent($0) },
                openFolder: { window.runInFocusedPane("cd " + shellQuote($0)) },
                shortcuts: [
                    .init(title: "Command Palette", keys: OctetShortcut.palette.display) { ui.paletteVisible = true },
                    .init(title: "New Claude Conversation", keys: OctetShortcut.newConversation.display) { window.newConversation() },
                    .init(title: "New Codex Conversation") { window.newConversation(engine: .codex) },
                    .init(title: "New Pi Conversation") { window.newConversation(engine: .pi) },
                    .init(title: "New Qwen Conversation") { window.newConversation(engine: .qwen) },
                    .init(title: "Split Right", keys: OctetShortcut.splitRight.display) { window.splitPane(.right) },
                    .init(title: "Agents Board", keys: OctetShortcut.agents.display) { window.toggleAgentsBoard() },
                ]
            )
            .frame(width: proxy.size.width, height: height)
            .offset(y: top)
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            OctetTerminalView(
                command: session.command,
                environment: session.environment,
                workingDirectory: NSHomeDirectory(),
                hiddenTopRows: EngineSession.hiddenTopRows,
                anchor: terminalAnchor,
                onTitleChange: { _ in },
                onExit: {
                    // A window closing takes its client with it; that's not
                    // the engine going away. With other windows open, a
                    // client that exits closes only its own window.
                    if window.closing { return }
                    if WindowRegistry.shared.isMulti { window.nsWindow?.close() } else { NSApp.terminate(nil) }
                },
                onSurface: { window.surface = $0 }
            )
            .background(Color(hex: TerminalTheme.named(settings.values.themeName).background)
                .opacity(settings.values.effectiveBackgroundOpacity))

        } else {
            VStack(spacing: 8) {
                Text("Terminal engine missing").font(.system(size: 14, weight: .semibold))
                Text("The terminal engine is missing from this copy of Octet. Reinstall Octet.")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
        }
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
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "octet.sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "octet.sidebarVisible") }
    }
    @Published var paletteVisible = false
    /// Drag the sidebar's edge to resize it (200pt up to half the window).
    @Published var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "octet.sidebarWidth")
        return saved > 0 ? CGFloat(saved) : Theme.sidebarWidth
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "octet.sidebarWidth") }
    }
    static let sidebarMinWidth: CGFloat = 200
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
                        startWidth = start
                        let maxWidth = max(UIState.sidebarMinWidth, (NSApp.keyWindow?.frame.width ?? 1280) / 2)
                        ui.sidebarWidth = min(maxWidth, max(UIState.sidebarMinWidth, (start + drag.translation.width).rounded()))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { ui.sidebarWidth = Theme.sidebarWidth }
            .help("Drag to resize the sidebar. Double-click to reset.")
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(ui.sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 16 : -16
                ui.sidebarWidth = max(UIState.sidebarMinWidth, ui.sidebarWidth + delta)
            }
    }
}

private struct TitleBar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var agents = AgentCenter.shared
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 8) {
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
            .help("Toggle Sidebar (⌘B)")
            .accessibilityLabel(ui.sidebarVisible ? "Hide sidebar" : "Show sidebar")
            Spacer()
            // A connected engine is the normal state and says nothing worth a
            // badge; only the wait for one does.
            if !store.isConnected { connectingIndicator }
            AccountChips()
                .padding(.trailing, 12)
        }
        // Centered on the window, not between the uneven side groups.
        .overlay {
            Button {
                ui.paletteVisible = true
            } label: {
                HStack(spacing: 8) {
                    OctetIcon("magnifyingglass", size: 15)
                    Text(titleText).font(Theme.uiFontMedium).lineLimit(1)
                    Spacer(minLength: 8)
                    Keycap(text: "⌘P")
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(width: 420, height: 26)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .buttonStyle(.plain)
            .help("Command Palette (⌘P)")
            .accessibilityLabel("Search, \(titleText)")
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

    private var titleText: String {
        guard let workspace = window.focusedWorkspace else { return "Octet" }
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

/// Shows the recovery panel under the title bar while sessions are offered.
private struct RecoveryOverlay: View {
    @ObservedObject var recovery: AgentRecoveryController
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if !recovery.offered.isEmpty {
                RecoveryPanel(recovery: recovery)
                    .padding([.trailing, .bottom], 12)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .move(edge: .bottom))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.18)), value: recovery.offered.isEmpty)
        .onChange(of: recovery.offered.isEmpty) { _, empty in
            DebugSnapshot.overlay("recovery", !empty)
        }
    }
}

/// What the terminal area reacts to beyond the view tree: each grid reading
/// and anything else that changes whether a tab is fresh, and a tab drag
/// starting. Kept apart so the window's own view stays small enough to
/// type-check.
private struct TerminalWatchers: ViewModifier {
    @ObservedObject var anchor: TerminalAnchor
    @ObservedObject var tabDrag: TabDrag
    let focusedTab: String?
    let promptEmpty: Bool
    let observe: (TerminalGrid?) -> Void
    let dragChanged: (String?) -> Void
    /// The client has drawn: it can be sent keys.
    let ready: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(anchor.$grid) { grid in
                if grid != nil { ready() }
                observe(grid)
            }
            .onChange(of: focusedTab) { _, _ in observe(anchor.grid) }
            .onChange(of: promptEmpty) { _, _ in observe(anchor.grid) }
            .onChange(of: tabDrag.tabId) { _, dragged in dragChanged(dragged) }
    }
}
