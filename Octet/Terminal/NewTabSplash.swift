import AppKit
import SwiftUI

/// Which tab shows the new-tab splash right now, fed one grid reading at a
/// time by the terminal. The deciding is `NewTabFreshness`; this only
/// publishes the answer.
@MainActor
final class NewTabSplashModel: ObservableObject {
    @Published private(set) var tabId: String?
    private var freshness = NewTabFreshness()
    /// The last reading, kept to look at again once it can be believed.
    private var latest: (tab: String?, grid: TerminalGrid?, eligible: Bool, typing: Bool)?
    private var recheck: DispatchWorkItem?

    /// One reading of the grid for the tab in front. `eligible` is false
    /// while something else owns the terminal area (a conversation, a board,
    /// a split, a running program), which leaves the tab's state untouched.
    /// `typing` is Octet's own command line holding text: it keeps a command
    /// until Return, so the shell's cursor doesn't move while it's typed.
    func observe(tab: String?, grid: TerminalGrid?, eligible: Bool, typing: Bool) {
        latest = (tab, grid, eligible, typing)
        evaluate()
    }

    private func evaluate() {
        recheck?.cancel()
        recheck = nil
        guard let latest else { return }
        var shown: String?
        if latest.eligible, let tab = latest.tab, let grid = latest.grid {
            let now = Date()
            if freshness.observe(tab: tab, cursorRow: grid.cursorRow, cursorColumn: grid.cursorColumn,
                                 rowsInUse: grid.rowsInUse, at: now), !latest.typing {
                shown = tab
            }
            // The terminal only reports changes, so a grid that has stopped
            // changing would never be judged: look again once it counts.
            if let settles = freshness.settles(tab: tab, at: now) {
                recheck?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.evaluate() }
                recheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + settles.timeIntervalSince(now) + 0.02, execute: work)
            }
        }
        if shown != tabId { tabId = shown }
    }
}

/// What a new terminal tab offers before anything has run in it.
///
/// Drawn in the blank rows above a bottom-anchored prompt (or below a top one),
/// never over it, after T3 Code's empty states: a centred column with a short
/// heading, the agents as tiles, recent folders as rows in a card, and the
/// commands with the keys that run them, the way editors fill an empty pane
/// (VS Code and Zed list their commands so the keys get learned). Everything
/// here acts on this tab: an agent starts in its shell, a folder is `cd`'d
/// into, and the keys shown are the ones that already work from the terminal.
///
/// The keyboard reaches it too, without taking keys from the shell: ↓ at the
/// fresh prompt (which a shell has no use for) starts choosing, ↑/↓ and ←/→
/// move, Return runs the choice and Esc hands the keys back. ↑ before that is
/// still the shell's history.
struct NewTabSplash: View {
    struct Shortcut: Identifiable {
        let title: String
        var keys: String?
        var agent: String?
        let run: () -> Void
        var id: String { title }
    }

    /// The folder the tab's shell is in, left out of the recent folders.
    let currentDirectory: String?
    /// The window the splash is in; only its keys are read.
    var hostWindow: NSWindow?
    let runAgent: (DiscoveredAgent) -> Void
    let openFolder: (String) -> Void
    /// Types a command line at this tab's prompt without running it: an agent's installer.
    var runCommand: ((String) -> Void)?
    let shortcuts: [Shortcut]
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var folders: [RecentFolder] = RecentFolders.cached
    @StateObject private var keys = SplashKeys()
    /// How much ViewThatFits found room for: 2 everything, 1 without the
    /// folders, 0 the agents alone. The keyboard walks only what's shown.
    @State private var level = 2

    private var agents: [DiscoveredAgent] { discovery.agents.filter { $0.executablePath != nil } }
    private var availableShortcuts: [Shortcut] {
        let installed = Set(agents.map(\.id))
        return shortcuts.filter { $0.agent.map(installed.contains) ?? true }
    }

    private var recent: [RecentFolder] {
        Array(folders.filter { $0.path != currentDirectory }.prefix(4))
    }

