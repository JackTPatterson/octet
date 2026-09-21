import AppKit
import Foundation

/// Herd's own `/` menu for agent panes. Typing `/` on an empty prompt is
/// caught before it reaches the terminal, so the agent's in-terminal list
/// never renders; picking a command types it into the pane instead.
@MainActor
final class SlashController: ObservableObject {
    @Published private(set) var commands: [SlashCommand] = []
    /// Submenus the user has opened, e.g. `/model` then a model's efforts.
    @Published private(set) var path: [SlashCommand] = []
    /// A new query re-ranks the list, so the highlight goes back to the best match.
    @Published var query = "" { didSet { if query != oldValue { selection = 0 } } }
    @Published var selection = 0
    /// The pane the menu is typing into; nil when closed.
    @Published private(set) var paneId: String?
    @Published private(set) var agentName = ""
    private var agentKind = ""

    private unowned let store: SessionStore
    /// Characters typed into each pane since its prompt was last submitted,
    /// so `/` only opens the menu at the start of an empty prompt.
    private var typed: [String: String] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    var isOpen: Bool { paneId != nil }

    /// The level being shown: a submenu's children, or the root list.
    var level: [SlashCommand] {
        path.last?.children ?? commands
    }

    var matches: [SlashCommand] {
        SlashCommands.matching(query, in: level)
    }

    var selectedHasChildren: Bool {
        matches.indices.contains(selection) && matches[selection].hasChildren
    }

    /// What Return will do to the highlighted command.
    var selectedRuns: Bool {
        guard matches.indices.contains(selection) else { return false }
        let command = matches[selection]
        return !command.hasChildren && command.argumentHint.isEmpty && SettingsStore.shared.values.slashRunsCommands
    }

    /// Opens the highlighted command's submenu, if it has one.
    func openSelected() {
        guard matches.indices.contains(selection) else { return }
        descend(matches[selection])
    }

    /// `/model gpt-6-astra` while two submenus deep.
    var breadcrumb: String {
        path.last?.insertion ?? "/"
    }

    // MARK: - Key interception

