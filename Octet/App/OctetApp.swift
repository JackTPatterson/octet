import Carbon
import Sparkle
import SwiftUI

@main
struct OctetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @StateObject private var marketplace: MarketplaceStore
    @StateObject private var prompt: PromptEditor
    private let session: EngineSession?
    private let updaterController: SPUStandardUpdaterController

    @MainActor private static var started = false

    init() {
        // Sparkle owns the native update-found, install, and relaunch prompts.
        // Its schedule and signing configuration live in Info.plist.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // IDEs and parent agents commonly export NO_COLOR for their own logs.
        // Octet is a real PTY, so that host-only preference must not erase the
        // native colors of Claude, Codex, shells, or any other terminal app.
        TerminalEnvironment.clearInheritedColorSuppression()
        let session = EngineSession.make()
        let settings = SettingsStore.shared
        settings.sessionConfigPath = session?.configPath
        settings.writeSessionConfig()
        self.session = session
        // Launched from inside an agent's shell, Octet would hand that agent's
        // session markers to every pane it opens.
        AgentEnvironment.clearInheritedMarkers()
        let socketPath = session?.socketPath ?? EngineClient.socketPath(session: EngineSession.name)
        let store = SessionStore(client: EngineClient(socketPath: socketPath))
        _store = StateObject(wrappedValue: store)
        _marketplace = StateObject(wrappedValue: MarketplaceStore(session: store))
        let prompt = PromptEditor(store: store)
        _prompt = StateObject(wrappedValue: prompt)
        OctetKeyHook.prompt = prompt
        OctetKeyHook.store = store
        OctetPluginHost.shared.attach(store)
        // After the window is up, so the question has somewhere to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session?.offerColorRestartIfNeeded() }
        settings.reloadSession = { [weak store] in store?.reloadSessionConfig(quiet: true) }
        OctetTerminalRuntime.configure(overrides: settings.values.rendererConfig + "\n" + Theme.octetShortcutUnbinds)
        OctetTerminalRuntime.setColorScheme(dark: !TerminalTheme.named(settings.values.themeName).isLight)
    }

    var body: some Scene {
        // Each window is its own client of the one engine session, showing
        // a workspace of its own; what it was opened for comes back with it.
        WindowGroup(for: OctetWindowSpec.self) { $spec in
            OctetWindowRoot(spec: spec, store: store, session: session, prompt: prompt)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    // Once for the app, not once per window.
                    guard !Self.started else { return }
                    Self.started = true
                    store.start()
                    AccountStore.shared.start()
                    AgentsStore.shared.start()
                    CodexAgentsStore.shared.start()
                    AgentDiscoveryStore.shared.scanIfStale()
                    repairInstalledSubagentHooks()
                    DebugSnapshot.start()
                }
        } defaultValue: {
            OctetWindowSpec()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { OctetCommands(store: store, updater: updaterController.updater) }

        Settings {
            SettingsView(store: store)
        }
        Window("Marketplace", id: "marketplace") {
            MarketplaceView(store: marketplace)
        }
        .defaultSize(width: 900, height: 620)
        Window("Running Terminal Agents", id: "terminal-agents") {
            AgentBoardView(store: store) { agent in
                WindowRegistry.shared.key?.focus(AgentEvent(id: agent.paneId, kind: .finished, agent: agent.agent,
                                       paneId: agent.paneId, tabId: agent.tabId,
                                       workspaceId: agent.workspaceId, label: "", workedFor: nil, at: Date()))
            }
        }
        .defaultSize(width: 620, height: 460)
    }

    /// Preserve the user's existing opt-in while repairing paths after an
    /// app rename, a new build location, or an update. Hooks that were never
    /// installed remain untouched.
    private func repairInstalledSubagentHooks() {
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else { return }
        for spec in SubagentHookInstaller.available() where SubagentHookInstaller.isInstalled(spec) {
            _ = try? SubagentHookInstaller.install(cliPath: cli, spec: spec)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Octet has its own tabs; macOS window tabs would add a second row
        // and a second terminal client sharing one UI state.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Restores a saved Secure Keyboard Entry choice.
        _ = SecureInput.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    static var hasVisibleTerminalWindow: Bool {
        WindowRegistry.shared.windows.contains { $0.nsWindow?.isVisible == true }
            || MainWindow.window?.isVisible == true
    }

    /// Finder's “Open With Octet” and `open -a Octet file` are full-editor
    /// intents. In-app ⌘O is terminal context and starts as a split instead.
    @MainActor
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openWhenReady(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    @MainActor
    private func openWhenReady(_ urls: [URL], attempts: Int = 0) {
        guard let window = WindowRegistry.shared.key else {
            guard attempts < 30 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openWhenReady(urls, attempts: attempts + 1)
            }
            return
        }
        window.bringForward()
        for url in urls { window.openFile(url, presentation: .full) }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SettingsStore.shared.values.confirmQuit else { return .terminateNow }
        // Octet's dialog is drawn inside a terminal window. With none left
        // (the last one just closed) nothing could show it, and the quit
        // would wait forever; quitting loses nothing, the session keeps
        // running.
        guard Self.hasVisibleTerminalWindow else { return .terminateNow }
        // Octet's own dialog, so the answer arrives asynchronously.
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Quit Octet?",
            message: "Your terminals and agents keep running in the background. Reopen Octet to pick up where you left off.",
            confirmTitle: "Quit",
            suppressTitle: "Don't ask again",
            onConfirm: { suppress in
                if suppress { SettingsStore.shared.values.confirmQuit = false }
                NSApp.reply(toApplicationShouldTerminate: true)
            },
            onCancel: { NSApp.reply(toApplicationShouldTerminate: false) }
        ))
        return .terminateLater
    }
}