    var body: some View {
        // Short windows drop the parts that matter least first: folders,
        // then the shortcuts, keeping the agents.
        ViewThatFits(in: .vertical) {
            content(level: 2)
            content(level: 1)
            content(level: 0)
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)
        .task {
            folders = await RecentFolders.refreshed()
            keys.items = items(level: level)
        }
        .onAppear {
            keys.items = items(level: level)
            keys.start(window: hostWindow)
        }
        .onDisappear { keys.stop() }
        .onChange(of: level) { _, value in keys.items = items(level: value) }
        .onChange(of: agents.map(\.id)) { _, _ in keys.items = items(level: level) }
    }

    /// Everything the keyboard can reach at this level, in reading order.
    private func items(level: Int) -> [SplashKeys.Item] {
        var list = agents.map { agent in SplashKeys.Item(id: "agent:" + agent.id) { runAgent(agent) } }
        if level >= 2 { list += recent.map { folder in SplashKeys.Item(id: "folder:" + folder.path) { openFolder(folder.path) } } }
        if level >= 1 { list += availableShortcuts.map { shortcut in SplashKeys.Item(id: "command:" + shortcut.id, run: shortcut.run) } }
        return list
    }

    private func content(level: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            heading
            if !agents.isEmpty {
                section("Start an agent") {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(max(agents.count, 1), 4))
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(agents) { agent in
                            AgentTile(agent: agent, selected: keys.selected == "agent:" + agent.id) { runAgent(agent) }
                        }
                    }
                }
            }
            // None found on this Mac yet: say how to get one, once the scan is in.
            if agents.isEmpty, discovery.scannedAt != nil {
                section("Install an agent") {
                    InstallAgentCard(scanning: discovery.scanning, run: runCommand) { discovery.scan() }
                }
            }
            if level >= 2, !recent.isEmpty {
                section("Recent folders") {
                    SplashCard {
                        ForEach(Array(recent.enumerated()), id: \.element.path) { index, folder in
                            if index > 0 { SplashCardDivider() }
                            FolderRow(folder: folder, selected: keys.selected == "folder:" + folder.path) {
                                openFolder(folder.path)
                            }
                        }
                    }
                }
            }
            if level >= 1, !availableShortcuts.isEmpty {
                section("Commands") {
                    VStack(spacing: 1) {
                        ForEach(availableShortcuts) { shortcut in
                            ShortcutRow(shortcut: shortcut, selected: keys.selected == "command:" + shortcut.id)
                        }
                    }
                }
            }
            keyHint
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if self.level != level { self.level = level } }
    }

    private var heading: some View {
        VStack(spacing: 4) {
            Text("New tab")
                .font(Theme.interfaceFont(17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Group {
                if let currentDirectory {
                    Text("Start something in ") + Text(abbreviateHome(currentDirectory)).font(Theme.Text.mono(12))
                } else {
                    Text("Start an agent, open a folder, or run a command.")
                }
            }
            .font(Theme.interfaceFont(12.5))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    /// How to reach it from the keyboard, quietly, under everything.
    private var keyHint: some View {
        HStack(spacing: 5) {
            if keys.selected == nil {
                Keycap(text: "↓")
                Text("to choose").foregroundStyle(Theme.textTertiary)
            } else {
                Keycap(text: "↑")
                Keycap(text: "↓")
                Text("to move").foregroundStyle(Theme.textTertiary)
                Keycap(text: "↩").padding(.leading, 6)
                Text("to run").foregroundStyle(Theme.textTertiary)
                Keycap(text: "esc").padding(.leading, 6)
                Text("for the shell").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(Theme.captionFont)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.selected == nil ? "Press down arrow to choose an item"
                            : "Up and down arrows to move, Return to run, Escape to go back to the shell")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 2)
            content()
        }
    }
}

/// The splash's keyboard: a local key monitor that only answers in its own
/// window while the terminal (not a text field) has the keys, and only once
/// ↓ has started a choice, so the shell keeps its history on ↑. The ↓ that
/// starts it is passed on to the shell as well.
@MainActor
final class SplashKeys: ObservableObject {
    struct Item {
        let id: String
        let run: () -> Void
    }

    @Published private(set) var selected: String?
    var items: [Item] = [] {
        didSet { if let selected, !items.contains(where: { $0.id == selected }) { self.selected = nil } }
    }
    private var monitor: Any?
    #if DEBUG
    /// Verification: keys pressed by OCTET_DEBUG_KEYS count in a window
    /// left in the background.
    private static let debugKeys = ProcessInfo.processInfo.environment["OCTET_DEBUG_KEYS"] != nil
    #else
    private static let debugKeys = false
    #endif

    func start(window: NSWindow?) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window, window.isKeyWindow || Self.debugKeys else { return event }
            return self.handle(event, in: window) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        selected = nil
    }

    /// True when the key was the splash's.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        // A field being edited (the palette, a rename) keeps its keys.
        if window.firstResponder is NSText { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, !items.isEmpty else {
            selected = nil
            return false
        }
        let index = selected.flatMap { id in items.firstIndex { $0.id == id } }
        switch event.keyCode {
        case 125, 124: // down, right
            guard let index else {
                // → at a fresh prompt is the shell's; ↓ starts choosing, and
                // still reaches the shell, so a binding on it keeps working.
                guard event.keyCode == 125 else { return false }
                selected = items.first?.id
                return false
            }
            selected = items[min(index + 1, items.count - 1)].id
            return true
        case 126, 123: // up, left
            guard let index else { return false }
            selected = items[max(index - 1, 0)].id
            return true
        case 36, 76: // return, enter
            guard let index else { return false }
            let item = items[index]
            selected = nil
            item.run()
            return true
        case 53: // escape
            guard index != nil else { return false }
            selected = nil
            return true
        default:
            // Typing hands the keys back to the shell.
            selected = nil
            return false
        }
    }
}

/// A rounded, bordered group of rows, as T3 Code's cards.
private struct SplashCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous)
        VStack(spacing: 0) { content() }
            .padding(3)
            .background(shape.fill(Theme.card.opacity(0.45)))
            .overlay(shape.strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, Theme.controlRadius)
            }
    }
}

