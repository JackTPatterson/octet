import SwiftUI

@main
struct HerdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: HerdrStore
    @StateObject private var ui = UIState()
    @StateObject private var marketplace: MarketplaceStore
    @StateObject private var slash: SlashController
    @StateObject private var prompt: PromptEditor
    private let session: HerdrSession?

    init() {
        let session = HerdrSession.make()
        let settings = SettingsStore.shared
        settings.herdrConfigPath = session?.configPath
        settings.writeHerdrConfig()
        self.session = session
        // Launched from inside an agent's shell, Herd would hand that agent's
        // session markers to every pane it opens.
        AgentEnvironment.clearInheritedMarkers()
        let socketPath = session?.socketPath ?? HerdrClient.socketPath(session: HerdrSession.name)
        let store = HerdrStore(client: HerdrClient(socketPath: socketPath))
        _store = StateObject(wrappedValue: store)
        _marketplace = StateObject(wrappedValue: MarketplaceStore(herdr: store))
        let slash = SlashController(store: store)
        _slash = StateObject(wrappedValue: slash)
        HerdKeyHook.controller = slash
        let prompt = PromptEditor(store: store)
        _prompt = StateObject(wrappedValue: prompt)
        HerdKeyHook.prompt = prompt
        HerdKeyHook.store = store
        settings.reloadHerdr = { [weak store] in store?.reloadHerdrConfig(quiet: true) }
        HerdTerminalRuntime.configure(overrides: settings.values.ghosttyConfig + "\n" + Theme.herdShortcutUnbinds)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, ui: ui, session: session, slash: slash, prompt: prompt)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    store.start()
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
        Window("Agents", id: "agents") {
            AgentBoardView(store: store) { agent in
                store.focus(AgentEvent(id: agent.paneId, kind: .finished, agent: agent.agent,
                                       paneId: agent.paneId, tabId: agent.tabId,
                                       workspaceId: agent.workspaceId, label: "", workedFor: nil, at: Date()))
            }
        }
        .defaultSize(width: 620, height: 460)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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

struct HerdCommands: Commands {
    let store: HerdrStore
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Workspace") { store.newWorkspace() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Folder as Workspace…") { PaletteCatalog.openFolder(store: store) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Close Tab") { store.closeFocusedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            Button("Marketplace…") { MarketplaceWindow.open() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Agents…") { AgentBoardWindow.open() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(store.twin.isVisible ? "Show Terminal" : "Visual Twin") { store.twin.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Install Subagent Tabs Hook") { SubagentHookMenu.install() }
            Button("Remove Subagent Tabs Hook") { SubagentHookMenu.uninstall() }
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette") { ui.paletteVisible.toggle() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Command Palette ") { ui.paletteVisible.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { ui.sidebarVisible.toggle() }
                .keyboardShortcut("b", modifiers: .command)
        }
        CommandMenu("Pane") {
            Button("Split Right") { store.splitPane(.right) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { store.splitPane(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Toggle Zoom") { store.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Close Pane") { store.closeFocusedPane() }
            Divider()
            Button("Focus Left") { store.focusPane(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Right") { store.focusPane(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Up") { store.focusPane(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Down") { store.focusPane(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        CommandMenu("Navigate") {
            Button("Next Tab") { store.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Next Workspace") { store.selectAdjacentWorkspace(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Previous Workspace") { store.selectAdjacentWorkspace(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}

/// Menu actions for the subagent tabs hook, for any agent that has one.
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
/// Opens the agents board, the same way the Marketplace window opens.
@MainActor
enum AgentBoardWindow {
    static let id = "agents"
    static var opener: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

@MainActor
enum MarketplaceWindow {
    static let id = "marketplace"
    static var opener: (() -> Void)?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}


/// Static bridge so the Ghostty surface can consult the slash menu without
/// knowing about Herd's stores.
@MainActor
enum HerdKeyHook {
    static weak var controller: SlashController?
    static weak var prompt: PromptEditor?

    static weak var store: HerdrStore?

    static func handleKeyDown(_ event: NSEvent) -> Bool {
        // An image on the clipboard becomes a path, in any pane.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           prompt?.isActive != true,
           let store, PasteHandler.handleCommandV(store: store) {
            return true
        }
        // Agent panes get the slash menu; shell prompts get Herd's own line.
        if controller?.handleKeyDown(event) == true { return true }
        return prompt?.handleKeyDown(event) ?? false
    }
}