/// Shortcuts come from `OctetShortcut`, which the Settings Keyboard page lists too.
/// Each acts on the terminal window in front.
struct OctetCommands: Commands {
    let store: SessionStore
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updater: updater)
        }
        CommandGroup(replacing: .newItem) {
            Button(OctetShortcut.newTab.title) { KeyWindow.act { $0.newTab() } }
                .keyboardShortcut(OctetShortcut.newTab.keyboardShortcut)
            Button(OctetShortcut.newConversation.title) { KeyWindow.act { $0.newConversation() } }
                .keyboardShortcut(OctetShortcut.newConversation.keyboardShortcut)
            // Codex's has no shortcut of its own: ⌘⇧N belongs to Claude's,
            // and a second chord for the same thing isn't worth the key.
            Button("New Codex Conversation") { KeyWindow.act { $0.newConversation(engine: .codex) } }
            Button("New OpenCode Conversation") { KeyWindow.act { $0.newConversation(engine: .opencode) } }
            Button("New Pi Conversation") { KeyWindow.act { $0.newConversation(engine: .pi) } }
            Button("New Qwen Conversation") { KeyWindow.act { $0.newConversation(engine: .qwen) } }
            Button(OctetShortcut.agents.title) { KeyWindow.act { $0.toggleAgentsBoard() } }
                .keyboardShortcut(OctetShortcut.agents.keyboardShortcut)
            Button(OctetShortcut.newWorkspace.title) { KeyWindow.act { $0.newWorkspace() } }
                .keyboardShortcut(OctetShortcut.newWorkspace.keyboardShortcut)
            Button(OctetShortcut.newWindow.title) { WindowActions.newWindow(store: store) }
                .keyboardShortcut(OctetShortcut.newWindow.keyboardShortcut)
            Button(OctetShortcut.openFile.title) { KeyWindow.act { $0.showFilePicker() } }
                .keyboardShortcut(OctetShortcut.openFile.keyboardShortcut)
            Button(OctetShortcut.openFolder.title) { KeyWindow.act { PaletteCatalog.openFolder(window: $0) } }
                .keyboardShortcut(OctetShortcut.openFolder.keyboardShortcut)
            Divider()
            // ⌘W closes Settings or Marketplace when one of them is in front.
            Button(OctetShortcut.closeTab.title) {
                if MainWindow.isKey { KeyWindow.act { $0.closeFocusedTab() } } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut(OctetShortcut.closeTab.keyboardShortcut)
            Button(OctetShortcut.reopenClosedTab.title) { KeyWindow.act { $0.reopenClosedTab() } }
                .keyboardShortcut(OctetShortcut.reopenClosedTab.keyboardShortcut)
            RecentlyClosedMenu(closed: store.closedTabs)
        }
        CommandGroup(replacing: .saveItem) {
            Button(OctetShortcut.saveFile.title) { KeyWindow.act { $0.editor.save() } }
                .keyboardShortcut(OctetShortcut.saveFile.keyboardShortcut)
            Button("Save All") { KeyWindow.act { $0.editor.saveAll() } }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandGroup(after: .appSettings) {
            Button(OctetShortcut.marketplace.title) { MarketplaceWindow.open() }
                .keyboardShortcut(OctetShortcut.marketplace.keyboardShortcut)
            SecureKeyboardEntryToggle()
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                KeyWindow.act { context in
                    context.editor.isPresented ? context.editor.find() : context.findOutput()
                }
            }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") {
                KeyWindow.act { context in
                    context.editor.isPresented ? context.editor.find(.nextMatch) : context.findOutput(.nextMatch)
                }
            }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") {
                KeyWindow.act { context in
                    context.editor.isPresented ? context.editor.find(.previousMatch) : context.findOutput(.previousMatch)
                }
            }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(OctetShortcut.palette.title) { KeyWindow.act { $0.ui.paletteVisible.toggle() } }
                .keyboardShortcut(OctetShortcut.palette.keyboardShortcut)
            Button(OctetShortcut.paletteAll.title) { KeyWindow.act { $0.ui.paletteVisible.toggle() } }
                .keyboardShortcut(OctetShortcut.paletteAll.keyboardShortcut)
            Button(OctetShortcut.visualTwin.title) { KeyWindow.act { $0.twin.toggle() } }
                .keyboardShortcut(OctetShortcut.visualTwin.keyboardShortcut)
            Button(OctetShortcut.review.title) { KeyWindow.act { $0.toggleReview() } }
                .keyboardShortcut(OctetShortcut.review.keyboardShortcut)
            // The workspace's agents, else every agent, else the tab's panes.
            Button(OctetShortcut.broadcast.title) {
                KeyWindow.act { window in
                    window.ui.paletteStart = ["action.broadcast.workspace", "action.broadcast.everywhere", "action.broadcast.tab"]
                    window.ui.paletteVisible = true
                }
            }
            .keyboardShortcut(OctetShortcut.broadcast.keyboardShortcut)
            Button(OctetShortcut.toggleSidebar.title) { KeyWindow.act { $0.ui.sidebarVisible.toggle() } }
                .keyboardShortcut(OctetShortcut.toggleSidebar.keyboardShortcut)
            Divider()
            // The terminal's own zoom keys are unbound (Theme.octetShortcutUnbinds),
            // so these change the Font size setting instead of one pane.
            Button(OctetShortcut.increaseFontSize.title) { MainWindow.perform { SettingsStore.shared.adjustFontSize(by: 1) } }
                .keyboardShortcut(OctetShortcut.increaseFontSize.keyboardShortcut)
            Button(OctetShortcut.decreaseFontSize.title) { MainWindow.perform { SettingsStore.shared.adjustFontSize(by: -1) } }
                .keyboardShortcut(OctetShortcut.decreaseFontSize.keyboardShortcut)
            Button(OctetShortcut.resetFontSize.title) { MainWindow.perform { SettingsStore.shared.resetFontSize() } }
                .keyboardShortcut(OctetShortcut.resetFontSize.keyboardShortcut)
        }
        CommandMenu("Pane") {
            Button(OctetShortcut.splitRight.title) { KeyWindow.act { $0.splitPane(.right) } }
                .keyboardShortcut(OctetShortcut.splitRight.keyboardShortcut)
            Button(OctetShortcut.splitDown.title) { KeyWindow.act { $0.splitPane(.down) } }
                .keyboardShortcut(OctetShortcut.splitDown.keyboardShortcut)
            Button(OctetShortcut.toggleZoom.title) { KeyWindow.act { $0.toggleZoom() } }
                .keyboardShortcut(OctetShortcut.toggleZoom.keyboardShortcut)
            Button("Close Pane") { KeyWindow.act { $0.closeFocusedPane() } }
            Button("Move Pane to New Tab") { KeyWindow.act { $0.moveFocusedPaneToNewTab() } }
            Divider()
            Button(OctetShortcut.focusLeft.title) { KeyWindow.act { $0.focusPane(.left) } }
                .keyboardShortcut(OctetShortcut.focusLeft.keyboardShortcut)
            Button(OctetShortcut.focusRight.title) { KeyWindow.act { $0.focusPane(.right) } }
                .keyboardShortcut(OctetShortcut.focusRight.keyboardShortcut)
            Button(OctetShortcut.focusUp.title) { KeyWindow.act { $0.focusPane(.up) } }
                .keyboardShortcut(OctetShortcut.focusUp.keyboardShortcut)
            Button(OctetShortcut.focusDown.title) { KeyWindow.act { $0.focusPane(.down) } }
                .keyboardShortcut(OctetShortcut.focusDown.keyboardShortcut)
        }
        CommandMenu("Navigate") {
            Button(OctetShortcut.nextTab.title) { KeyWindow.act { $0.selectAdjacentTab(offset: 1) } }
                .keyboardShortcut(OctetShortcut.nextTab.keyboardShortcut)
            Button(OctetShortcut.previousTab.title) { KeyWindow.act { $0.selectAdjacentTab(offset: -1) } }
                .keyboardShortcut(OctetShortcut.previousTab.keyboardShortcut)
            Divider()
            Button(OctetShortcut.nextWorkspace.title) { KeyWindow.act { $0.selectAdjacentWorkspace(offset: 1) } }
                .keyboardShortcut(OctetShortcut.nextWorkspace.keyboardShortcut)
            Button(OctetShortcut.previousWorkspace.title) { KeyWindow.act { $0.selectAdjacentWorkspace(offset: -1) } }
                .keyboardShortcut(OctetShortcut.previousWorkspace.keyboardShortcut)
            Divider()
            ForEach(1...9, id: \.self) { number in
                let shortcut = OctetShortcut.tab(number)
                Button(shortcut.title) { KeyWindow.act { $0.selectTab(number: number) } }
                    .keyboardShortcut(shortcut.keyboardShortcut)
            }
        }
        // Window mechanics after the system's own Window items, the way
        // browsers and editors put them.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Move Tab to New Window") { KeyWindow.act { WindowActions.moveFocusedTabToNewWindow(from: $0) } }
            Button("Merge All Windows") { WindowActions.mergeAllWindows() }
                .disabled(false)
        }
        // Replaces SwiftUI's item that only says help isn't available.
        CommandGroup(replacing: .help) {
            Button("Octet Help") { OctetHelp.openReadme() }
            KeyboardShortcutsMenuItem()
        }
    }
}