/// What to do on a Mac with no coding agent yet: the installers for the
/// two Octet knows best, each typed into this tab on click (Return runs it),
/// and a scan to pick
/// up one installed some other way.
private struct InstallAgentCard: View {
    let scanning: Bool
    let run: ((String) -> Void)?
    let rescan: () -> Void

    private static let installers: [(agent: String, name: String, command: String)] = [
        ("claude", "Claude Code", "npm install -g @anthropic-ai/claude-code"),
        ("codex", "Codex", "npm install -g @openai/codex"),
    ]

    var body: some View {
        SplashCard {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("No coding agents found on this Mac. Install one and it shows up here, ready to start in any tab.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.installers, id: \.agent) { installer in
                    InstallerRow(agent: installer.agent, name: installer.name, command: installer.command, run: run)
                }
                HStack(spacing: Theme.Space.sm) {
                    Spacer()
                    if scanning { LoadingLine(width: 20) }
                    OctetButton(title: scanning ? "Looking…" : "Look Again", kind: .ghost, compact: true, action: rescan)
                        .disabled(scanning)
                }
            }
            .padding(Theme.Space.md)
        }
    }

    private struct InstallerRow: View {
        let agent: String
        let name: String
        let command: String
        let run: ((String) -> Void)?
        @State private var hovered = false

        var body: some View {
            Button {
                if let run { run(command) } else { copy() }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    if let brand = AgentBrand.forAgent(agent) { AgentLogo(brand: brand, size: 16) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Install \(name)").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                        Text(command).font(Theme.Text.mono(10.5)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: Theme.Space.md)
                }
                .padding(.horizontal, Theme.Space.sm)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(OctetPressStyle())
            .onHover { hovered = $0 }
            .contextMenu { Button("Copy Command", action: copy) }
            .help(run == nil ? "Copy \(command)" : "Type \(command) in this tab; press Return to run it")
            .accessibilityLabel("Install \(name)")
            .accessibilityHint(run == nil ? "Copies the install command" : "Types \(command) in this tab; press Return to run it")
        }

        private func copy() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            ToastCenter.shared.info("Copied the \(name) install command")
        }
    }
}

