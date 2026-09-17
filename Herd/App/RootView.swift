import SwiftUI

/// Window layout: Warp title bar, sidebar, tab bar, and the herdr terminal.
struct RootView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState
    let session: HerdrSession?
    @ObservedObject var slash: SlashController
    @ObservedObject var prompt: PromptEditor
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var confirmations = ConfirmCenter.shared
    @StateObject private var terminalAnchor = TerminalAnchor()

    /// Where the terminal starts across the window.
    private var sidebarInset: CGFloat { ui.sidebarVisible ? Theme.sidebarWidth + 1 : 0 }
    private var windowHeight: CGFloat { NSApp.keyWindow?.contentView?.bounds.height ?? 800 }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Chrome views are re-identified per theme so every color
            // re-resolves; the terminal keeps its identity (and herdr client).
            TitleBar(store: store, ui: ui)
                .id(settings.values.themeName)
            HStack(spacing: 0) {
                if ui.sidebarVisible {
                    HStack(spacing: 0) {
                        SidebarView(store: store)
                        Rectangle().fill(Theme.divider).frame(width: 1)
                    }
                    .id(settings.values.themeName)
                    .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                }
                VStack(spacing: 0) {
                    TabBarView(store: store)
                        .id(settings.values.themeName)
                    terminal
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // The engine's chrome row travels down with bottom-anchored
            // content, and only a root-level overlay paints above the hosted
            // terminal view. It goes on first, so Herd's own panels are never
            // painted over by it.
            ChromeCover(anchor: terminalAnchor, twin: store.twin, prompt: prompt, sidebarInset: sidebarInset)
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
            .id(settings.values.themeName)
        }
        .onAppear {
            MarketplaceWindow.opener = { openWindow(id: MarketplaceWindow.id) }
            AgentBoardWindow.opener = { openWindow(id: AgentBoardWindow.id) }
            slash.warmContexts()
            ClipboardWatcher.shared.start()
            #if DEBUG
            // Verification hook: open a window at launch without a click.
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == MarketplaceWindow.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MarketplaceWindow.open() }
            }
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == AgentBoardWindow.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AgentBoardWindow.open() }
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
            if ProcessInfo.processInfo.environment["HERD_OPEN_WINDOW"] == "twin" {
                // Opens the twin as soon as an agent pane exists.
                @MainActor func tryOpen(_ attempt: Int) {
                    guard attempt < 30 else { return }
                    if store.twin.canShow {
                        store.twin.show()
                        // Verification types into the twin, which needs the
                        // window to be the one receiving keys.
                        NSApp.activate(ignoringOtherApps: true)
                        if ProcessInfo.processInfo.environment["HERD_TWIN_ANSWER"] != nil { answerWhenAsked(0) }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { tryOpen(attempt + 1) } }
                }
                @MainActor func answerWhenAsked(_ attempt: Int) {
                    guard attempt < 30 else { return }
                    if let option = store.twin.approval?.options.first {
                        store.twin.answer(option)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { answerWhenAsked(attempt + 1) } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { tryOpen(0) } }
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
        .onChange(of: slash.isOpen) { _, open in DebugSnapshot.overlay("slash", open) }
        .onChange(of: confirmations.request?.id) { _, id in DebugSnapshot.overlay("confirm", id != nil) }
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
        .overlay { ConfirmDialog(center: confirmations) }
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: ui.paletteVisible)
        .animation(motion.animation(.sidebar), value: ui.sidebarVisible)
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlay("palette", visible)
            if visible {
                store.refreshPlugins()
                store.refreshRemoteMachines()
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
        .onChange(of: store.snapshot) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            }
        }
        .background(settings.values.backgroundOpacity < 1 ? Color.clear : Theme.terminalBackground)
        .background(WindowTransparency(
            opacity: settings.values.backgroundOpacity,
            blur: settings.values.backgroundBlur,
            themeName: settings.values.themeName
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
                hiddenTopRows: HerdrSession.hiddenTopRows,
                anchor: terminalAnchor,
                onTitleChange: { _ in },
                onExit: { NSApp.terminate(nil) }
            )
            .background(Color(hex: TerminalTheme.named(settings.values.themeName).background)
                .opacity(settings.values.backgroundOpacity))
            // The twin draws over the pane it is showing; the real terminal
            // keeps running underneath, which is what it is a twin of.
            .overlay { TwinLayer(twin: store.twin, store: store) }

        } else {
            VStack(spacing: 8) {
                Text("Terminal engine missing").font(.system(size: 14, weight: .semibold))
                Text("Install it with `brew install herdr`, then relaunch Herd.")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
        }
    }
}

/// Makes the window see-through when the terminal background is translucent,
/// and applies Ghostty's background blur.
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

/// Hides the engine's chrome row where it rides down with bottom-anchored
/// content. There is nothing to cover while the twin is up, since none of the
/// terminal is showing.
private struct ChromeCover: View {
    @ObservedObject var anchor: TerminalAnchor
    @ObservedObject var twin: TwinSession
    @ObservedObject var prompt: PromptEditor
    @ObservedObject private var settings = SettingsStore.shared
    let sidebarInset: CGFloat

    var body: some View {
        let cover = twin.isVisible ? nil : anchor.chromeCover
        let _ = { DebugSnapshot.coverActive = cover != nil || prompt.isActive }()
        if let cover {
            Color(hex: TerminalTheme.named(settings.values.themeName).background)
                .frame(width: cover.width, height: cover.height)
                .offset(x: sidebarInset + cover.minX,
                        y: Theme.titleBarHeight + Theme.tabBarHeight + cover.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Shows the visual twin over the terminal while it is on for this pane.
private struct TwinLayer: View {
    @ObservedObject var twin: TwinSession
    @ObservedObject var store: HerdrStore
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if settings.values.visualTwin, twin.isVisible {
                TwinView(twin: twin, store: store)
                    .transition(motion.animates(.palette) ? .opacity : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: twin.isVisible)
        .onChange(of: twin.isVisible) { _, visible in DebugSnapshot.overlay("twin", visible) }
    }
}

final class UIState: ObservableObject {
    @Published var sidebarVisible = true
    @Published var paletteVisible = false
}

private struct TitleBar: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights.
            Color.clear.frame(width: 70)
            Button {
                ui.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(ui.sidebarVisible ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 28, height: 24)
                    .background(ui.sidebarVisible ? Theme.cardSelected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (⌘B)")
            Spacer()
            Button {
                ui.paletteVisible = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
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
            Spacer()
            connectionIndicator
                .padding(.trailing, 12)
        }
        .frame(height: Theme.titleBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var titleText: String {
        guard let workspace = store.focusedWorkspace else { return "Herd" }
        let tab = store.focusedWorkspaceTabs.first { $0.tabId == store.snapshot.focusedTabId }
        return [workspace.label, tab?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var connectionIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.isConnected ? Color(hex: AgentStateColor.done) : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(store.isConnected ? "ready" : "connecting")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
        }
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