    /// Called before the terminal sees a key. Returns true when Herd took it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard SettingsStore.shared.values.slashMenu, !isOpen else { return false }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        guard let pane = focusedAgentPane() else {
            typed.removeAll()
            return false
        }

        switch characters {
        case "\r", "\n", "\u{3}", "\u{1B}":
            typed[pane.paneId] = ""
            return false
        case "\u{7F}", "\u{8}":
            if var buffer = typed[pane.paneId], !buffer.isEmpty {
                buffer.removeLast()
                typed[pane.paneId] = buffer
            }
            return false
        case "/":
            guard (typed[pane.paneId] ?? "").isEmpty else { break }
            open(paneId: pane.paneId, agent: pane.agent)
            return true
        default:
            break
        }
        if characters.count == 1, characters.first.map({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " }) == true {
            typed[pane.paneId, default: ""] += characters
        }
        return false
    }

    /// The focused pane, when an agent is running in it.
    private func focusedAgentPane() -> (paneId: String, agent: String?)? {
        let snapshot = store.snapshot
        let agents = snapshot.agents
        guard let agent = agents.first(where: { $0.paneId == snapshot.focusedPaneId })
            ?? agents.first(where: { $0.tabId == (store.displayedFocusedTabId ?? snapshot.focusedTabId) })
        else { return nil }
        return (agent.paneId, agent.agent)
    }

    // MARK: - Menu

    func open(paneId: String, agent: String?) {
        let snapshot = store.snapshot
        let cwd = snapshot.panes.first { $0.paneId == paneId }?.cwd
        agentName = AgentBrand.forAgent(agent)?.displayName ?? "the agent"
        agentKind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        query = ""
        selection = 0
        path = []
        commands = SlashCommands.all(agent: agent, cwd: cwd, context: contexts[agentKind] ?? SlashContext())
        self.paneId = paneId
        // The arguments (servers, models, agents) are read from disk, so the
        // list fills in a moment later if it has gone stale.
        reloadContext(agent: agent, cwd: cwd)
    }

    func close() {
        paneId = nil
        query = ""
        path = []
        commands = []
    }

    /// Opens a command's submenu.
    func descend(_ command: SlashCommand) {
        guard command.hasChildren else { return }
        path.append(command)
        query = ""
        selection = 0
    }

    /// Leaves the current submenu; at the root this cancels the menu.
    func ascend() {
        guard !path.isEmpty else {
            cancel()
            return
        }
        path.removeLast()
        query = ""
        selection = 0
    }

    func moveSelection(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Runs the highlighted command in the pane — the menu replaces the
    /// prompt for these, so nothing is left to press Return on. `insert`
    /// types it instead, for when arguments still have to be written. A
    /// command with arguments opens its submenu first.
    func choose(_ command: SlashCommand? = nil, insert: Bool = false) {
        guard let paneId else { return }
        let picked = command ?? (matches.indices.contains(selection) ? matches[selection] : nil)
        guard let picked else {
            cancel()
            return
        }
        if picked.hasChildren {
            descend(picked)
            return
        }
        // A command still expecting free text is typed, never run blind.
        let typeOnly = insert || !SettingsStore.shared.values.slashRunsCommands || !picked.argumentHint.isEmpty
        send(text: picked.insertion + (typeOnly ? " " : ""), to: paneId, submit: !typeOnly)
        close()
    }

    /// Backspace on an empty query: leaves the submenu, or at the root
    /// deletes the `/` itself by closing without typing anything.
    func backspaceOnEmpty() {
        guard path.isEmpty else { return ascend() }
        close()
        HerdTerminalRuntime.focusTerminal()
    }

    /// Escape: closes the menu and passes on what was typed, so nothing the
    /// user wrote is swallowed.
    func cancel() {
        guard let paneId else { return }
        let literal = (path.last.map { $0.insertion + " " } ?? "/") + query
        close()
        send(text: literal, to: paneId, submit: false)
    }

    // MARK: - Argument context

    /// Cached per agent, so the menu always opens with its arguments ready.
    private var contexts: [String: SlashContext] = [:]
    private var contextLoadedAt: [String: Date] = [:]
    private static let contextLifetime: TimeInterval = 120

    /// Reads every installed agent's config in the background at launch, so
    /// the first `/` already knows their servers, models and prompts.
    func warmContexts() {
        for host in AgentHosts.installed() {
            reloadContext(agent: host.id, cwd: nil, force: true)
        }
    }

    /// Reads each agent's own config (MCP servers, models, agents, styles)
    /// off the main thread, plus what Herd itself knows: recent project
    /// folders and the sessions it can resume.
    func reloadContext(agent: String?, cwd: String?, force: Bool = false) {
        let kind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        if !force, let loadedAt = contextLoadedAt[kind], Date().timeIntervalSince(loadedAt) < Self.contextLifetime {
            return
        }
        contextLoadedAt[kind] = Date()
        let directories = Array(store.groups.map(\.id).prefix(12))
        let sessions = recentSessions()
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded = SlashContext.load(agent: agent, cwd: cwd)
            loaded.directories = directories
            loaded.sessions = sessions
            DispatchQueue.main.async { [weak self] in
                guard let self, loaded != self.contexts[kind] else { return }
                self.contexts[kind] = loaded
                guard self.isOpen, self.agentKind == kind else { return }
                let keep = self.path.map(\.insertion)
                self.commands = SlashCommands.all(agent: agent, cwd: cwd, context: loaded)
                // Follow the open submenu into the rebuilt tree.
                var rebuilt: [SlashCommand] = []
                var level = self.commands
                for insertion in keep {
                    guard let match = level.first(where: { $0.insertion == insertion }) else { break }
                    rebuilt.append(match)
                    level = match.children
                }
                self.path = rebuilt
            }
        }
    }

    private func recentSessions() -> [(id: String, label: String)] {
        store.recovery.resumableSessions().prefix(10).map { record in
            (record.sessionId ?? "", record.tabLabel.isEmpty ? record.workspaceLabel : record.tabLabel)
        }
        .filter { !$0.0.isEmpty }
    }

    private func send(text: String, to paneId: String, submit: Bool) {
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                submit
                    ? try client.call("agent.prompt", ["target": paneId, "text": text])
                    : try client.call("pane.send_text", ["pane_id": paneId, "text": text])
            }
            DispatchQueue.main.async {
                if case .failure(let error) = outcome {
                    ToastCenter.shared.fail(nil, "Couldn't run that command", detail: String(describing: error))
                }
                HerdTerminalRuntime.focusTerminal()
            }
        }
    }

    /// Focus moved elsewhere: the pane's prompt state is unknown again.
    func resetTyping() {
        typed.removeAll()
    }
}