/// The hairline between a card's rows.
private struct SplashCardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10)
    }
}

/// An agent to start in this tab: its mark, its name and the command it
/// types.
private struct AgentTile: View {
    let agent: DiscoveredAgent
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius + 2, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                if let brand = AgentBrand.forAgent(agent.id) {
                    AgentLogo(brand: brand, size: 20)
                } else {
                    OctetIcon("terminal", size: 18).foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 1) {
                    Text(agent.displayName)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(agent.command)
                        .font(Theme.Text.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(shape.fill(selected ? Theme.cardSelected : hovered ? Theme.hover : Theme.card.opacity(0.45)))
            .overlay(shape.strokeBorder(selected ? Theme.textSecondary.opacity(0.55) : Theme.border.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, Theme.controlRadius)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("Run \(agent.onShellPath == true ? agent.command : agent.executablePath ?? agent.command) in this tab")
        .accessibilityLabel("Start \(agent.displayName) in this tab")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A recent folder: its icon, name and where it is, when it last changed,
/// and a `cd` into it on click.
private struct FolderRow: View {
    let folder: RecentFolder
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let path = folder.path
        Button(action: action) {
            HStack(spacing: 10) {
                OctetIcon("folder", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.card))
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(abbreviateHome((path as NSString).deletingLastPathComponent))
                        .font(Theme.Text.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selected {
                    Keycap(text: "↩")
                } else {
                    let age = WorkspaceActivity.ageLabel(since: folder.modified)
                    if !age.isEmpty {
                        Text(age == "now" ? "now" : "\(age) ago")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("cd \(abbreviateHome(path))")
        .accessibilityLabel("Change to \((path as NSString).lastPathComponent)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A command and the keys that run it, the way an editor's empty pane lists
/// them. The keys already work from the terminal; a click does the same.
private struct ShortcutRow: View {
    let shortcut: NewTabSplash.Shortcut
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: shortcut.run) {
            HStack(spacing: 8) {
                Text(shortcut.title)
                    .font(Theme.uiFont)
                    .foregroundStyle(hovered || selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                if let keys = shortcut.keys {
                    HStack(spacing: 3) {
                        ForEach(Array(Self.caps(keys).enumerated()), id: \.offset) { _, cap in Keycap(text: cap) }
                    }
                } else if selected {
                    Keycap(text: "↩")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(shortcut.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(shortcut.keys.map { "Keyboard shortcut \($0)" } ?? "")
    }

    /// "⇧⌘N" as a cap per key, the way T3 Code's kbd groups read.
    static func caps(_ keys: String) -> [String] {
        let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var caps: [String] = []
        var rest = ""
        for character in keys {
            if modifiers.contains(character), rest.isEmpty { caps.append(String(character)) } else { rest.append(character) }
        }
        if !rest.isEmpty { caps.append(rest) }
        return caps
    }
}

/// A recent project folder and when something in it last changed.
struct RecentFolder: Equatable {
    let path: String
    let modified: Date?
}

/// Recently touched project folders, as the palette lists them. Reading
/// them walks the project folders on disk, so it happens off the main thread
/// and the last answer is kept for the next splash.
enum RecentFolders {
    @MainActor static var cached: [RecentFolder] = []

    @MainActor private static var loadedAt = Date.distantPast
    /// A splash opens with every new tab, and the walk is only worth
    /// repeating once what it found could have changed.
    private static let freshFor: TimeInterval = 30

    /// The folders, read again only when the last reading is old.
    @MainActor
    static func refreshed() async -> [RecentFolder] {
        if Date().timeIntervalSince(loadedAt) < freshFor, !cached.isEmpty { return cached }
        return await load()
    }

    @MainActor
    static func load() async -> [RecentFolder] {
        let folders = await Task.detached(priority: .utility) {
            ProjectDirectories.listWithDates().map { RecentFolder(path: $0.path, modified: $0.modified == .distantPast ? nil : $0.modified) }
        }.value
        cached = folders
        loadedAt = Date()
        return folders
    }
}
