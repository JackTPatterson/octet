import SwiftUI

/// Window layout: title bar, sidebar, tab bar, and the session terminal.
struct RootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let session: EngineSession?
    @ObservedObject var slash: SlashController
    @ObservedObject var prompt: PromptEditor
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var confirmations = ConfirmCenter.shared
    @StateObject private var terminalAnchor = TerminalAnchor()
    @ObservedObject private var agents = AgentCenter.shared

    /// Where the terminal starts across the window.
    private var sidebarInset: CGFloat { ui.sidebarVisible ? ui.sidebarWidth + 1 : 0 }
    private var windowHeight: CGFloat { NSApp.keyWindow?.contentView?.bounds.height ?? 800 }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
                    terminal
                        .overlay {
                            // Clipped to the terminal area, so the board slides
                            // out from behind the sidebar, not over it.
                            ZStack {
                                if agents.board == .claude {
                                    AgentsBoard(store: store)
                                        .transition(motion.animates(.sidebar) ? .move(edge: .leading).combined(with: .opacity) : .identity)
                                } else if agents.board == .codex {
                                    CodexBoard(store: store)
                                        .transition(motion.animates(.sidebar) ? .move(edge: .leading).combined(with: .opacity) : .identity)
                                } else if let conversation = agents.active(in: store.focusedWorkspace?.workspaceId) {
                                    ConversationView(session: conversation, client: store.client)
                                        .id(conversation.id)
                                }
                            }
                            // Full size even while empty, so the clip is a
                            // fixed window the board slides through rather than
                            // a box that grows with it from the center.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            AgentBannerStack(center: AgentBannerCenter.shared) { event in
                store.focus(event)
            }
            .padding(.top, Theme.titleBarHeight + Theme.tabBarHeight)
        }
        .overlay(alignment: .bottomTrailing) {
            // Toasts sit above the recovery panel, both anchored bottom-right.
            VStack(alignment: .trailing, spacing: 8) {
                ToastStack(center: ToastCenter.shared)
                RecoveryOverlay(recovery: store.recovery)
            }
            .id(settings.themeKey)
        }
        .onAppear {
            MarketplaceWindow.opener = { openWindow(id: MarketplaceWindow.id) }
            slash.warmContexts()
            ClipboardWatcher.shared.start()
            #if DEBUG
            // Verification hook: "conversation" opens a native conversation;
            // "conversation:model" also opens that dropdown.
            if let window = ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"], window.hasPrefix("conversation") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    store.newConversation()
                    let parts = window.split(separator: ":").map(String.init)
                    ConversationDebug.openDropdown = parts.dropFirst().first
                    ConversationDebug.scrollToItem = parts.count > 2 ? Int(parts[2]) : nil
                }
            }
            // Verification hook: "codex" opens a native Codex conversation;
            // "codex:<text>" also sends that first message.
            if let window = ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"], window.hasPrefix("codex") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    store.newConversation(engine: .codex)
                    let text = window.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
                    guard let text, let session = AgentCenter.shared.sessions.last else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.send(text) }
                }
            }
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == "agents" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AgentCenter.shared.showingBoard = true }
            }
            // Verification hook: open a window at launch without a click.
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == MarketplaceWindow.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MarketplaceWindow.open() }
            }
            if let window = ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"], window.hasPrefix("slash") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    slash.open(paneId: store.snapshot.panes.first?.paneId ?? "", agent: "claude")
                    // "slash:model" opens that command's submenu too.
                    if let name = window.split(separator: ":").dropFirst().first,
                       let command = slash.commands.first(where: { $0.name == name }) {
                        slash.descend(command)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == "banner" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    AgentBannerCenter.shared.show([
                        AgentEvent(id: "sample-1", kind: .finished, agent: "claude", paneId: "w1:p1", tabId: "w1:t1",
                                   workspaceId: "w1", label: "migrate schema", workedFor: 134, at: Date()),
                        AgentEvent(id: "sample-2", kind: .needsInput, agent: "codex", paneId: "w1:p2", tabId: "w1:t2",
                                   workspaceId: "w1", label: "review auth flow", workedFor: 22, at: Date()),
                    ])
                }
            }
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == "confirm" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ConfirmCenter.shared.ask(
                        title: "Quit Herd?",
                        message: "Your terminals and agents keep running in the background. Reopen Herd to pick up where you left off.",
                        confirmTitle: "Quit",
                        suppressTitle: "Don't ask again"
                    ) { _ in }
                }
            }
            #endif
        }
        .onChange(of: store.lastError) { _, error in
            guard let error else { return }
            ToastCenter.shared.fail(nil, "Terminal request failed", detail: error)
            store.lastError = nil
        }
        .overlay(alignment: .center) {
            if slash.isOpen {
                SlashPaletteView(slash: slash)
                    .padding(.bottom, 40)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.14)), value: slash.isOpen)
        .onChange(of: slash.isOpen) { _, open in DebugSnapshot.overlayVisible = open }
        .onChange(of: confirmations.request?.id) { _, id in DebugSnapshot.overlayVisible = id != nil }
        .onChange(of: store.snapshot.focusedPaneId) { _, _ in slash.resetTyping() }
        .overlay(alignment: .topLeading) {
            // Herd's own command line, drawn over the shell's prompt.
            if prompt.isActive, let anchor = prompt.anchor {
                PromptEditorView(editor: prompt)
                    .frame(width: max(120, CGFloat(anchor.columnsRemaining) * anchor.cellWidth))
                    .offset(x: sidebarInset + anchor.origin.x,
                            y: Theme.titleBarHeight + Theme.tabBarHeight + anchor.origin.y)
                    .allowsHitTesting(false)
            }
            if prompt.isActive, prompt.completionsOpen, let anchor = prompt.anchor {
                // Under the word being completed, or above it near the foot
                // of the window.
                let top = Theme.titleBarHeight + Theme.tabBarHeight + anchor.origin.y
                let below = top + anchor.cellHeight + 4
                let fitsBelow = below + 240 < windowHeight
                CompletionMenuView(editor: prompt)
                    .offset(x: sidebarInset + anchor.origin.x + CGFloat(prompt.completionColumn) * anchor.cellWidth,
                            y: fitsBelow ? below : max(0, top - 244))
            }
        }
        .overlay(alignment: .topLeading) {
            // The engine's chrome row travels down with bottom-anchored
            // content. Only a root-level overlay paints above the hosted
            // terminal view, so the cover lives here rather than on it.
            let _ = { DebugSnapshot.coverActive = terminalAnchor.chromeCover != nil || prompt.isActive }()
            // A conversation covers the terminal, so the patch over the engine's
            // tab row would only show through it.
            if let cover = terminalAnchor.chromeCover, agents.active(in: store.focusedWorkspace?.workspaceId) == nil, agents.board == nil {
                Color(hex: TerminalTheme.named(settings.values.themeName).background)
                    .frame(width: cover.width, height: cover.height)
                    .offset(x: sidebarInset + cover.minX,
                            y: Theme.titleBarHeight + Theme.tabBarHeight + cover.minY)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        : .identity)
            }
        }
        // Above the palette, so a confirm raised while it's open isn't buried.
        .overlay { ConfirmDialog(center: confirmations) }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: ui.paletteVisible)
        .animation(motion.animation(.sidebar), value: ui.sidebarVisible)
        .animation(motion.animation(.sidebar), value: agents.board)
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlayVisible = visible
            if visible {
                store.refreshPlugins()
                palette.reset()
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            } else {
                HerdTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: store.plugins) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            }
        }
        .onChange(of: store.snapshot) { _, snapshot in
            if !snapshot.workspaces.isEmpty {
                AgentCenter.shared.restoreIfNeeded(
                    workspaceFor: { cwd in snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == cwd }?.workspaceId },
                    fallback: store.focusedWorkspace?.workspaceId
                )
            }
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
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

    private func closePalette() {
        ui.paletteVisible = false
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            HerdTerminalView(
                command: session.command,
                environment: session.environment,
                workingDirectory: NSHomeDirectory(),
                hiddenTopRows: EngineSession.hiddenTopRows,
                anchor: terminalAnchor,
                onTitleChange: { _ in },
                onExit: { NSApp.terminate(nil) }
            )
            .background(Color(hex: TerminalTheme.named(settings.values.themeName).background)
                .opacity(settings.values.effectiveBackgroundOpacity))

        } else {
            VStack(spacing: 8) {
                Text("Terminal engine missing").font(.system(size: 14, weight: .semibold))
                Text("The terminal engine is missing from this copy of Herd. Reinstall Herd.")
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
            HerdTerminalRuntime.applyBackgroundBlur(to: window)
        }
    }
}

final class UIState: ObservableObject {
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "herd.sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "herd.sidebarVisible") }
    }
    @Published var paletteVisible = false
    /// Drag the sidebar's edge to resize it (200pt up to half the window).
    @Published var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "herd.sidebarWidth")
        return saved > 0 ? CGFloat(saved) : Theme.sidebarWidth
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "herd.sidebarWidth") }
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
    @ObservedObject private var agents = AgentCenter.shared
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights, which hide in full screen.
            Color.clear.frame(width: isFullScreen ? 4 : 70)
            Button {
                ui.sidebarVisible.toggle()
            } label: {
                HerdIcon("sidebar.left", size: 18)
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
                    HerdIcon("magnifyingglass", size: 15)
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
        guard let workspace = store.focusedWorkspace else { return "Herd" }
        // A conversation in front names itself, not the terminal behind it.
        if let conversation = agents.active(in: workspace.workspaceId) {
            return [workspace.label, conversation.title].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let tab = store.focusedWorkspaceTabs.first { $0.tabId == store.displayedFocusedTabId }
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
            DebugSnapshot.overlayVisible = !empty
        }
    }
}