/// Keeps the application-menu item's enabled state in sync with Sparkle while
/// Sparkle performs a check, download, or pending installation.
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        model = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

/// Palette and Settings actions for the subagent tabs hook, for any agent that has one.
enum SubagentHookMenu {
    @MainActor
    static func install(_ spec: SubagentHookSpec? = nil) {
        let toasts = ToastCenter.shared
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else {
            toasts.fail(nil, "Couldn't install the subagent tabs hook", detail: "octet-cli is missing from the app bundle")
            return
        }
        let specs = spec.map { [$0] } ?? SubagentHookInstaller.available()
        guard !specs.isEmpty else {
            toasts.info("No agent to install into", detail: "Octet found no agent config on this machine")
            return
        }
        let handle = toasts.progress("Installing the subagent tabs hook…")
        var installed: [String] = []
        for spec in specs {
            do {
                _ = try SubagentHookInstaller.install(cliPath: cli, spec: spec)
                installed.append(spec.displayName)
            } catch {
                toasts.fail(handle, "Couldn't update \(spec.file)", detail: String(describing: error))
                return
            }
        }
        toasts.succeed(handle, "Installed the subagent tabs hook",
                       detail: "New sessions in \(installed.joined(separator: ", ")) open a tab per subagent")
    }

    @MainActor
    static func uninstall(_ spec: SubagentHookSpec? = nil) {
        let toasts = ToastCenter.shared
        let specs = spec.map { [$0] } ?? SubagentHookInstaller.available()
        let handle = toasts.progress("Removing the subagent tabs hook…")
        for spec in specs {
            do {
                _ = try SubagentHookInstaller.uninstall(spec: spec)
            } catch {
                toasts.fail(handle, "Couldn't update \(spec.file)", detail: String(describing: error))
                return
            }
        }
        toasts.succeed(handle, "Removed the subagent tabs hook")
    }
}

