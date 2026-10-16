import SwiftUI

/// The shell under the terminal, after T3 Code's terminal drawer: ⌘J or the
/// panel's drawer button shows it. One shell per workspace, in its folder;
/// once started it lives on while hidden, so a server started in it keeps
/// running and its output is still there when you come back.
struct TerminalDrawer: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    /// The workspaces whose shells are running, oldest first.
    @State private var startedTerminals: [String] = []

    private var currentTerminal: String { SidebarTerminals.key(window.focusedWorkspace?.workspaceId) }

    /// The shells to keep: every one started, and the one in front if the
    /// drawer is showing it for the first time.
    private var terminalsShown: [String] {
        ui.terminalDrawerVisible && !startedTerminals.contains(currentTerminal)
            ? startedTerminals + [currentTerminal] : startedTerminals
    }

    private func startTerminal(_ key: String) {
        if !startedTerminals.contains(key) { startedTerminals.append(key) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.terminalBackground
            ForEach(terminalsShown, id: \.self) { key in
                let shown = ui.terminalDrawerVisible && key == currentTerminal
                DrawerTerminal(store: store, ui: ui, workspace: key)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            toolbar
        }
        .onChange(of: ui.terminalDrawerVisible, initial: true) { _, visible in
            if visible {
                startTerminal(currentTerminal)
            } else if !startedTerminals.isEmpty {
                // Keys belong to the main terminal again, not the one now hidden.
                OctetTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: currentTerminal) { _, key in
            // Keys mustn't stay with the last workspace's shell, now hidden.
            if !startedTerminals.isEmpty { OctetTerminalRuntime.focusTerminal() }
            if ui.terminalDrawerVisible { startTerminal(key) }
        }
        .onChange(of: store.snapshot.workspaces.map(\.workspaceId)) { _, ids in
            // A closed workspace's shell goes with it. An empty list is a
            // reconnect in progress, not every workspace closing.
            guard !ids.isEmpty else { return }
            let open = Set(ids)
            startedTerminals.removeAll { !$0.isEmpty && !open.contains($0) }
        }
    }

    /// A small strip floating at the top right, as in T3 Code's drawer.
    private var toolbar: some View {
        HStack(spacing: 0) {
            OctetIconButton(icon: "xmark", help: OctetShortcut.terminalDrawer.help("Hide the terminal drawer")) {
                MotionPreferences.shared.perform(.sidebar) { ui.terminalDrawerVisible = false }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .padding(8)
    }
}

/// Where the drawer sits: under the terminal, as tall as it's been dragged,
/// and folded to nothing while hidden. The shells stay laid out at full
/// height underneath, so hiding the drawer never squeezes them to no rows.
struct TerminalDrawerHost: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState

    var body: some View {
        let height = clampedHeight
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            TerminalDrawer(store: store, ui: ui)
                .frame(height: height)
        }
        .frame(height: ui.terminalDrawerVisible ? height + 1 : 0, alignment: .top)
        .clipped()
        .overlay(alignment: .top) {
            if ui.terminalDrawerVisible { TerminalDrawerResizeHandle(ui: ui) }
        }
        .allowsHitTesting(ui.terminalDrawerVisible)
        .accessibilityHidden(!ui.terminalDrawerVisible)
    }

    private var clampedHeight: CGFloat {
        min(TerminalDrawerResizeHandle.maxHeight, max(UIState.terminalDrawerMinHeight, ui.terminalDrawerHeight))
    }
}

/// An invisible strip along the drawer's top edge: drag to resize,
/// double-click to go back to the default height.
private struct TerminalDrawerResizeHandle: View {
    @ObservedObject var ui: UIState
    @State private var startHeight: CGFloat?
    @State private var hovering = false

    /// Three quarters of the window, as in T3 Code.
    static var maxHeight: CGFloat {
        max(UIState.terminalDrawerMinHeight, (NSApp.keyWindow?.frame.height ?? 900) * 0.75)
    }

    var body: some View {
        Color.clear
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startHeight ?? ui.terminalDrawerHeight
                        startHeight = start
                        ui.terminalDrawerHeight = min(Self.maxHeight,
                            max(UIState.terminalDrawerMinHeight, (start - drag.translation.height).rounded()))
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .onTapGesture(count: 2) { ui.terminalDrawerHeight = UIState.terminalDrawerDefaultHeight }
            .help("Drag to resize the terminal drawer. Double-click to reset.")
            .accessibilityLabel("Terminal drawer height")
            .accessibilityValue("\(Int(ui.terminalDrawerHeight)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 16 : -16
                ui.terminalDrawerHeight = min(Self.maxHeight,
                    max(UIState.terminalDrawerMinHeight, ui.terminalDrawerHeight + delta))
            }
    }
}

/// A workspace's shell in the drawer, started in its folder the first time
/// the drawer is shown for it and kept while the workspace is open.
/// Start Again starts a fresh one in whatever folder is in front now.
private struct DrawerTerminal: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    /// The workspace this shell belongs to (`SidebarTerminals.key`).
    let workspace: String
    @StateObject private var anchor = TerminalAnchor()
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var suggestions = SidebarSuggestions.shared
    @State private var generation = 0
    @State private var exited = false

    private var folder: String {
        let inFront = window.focusedWorkspace?.workspaceId == workspace
        return (inFront ? window.focusedPaneId.flatMap { store.snapshot.workingDirectory(ofPane: $0) } : nil)
            ?? (workspace.isEmpty ? nil : store.snapshot.directory(ofWorkspace: workspace))
            ?? NSHomeDirectory()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let suggestion = suggestions.pending[workspace] { suggestionStrip(suggestion.command) }
            if settings.values.agentsReadSidebarTerminal { readableNote }
            shell
        }
    }

    /// The command an agent put at the prompt: read it, then Run or Clear.
    private func suggestionStrip(_ command: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.accent)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            OctetButton(title: "Run", kind: .primary, compact: true) {
                if let view = SidebarTerminals.shared.view(for: workspace) { SidebarTerminals.shared.run(in: view) }
                suggestions.dismiss(workspace: workspace)
            }
            OctetButton(title: "Clear", kind: .secondary, compact: true) {
                if let view = SidebarTerminals.shared.view(for: workspace) { SidebarTerminals.shared.clearLine(in: view) }
                suggestions.dismiss(workspace: workspace)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
        .help("An agent put this at the prompt. It hasn't run.")
    }

    /// Said over the terminal for as long as agents can read it.
    private var readableNote: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
            Text("Agents can read this terminal").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Button("Turn Off") { settings.values.agentsReadSidebarTerminal = false }
                .buttonStyle(.plain).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.card)
        .help("Read only. It's on in Settings › Terminal › Sidebar terminal.")
    }

    private var shell: some View {
        ZStack {
            OctetTerminalView(
                command: Self.shellCommand,
                environment: Self.environment,
                workingDirectory: folder,
                anchor: anchor,
                onTitleChange: { SidebarTerminals.shared.titleChanged(workspace: workspace, $0) },
                onExit: {
                    exited = true
                    SidebarTerminals.shared.exited(workspace: workspace)
                },
                onSurface: { SidebarTerminals.shared.register(workspace: workspace, view: $0) }
            )
            .id(generation)
            .background(Theme.terminalBackground)
            if exited {
                VStack(spacing: 8) {
                    Text("The shell exited").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                    OctetButton(title: "Start Again", kind: .secondary, compact: true) {
                        exited = false
                        generation += 1
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome))
            }
        }
    }

    /// The person's login shell.
    private static var shellCommand: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell) + " -l"
        }
        return (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") + " -l"
    }

    private static var environment: [String: String] {
        var env = TerminalEnvironment.colorCapability
        env["OCTET_SIDE_TERMINAL"] = "1"
        return env
    }
}

