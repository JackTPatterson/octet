import Carbon
import SwiftUI

@main
struct HerdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @StateObject private var ui = UIState()
    @StateObject private var marketplace: MarketplaceStore
    @StateObject private var slash: SlashController
    @StateObject private var prompt: PromptEditor
    private let session: EngineSession?

    init() {
        let session = EngineSession.make()
        let settings = SettingsStore.shared
        settings.sessionConfigPath = session?.configPath
        settings.writeSessionConfig()
        self.session = session
        // Launched from inside an agent's shell, Herd would hand that agent's
        // session markers to every pane it opens.
        AgentEnvironment.clearInheritedMarkers()
        let socketPath = session?.socketPath ?? EngineClient.socketPath(session: EngineSession.name)
        let store = SessionStore(client: EngineClient(socketPath: socketPath))
        _store = StateObject(wrappedValue: store)
        _marketplace = StateObject(wrappedValue: MarketplaceStore(session: store))
        let slash = SlashController(store: store)
        _slash = StateObject(wrappedValue: slash)
        HerdKeyHook.controller = slash
        let prompt = PromptEditor(store: store)
        _prompt = StateObject(wrappedValue: prompt)
        HerdKeyHook.prompt = prompt
        HerdKeyHook.store = store
        settings.reloadSession = { [weak store] in store?.reloadSessionConfig(quiet: true) }
        HerdTerminalRuntime.configure(overrides: settings.values.rendererConfig + "\n" + Theme.herdShortcutUnbinds)
        HerdTerminalRuntime.setColorScheme(dark: !TerminalTheme.named(settings.values.themeName).isLight)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, ui: ui, session: session, slash: slash, prompt: prompt)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    store.start()
                    AccountStore.shared.start()
                    AgentsStore.shared.start()
                    CodexAgentsStore.shared.start()
                    AgentDiscoveryStore.shared.scanIfStale()
                    DebugSnapshot.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { HerdCommands(store: store, ui: ui) }

        Settings {
            SettingsView(store: store)
        }
        Window("Marketplace", id: "marketplace") {
            MarketplaceView(store: marketplace)
        }
        .defaultSize(width: 900, height: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Herd has its own tabs; macOS window tabs would add a second row
        // and a second terminal client sharing one UI state.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Restores a saved Secure Keyboard Entry choice.
        _ = SecureInput.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SettingsStore.shared.values.confirmQuit else { return .terminateNow }
        // Herd's own dialog, so the answer arrives asynchronously.
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "Quit Herd?",
            message: "Your terminals and agents keep running in the background. Reopen Herd to pick up where you left off.",
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

/// Shortcuts come from `HerdShortcut`, which the Settings Keyboard page lists too.
struct HerdCommands: Commands {
    let store: SessionStore
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(HerdShortcut.newTab.title) { MainWindow.perform { store.newTab() } }
                .keyboardShortcut(HerdShortcut.newTab.keyboardShortcut)
            Button(HerdShortcut.newConversation.title) { MainWindow.perform { store.newConversation() } }
                .keyboardShortcut(HerdShortcut.newConversation.keyboardShortcut)
            // Codex's has no shortcut of its own: ⌘⇧N belongs to Claude's,
            // and a second chord for the same thing isn't worth the key.
            Button("New Codex Conversation") { MainWindow.perform { store.newConversation(engine: .codex) } }
            Button(HerdShortcut.agents.title) { MainWindow.perform { store.toggleAgentsBoard() } }
                .keyboardShortcut(HerdShortcut.agents.keyboardShortcut)
            Button(HerdShortcut.newWorkspace.title) { MainWindow.perform { store.newWorkspace() } }
                .keyboardShortcut(HerdShortcut.newWorkspace.keyboardShortcut)
            Button(HerdShortcut.openFolder.title) { PaletteCatalog.openFolder(store: store) }
                .keyboardShortcut(HerdShortcut.openFolder.keyboardShortcut)
            Divider()
            // ⌘W closes Settings or Marketplace when one of them is in front.
            Button(HerdShortcut.closeTab.title) {
                if MainWindow.isKey { store.closeFocusedTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut(HerdShortcut.closeTab.keyboardShortcut)
        }
        CommandGroup(after: .appSettings) {
            Button(HerdShortcut.marketplace.title) { MarketplaceWindow.open() }
                .keyboardShortcut(HerdShortcut.marketplace.keyboardShortcut)
            SecureKeyboardEntryToggle()
        }
        CommandGroup(after: .sidebar) {
            Button(HerdShortcut.palette.title) { MainWindow.perform { ui.paletteVisible.toggle() } }
                .keyboardShortcut(HerdShortcut.palette.keyboardShortcut)
            Button(HerdShortcut.paletteAll.title) { MainWindow.perform { ui.paletteVisible.toggle() } }
                .keyboardShortcut(HerdShortcut.paletteAll.keyboardShortcut)
            Button(HerdShortcut.toggleSidebar.title) { MainWindow.perform { ui.sidebarVisible.toggle() } }
                .keyboardShortcut(HerdShortcut.toggleSidebar.keyboardShortcut)
            Divider()
            // The terminal's own zoom keys are unbound (Theme.herdShortcutUnbinds),
            // so these change the Font size setting instead of one pane.
            Button(HerdShortcut.increaseFontSize.title) { MainWindow.perform { SettingsStore.shared.adjustFontSize(by: 1) } }
                .keyboardShortcut(HerdShortcut.increaseFontSize.keyboardShortcut)
            Button(HerdShortcut.decreaseFontSize.title) { MainWindow.perform { SettingsStore.shared.adjustFontSize(by: -1) } }
                .keyboardShortcut(HerdShortcut.decreaseFontSize.keyboardShortcut)
            Button(HerdShortcut.resetFontSize.title) { MainWindow.perform { SettingsStore.shared.resetFontSize() } }
                .keyboardShortcut(HerdShortcut.resetFontSize.keyboardShortcut)
        }
        CommandMenu("Pane") {
            Button(HerdShortcut.splitRight.title) { MainWindow.perform { store.splitPane(.right) } }
                .keyboardShortcut(HerdShortcut.splitRight.keyboardShortcut)
            Button(HerdShortcut.splitDown.title) { MainWindow.perform { store.splitPane(.down) } }
                .keyboardShortcut(HerdShortcut.splitDown.keyboardShortcut)
            Button(HerdShortcut.toggleZoom.title) { MainWindow.perform { store.toggleZoom() } }
                .keyboardShortcut(HerdShortcut.toggleZoom.keyboardShortcut)
            Button("Close Pane") { MainWindow.perform { store.closeFocusedPane() } }
            Divider()
            Button(HerdShortcut.focusLeft.title) { MainWindow.perform { store.focusPane(.left) } }
                .keyboardShortcut(HerdShortcut.focusLeft.keyboardShortcut)
            Button(HerdShortcut.focusRight.title) { MainWindow.perform { store.focusPane(.right) } }
                .keyboardShortcut(HerdShortcut.focusRight.keyboardShortcut)
            Button(HerdShortcut.focusUp.title) { MainWindow.perform { store.focusPane(.up) } }
                .keyboardShortcut(HerdShortcut.focusUp.keyboardShortcut)
            Button(HerdShortcut.focusDown.title) { MainWindow.perform { store.focusPane(.down) } }
                .keyboardShortcut(HerdShortcut.focusDown.keyboardShortcut)
        }
        CommandMenu("Navigate") {
            Button(HerdShortcut.nextTab.title) { MainWindow.perform { store.selectAdjacentTab(offset: 1) } }
                .keyboardShortcut(HerdShortcut.nextTab.keyboardShortcut)
            Button(HerdShortcut.previousTab.title) { MainWindow.perform { store.selectAdjacentTab(offset: -1) } }
                .keyboardShortcut(HerdShortcut.previousTab.keyboardShortcut)
            Divider()
            Button(HerdShortcut.nextWorkspace.title) { MainWindow.perform { store.selectAdjacentWorkspace(offset: 1) } }
                .keyboardShortcut(HerdShortcut.nextWorkspace.keyboardShortcut)
            Button(HerdShortcut.previousWorkspace.title) { MainWindow.perform { store.selectAdjacentWorkspace(offset: -1) } }
                .keyboardShortcut(HerdShortcut.previousWorkspace.keyboardShortcut)
            Divider()
            ForEach(1...9, id: \.self) { number in
                let shortcut = HerdShortcut.tab(number)
                Button(shortcut.title) { MainWindow.perform { store.selectTab(number: number) } }
                    .keyboardShortcut(shortcut.keyboardShortcut)
            }
        }
        // Replaces SwiftUI's item that only says help isn't available.
        CommandGroup(replacing: .help) {
            Button("Herd Help") { HerdHelp.openReadme() }
            KeyboardShortcutsMenuItem()
        }
    }
}

/// Palette and Settings actions for the subagent tabs hook, for any agent that has one.
enum SubagentHookMenu {
    @MainActor
    static func install(_ spec: SubagentHookSpec? = nil) {
        let toasts = ToastCenter.shared
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "herd-cli")?.path else {
            toasts.fail(nil, "Couldn't install the subagent tabs hook", detail: "herd-cli is missing from the app bundle")
            return
        }
        let specs = spec.map { [$0] } ?? SubagentHookInstaller.available()
        guard !specs.isEmpty else {
            toasts.info("No agent to install into", detail: "Herd found no agent config on this machine")
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


/// Static bridge so the terminal surface can consult the slash menu without
/// knowing about Herd's stores.
@MainActor
enum HerdKeyHook {
    static weak var controller: SlashController?
    static weak var prompt: PromptEditor?

    static weak var store: SessionStore?

    static func handleKeyDown(_ event: NSEvent) -> Bool {
        // An image on the clipboard becomes a path, in any pane.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           prompt?.isActive != true,
           let store, PasteHandler.handleCommandV(store: store) {
            return true
        }
        // A dialog over the terminal owns the keyboard; Return and Esc reach
        // its buttons as key equivalents before this runs.
        if let request = ConfirmCenter.shared.request,
           request.window == nil || request.window === MainWindow.window { return true }
        // Input methods and dead keys compose text over several keystrokes;
        // raw key codes would break Japanese, Chinese, Korean and Option-accents.
        if isComposing(event) { return false }
        // Agent panes get the slash menu; shell prompts get Herd's own line.
        if controller?.handleKeyDown(event) == true { return true }
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

    static var isKey: Bool {
        guard let window else { return true }
        return NSApp.keyWindow == nil || NSApp.keyWindow === window
    }

    static func perform(_ action: () -> Void) {
        if isKey { action() }
    }
}

/// Herd menu checkbox for Secure Keyboard Entry, like Terminal's.
struct SecureKeyboardEntryToggle: View {
    @ObservedObject private var secure = SecureInput.shared

    var body: some View {
        Toggle("Secure Keyboard Entry", isOn: $secure.global)
    }
}