/// Opens the Marketplace window from menus and the palette. RootView hands
/// over SwiftUI's `openWindow`, which is only available inside a view.
@MainActor
enum MarketplaceWindow {
    static let id = "marketplace"
    static var opener: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}


/// Static bridge so the terminal surface can consult Octet's command line without
/// knowing about Octet's stores.
@MainActor
enum OctetKeyHook {
    static weak var prompt: PromptEditor?

    static weak var store: SessionStore?
    /// Set while the prompt editor hands held keys back to the terminal.
    static var replaying = false

    static func paste(from pasteboard: NSPasteboard = .general, plainText: Bool = false) -> Bool {
        guard ConfirmCenter.shared.request == nil else { return true }
        if !plainText, pasteboard === NSPasteboard.general,
           let store, PasteHandler.handleCommandV(store: store) { return true }
        guard let text = pasteboard.getOpinionatedStringContents() else {
            return prompt?.isActive == true
        }
        if let store, PastePreviewCenter.shared.intercept(text, store: store) { return true }
        return prompt?.insertPastedText(text) ?? false
    }

    static func handleKeyDown(_ event: NSEvent) -> Bool {
        if replaying { return false }
        // A dialog over the terminal owns the keyboard. Its buttons' Return
        // and Esc equivalents don't reach it past the terminal, so they're
        // answered here.
        if let request = ConfirmCenter.shared.request,
           request.window == nil || request.window === event.window {
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            switch event.keyCode {
            case 36 where plain, 76 where plain: ConfirmCenter.shared.confirm()
            case 53 where !request.cancelTitle.isEmpty: ConfirmCenter.shared.cancel()
            default: break
            }
            return true
        }
        // Input methods and dead keys compose text over several keystrokes;
        // raw key codes would break Japanese, Chinese, Korean and Option-accents.
        if isComposing(event) { return false }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v", paste() { return true }
        // ⌘↑ / ⌘↓: previous and next prompt in a shell's scrollback.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.keyCode == 126 || event.keyCode == 125, let store,
           PromptJumper.handle(event.keyCode == 126 ? .up : .down, store: store) { return true }
        // Shell prompts get Octet's own line; agents keep their own `/` menus.
        return prompt?.handleKeyDown(event) ?? false
    }
}

@MainActor
private func isComposing(_ event: NSEvent) -> Bool {
    if let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return true }
    // A dead key (Option-e, Option-u…) produces no characters on its own.
    if event.characters?.isEmpty ?? true, event.modifierFlags.intersection([.command, .control]).isEmpty { return true }
    // CJK and other non-ASCII input sources run through an input method.
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
    return !CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
}

/// The terminal window. Tab, pane and sidebar shortcuts act on it only, so
/// they do nothing while Settings or Marketplace is in front.
@MainActor
enum MainWindow {
    static weak var window: NSWindow?

    /// A terminal window is in front: any of them, now there can be several.
    static var isKey: Bool {
        guard let key = NSApp.keyWindow else { return true }
        return key === window || WindowRegistry.shared.windows.contains { $0.nsWindow === key }
    }

    static func perform(_ action: () -> Void) {
        if isKey { action() }
    }
}

/// Octet menu checkbox for Secure Keyboard Entry, like Terminal's.
struct SecureKeyboardEntryToggle: View {
    @ObservedObject private var secure = SecureInput.shared

    var body: some View {
        Toggle("Secure Keyboard Entry", isOn: $secure.global)
    }
}

@MainActor
enum AgentBoardWindow {
    static let id = "terminal-agents"
    static var opener: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

/// File › Recently Closed: every closed tab still running, newest first.
private struct RecentlyClosedMenu: View {
    @ObservedObject var closed: ClosedTabsController

    var body: some View {
        Menu("Recently Closed") {
            ForEach(closed.records.reversed()) { record in
                Button(record.command.map { "\(record.title) — \(ShellRecovery.short($0, limit: 40))" } ?? record.title) {
                    KeyWindow.act { $0.reopenClosedTab(record) }
                }
            }
            if !closed.records.isEmpty {
                Divider()
                Button("End All Closed Tabs") { closed.closeAll() }
            }
        }
        .disabled(closed.records.isEmpty)
    }
}
