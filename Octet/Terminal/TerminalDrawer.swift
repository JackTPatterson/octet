import Darwin
import SwiftUI

/// The shells under the terminal, after T3 Code's terminal drawer: ⌘J or the
/// panel's drawer button shows it. Each workspace gets its own terminals, in
/// its folder, in groups of one to four side by side or stacked
/// (`DrawerTerminalLayout`). Once started a shell lives on while hidden,
/// whether the drawer, its group or its workspace is out of sight, so a
/// server started in it keeps running and its output is still there.
struct TerminalDrawer: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @StateObject private var terminals = DrawerTerminals()

    private var currentWorkspace: String { SidebarTerminals.key(window.focusedWorkspace?.workspaceId) }

    /// The workspaces whose shells to keep: every one started, and the one
    /// in front if the drawer is showing it for the first time.
    private var workspacesShown: [String] {
        ui.terminalDrawerVisible && !terminals.started.contains(currentWorkspace)
            ? terminals.started + [currentWorkspace] : terminals.started
    }

    var body: some View {
        let current = terminals.layout(currentWorkspace)
        ZStack(alignment: .topTrailing) {
            Theme.terminalBackground
            HStack(spacing: 0) {
                // One stack for every shell, so the sidebar coming and going
                // never rebuilds (and so restarts) them.
                ZStack {
                    ForEach(workspacesShown, id: \.self) { key in
                        groups(of: key, inFront: ui.terminalDrawerVisible && key == currentWorkspace)
                    }
                }
                if current.showsSidebar {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    DrawerTerminalSidebar(terminals: terminals, workspace: currentWorkspace)
                }
            }
            if !current.showsSidebar {
                DrawerTerminalActions(terminals: terminals, workspace: currentWorkspace)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chrome))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    .padding(8)
            }
        }
        .onAppear {
            terminals.ui = ui
            #if DEBUG
            terminals.runDebugKeys(ui: ui) { currentWorkspace }
            #endif
        }
        .onChange(of: ui.terminalDrawerVisible, initial: true) { _, visible in
            if visible {
                terminals.start(currentWorkspace)
            } else if !terminals.started.isEmpty {
                // Keys belong to the main terminal again, not the one now hidden.
                OctetTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: currentWorkspace) { _, key in
            // Keys mustn't stay with the last workspace's shell, now hidden.
            if !terminals.started.isEmpty { OctetTerminalRuntime.focusTerminal() }
            if ui.terminalDrawerVisible { terminals.start(key) }
        }
        .onChange(of: store.snapshot.workspaces.map(\.workspaceId)) { _, ids in
            // A closed workspace's shells go with it. An empty list is a
            // reconnect in progress, not every workspace closing.
            guard !ids.isEmpty else { return }
            terminals.forget(workspacesNotIn: Set(ids))
        }
    }

    /// A workspace's groups, stacked; only the one in front shows. The rest
    /// stay laid out at full size so their shells keep their rows.
    @ViewBuilder
    private func groups(of key: String, inFront: Bool) -> some View {
        let layout = terminals.layout(key)
        ForEach(layout.groups) { group in
            let shown = inFront && group.id == layout.activeGroup?.id
            DrawerSplitLayout(axis: group.axis) {
                ForEach(group.terminals, id: \.self) { id in
                    DrawerTerminal(store: store, ui: ui, terminals: terminals, workspace: key, id: id,
                                   isPrimary: id == layout.primary,
                                   stripInset: layout.showsSidebar ? 0 : DrawerTerminalActions.floatingWidth)
                }
            }
            // Shows through the 1pt gaps between splits.
            .background(Theme.divider)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
        }
    }
}

/// A group's terminals in equal shares, 1pt apart. A Layout rather than an
/// HStack or VStack, because turning a group from side by side to stacked
/// must move its shells, not rebuild them.
private struct DrawerSplitLayout: Layout {
    var axis: DrawerTerminalLayout.Axis

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let horizontal = axis == .horizontal
        let share = ((horizontal ? bounds.width : bounds.height) - (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            let offset = (CGFloat(index) * (share + 1)).rounded()
            let end = index == subviews.count - 1
                ? (horizontal ? bounds.width : bounds.height) : (CGFloat(index) * (share + 1) + share).rounded()
            let size = horizontal ? CGSize(width: end - offset, height: bounds.height)
                : CGSize(width: bounds.width, height: end - offset)
            let origin = horizontal ? CGPoint(x: bounds.minX + offset, y: bounds.minY)
                : CGPoint(x: bounds.minX, y: bounds.minY + offset)
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

/// Split, split the other way, new and close: the floating strip while a
/// workspace has one terminal, the sidebar's top row once it has more. They
/// act on the terminal in front.
private struct DrawerTerminalActions: View {
    @ObservedObject var terminals: DrawerTerminals
    let workspace: String
    var compact = false

    /// The floating strip's width with its margin: four buttons, three
    /// dividers, its padding and the 8pt it sits in from the edge.
    static let floatingWidth: CGFloat = 4 * 24 + 3 * 5 + 4 + 16

    var body: some View {
        let layout = terminals.layout(workspace)
        let full = layout.canSplit ? "" : " (max \(DrawerTerminalLayout.maxPerGroup) per group)"
        HStack(spacing: 0) {
            // Left enabled while full and dimmed instead, so the tooltip still
            // says why; pressing it beeps.
            OctetIconButton(icon: "rectangle.split.2x1", help: "Split Terminal Horizontally (⌘D)" + full, compact: compact) {
                terminals.perform(.splitHorizontally, workspace: workspace)
            }
            .opacity(layout.canSplit ? 1 : 0.45)
            divider
            OctetIconButton(icon: "rectangle.split.1x2", help: "Split Terminal Vertically (⌘⇧D)" + full, compact: compact) {
                terminals.perform(.splitVertically, workspace: workspace)
            }
            .opacity(layout.canSplit ? 1 : 0.45)
            divider
            OctetIconButton(icon: "plus", help: "New Terminal (⌘N)", compact: compact) {
                terminals.perform(.newTerminal, workspace: workspace)
            }
            divider
            OctetIconButton(icon: "trash", help: "Close Terminal (⌘W)", compact: compact) {
                terminals.perform(.close, workspace: workspace)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: compact ? 12 : 14).padding(.horizontal, 2)
    }
}

/// Once a workspace has more than one terminal: the actions, then every
/// terminal by group, as in T3 Code. Clicking one brings its group up and
/// gives it the keys.
private struct DrawerTerminalSidebar: View {
    @ObservedObject var terminals: DrawerTerminals
    let workspace: String

    static let width: CGFloat = 144
    @Namespace private var selection

    var body: some View {
        let layout = terminals.layout(workspace)
        VStack(spacing: 0) {
            DrawerTerminalActions(terminals: terminals, workspace: workspace, compact: true)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(layout.groups) { group in
                        if layout.showsGroupHeaders {
                            DrawerGroupHeader(title: layout.groupLabel(of: group.id), count: group.terminals.count,
                                              active: group.id == layout.activeGroup?.id) {
                                if let first = group.terminals.first, group.id != layout.activeGroup?.id {
                                    terminals.select(first, workspace: workspace)
                                }
                            }
                        }
                        ForEach(group.terminals, id: \.self) { id in
                            DrawerTerminalRow(
                                label: layout.label(of: id, title: terminals.title(of: id, workspace: workspace)),
                                active: id == layout.active,
                                selection: selection,
                                onSelect: { terminals.select(id, workspace: workspace) },
                                onClose: { terminals.perform(.close, workspace: workspace, terminal: id) })
                            .padding(.leading, layout.showsGroupHeaders ? 8 : 0)
                        }
                    }
                }
                .padding(4)
                // The selection slides between rows, as tabs' do.
                .animation(MotionPreferences.shared.animation(.tabs, .smooth(duration: 0.2)), value: layout.active)
            }
        }
        .frame(width: Self.width)
        .background(Theme.chrome)
    }
}

/// A group's name and how many terminals it holds; filled while in front.
private struct DrawerGroupHeader: View {
    let title: String
    let count: Int
    let active: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(Theme.interfaceFont(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Text("\(count)").font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(active ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One terminal, in Octet's chip style: filled while in front, and its icon
/// turns into a close button under the pointer.
private struct DrawerTerminalRow: View {
    let label: String
    let active: Bool
    let selection: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                OctetIcon(hovered ? "xmark" : "terminal", size: 12)
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Terminal (⌘W)")
            .accessibilityLabel("Close \(label)")
            Text(label)
                .font(Theme.uiFont)
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            ZStack {
                if hovered && !active { RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.hover) }
                if active {
                    RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.cardSelected)
                        .matchedGeometryEffect(id: "selectedDrawerTerminal", in: selection)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One window's drawer terminals: every workspace's layout, which have
/// started, and the surfaces, so a row or a key can reach its shell.
/// Layouts are saved per workspace, so the splits come back on relaunch
/// (with fresh shells; the old ones end with the app).
@MainActor
final class DrawerTerminals: ObservableObject {
    @Published private(set) var layouts: [String: DrawerTerminalLayout]
    /// The workspaces whose shells are running, oldest first.
    @Published private(set) var started: [String] = []
    /// What each shell calls itself, by `key(_:_:)`.
    @Published private var titles: [String: String] = [:]
    /// Hidden when the last terminal closes.
    weak var ui: UIState?

    private struct WeakSurface {
        weak var view: TerminalEngine.SurfaceView?
        let workspace: String
        let id: Int
    }
    private var surfaces: [String: WeakSurface] = [:]
    nonisolated(unsafe) private var keyMonitor: Any?

    private static let defaultsKey = "octet.terminalDrawer.layouts"

    init() {
        layouts = Self.saved().filter { $0.value.isValid }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true ? nil : event }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private static func key(_ workspace: String, _ id: Int) -> String { "\(workspace)#\(id)" }

    func layout(_ workspace: String) -> DrawerTerminalLayout { layouts[workspace] ?? DrawerTerminalLayout() }

    func title(of id: Int, workspace: String) -> String? { titles[Self.key(workspace, id)] }

    func start(_ workspace: String) {
        guard !started.contains(workspace) else { return }
        started.append(workspace)
        // Restored splits each grab the keys as they attach; the one that
        // was in front should end up with them.
        if layout(workspace).terminals.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.focusActive(workspace) }
        }
    }

    /// Drops the shells and saved layouts of closed workspaces. The
    /// no-workspace drawer ("") is never closed.
    func forget(workspacesNotIn open: Set<String>) {
        started.removeAll { !$0.isEmpty && !open.contains($0) }
        for workspace in layouts.keys where !workspace.isEmpty && !open.contains(workspace) {
            layouts[workspace] = nil
            save(workspace)
        }
        titles = titles.filter { entry in
            let workspace = String(entry.key[..<(entry.key.lastIndex(of: "#") ?? entry.key.endIndex)])
            return workspace.isEmpty || open.contains(workspace)
        }
    }

    // MARK: - Surfaces

    func surfaceMade(_ view: TerminalEngine.SurfaceView, workspace: String, id: Int) {
        surfaces[Self.key(workspace, id)] = WeakSurface(view: view, workspace: workspace, id: id)
        view.onBecomeFirstResponder = { [weak self] in self?.update(workspace) { $0.focus(id) } }
        if layout(workspace).primary == id { SidebarTerminals.shared.register(workspace: workspace, view: view) }
    }

    func titleChanged(_ title: String, workspace: String, id: Int) {
        titles[Self.key(workspace, id)] = title
        if layout(workspace).primary == id { SidebarTerminals.shared.titleChanged(workspace: workspace, title) }
    }

    func exited(workspace: String, id: Int) {
        if layout(workspace).primary == id { SidebarTerminals.shared.exited(workspace: workspace) }
    }

    // MARK: - Actions

    /// The drawer's own Command keys, taken before the menus see them, but
    /// only while one of this drawer's shells is the first responder.
    /// Anything else, or the same keys anywhere else, goes on as usual.
    /// A local monitor rather than the surface's key-equivalent handling:
    /// for some keys (⌘N, ⌘W) the menus answer before the view is asked.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let command = DrawerTerminalCommand.matching(
            key: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command),
            shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control)),
            let responder = (event.window ?? NSApp.keyWindow)?.firstResponder as? TerminalEngine.SurfaceView,
            let entry = surfaces.values.first(where: { $0.view === responder })
        else { return false }
        perform(command, workspace: entry.workspace, terminal: entry.id)
        return true
    }

    /// Runs a command on `terminal`, or on the one in front. New shells take
    /// the keys themselves as they attach.
    func perform(_ command: DrawerTerminalCommand, workspace: String, terminal: Int? = nil) {
        if let terminal { update(workspace) { $0.focus(terminal) } }
        switch command {
        case .splitHorizontally, .splitVertically:
            var made: Int?
            update(workspace) { made = $0.split(command == .splitHorizontally ? .horizontal : .vertical) }
            if made == nil { NSSound.beep() }
        case .newTerminal:
            update(workspace) { $0.newGroup() }
        case .close:
            requestClose(terminal ?? layout(workspace).active, workspace: workspace)
        }
    }

    /// Brings a terminal's group up and gives it the keys.
    func select(_ id: Int, workspace: String) {
        update(workspace) { $0.focus(id) }
        focusActive(workspace)
    }

    /// Asks first when a program other than the shell is running in it,
    /// since closing stops it; an idle prompt just closes.
    private func requestClose(_ id: Int, workspace: String) {
        guard let view = surfaces[Self.key(workspace, id)]?.view, let running = Self.runningProgram(in: view) else {
            close(id, workspace: workspace)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \(layout(workspace).label(of: id, title: title(of: id, workspace: workspace)))?"
        alert.informativeText = "\(running) is still running in it. Closing the terminal stops it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close(id, workspace: workspace) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private func close(_ id: Int, workspace: String) {
        let primaryBefore = layout(workspace).primary
        var remaining = true
        update(workspace) { remaining = $0.close(id) }
        surfaces[Self.key(workspace, id)] = nil
        titles[Self.key(workspace, id)] = nil
        guard remaining else {
            // The last one: the drawer starts afresh next time it's shown.
            layouts[workspace] = nil
            save(workspace)
            started.removeAll { $0 == workspace }
            if let ui { MotionPreferences.shared.perform(.sidebar) { ui.terminalDrawerVisible = false } }
            OctetTerminalRuntime.focusTerminal()
            return
        }
        // Agents read the first terminal; when it closes, the next one is.
        let after = layout(workspace)
        if let primary = after.primary, primary != primaryBefore,
           let view = surfaces[Self.key(workspace, primary)]?.view {
            SidebarTerminals.shared.register(workspace: workspace, view: view)
            if let title = title(of: primary, workspace: workspace) {
                SidebarTerminals.shared.titleChanged(workspace: workspace, title)
            }
            if view.processExited { SidebarTerminals.shared.exited(workspace: workspace) }
        }
        focusActive(workspace)
    }

    /// Gives the keys to the terminal in front, once its group is showing.
    private func focusActive(_ workspace: String) {
        let id = layout(workspace).active
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.surfaces[Self.key(workspace, id)]?.view else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    /// The program in front in the shell, when it isn't the shell itself.
    private static func runningProgram(in view: TerminalEngine.SurfaceView) -> String? {
        guard !view.processExited, let pid = view.surfaceModel?.foregroundPID else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(Int32(pid), &name, UInt32(name.count)) > 0 else { return nil }
        let running = String(cString: name)
        return TerminalControl.isShell(running) ? nil : running
    }

    // MARK: - Saving

    private func update(_ workspace: String, _ change: (inout DrawerTerminalLayout) -> Void) {
        var layout = layout(workspace)
        change(&layout)
        guard layout != layouts[workspace] else { return }
        layouts[workspace] = layout
        save(workspace)
    }

    private static func saved() -> [String: DrawerTerminalLayout] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let all = try? JSONDecoder().decode([String: DrawerTerminalLayout].self, from: data) else { return [:] }
        return all
    }

    /// Writes one workspace's layout and leaves the rest as stored: every
    /// window has a drawer of its own, and must not undo another's.
    private func save(_ workspace: String) {
        var all = Self.saved()
        all[workspace] = layouts[workspace].flatMap { $0.isValid ? $0 : nil }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    #if DEBUG
    /// Verification hook: OCTET_DRAWER_KEYS="cmd+d cmd+shift+d cmd+n select:1 main cmd+d cmd+w" shows
    /// the drawer, then 15 seconds on (a fresh session takes a while to
    /// connect) posts each key as a real key event, through the local
    /// monitors and the menus, 1.5s apart.
    /// `select:N` clicks the Nth row, `main` gives the keys back to the main
    /// terminal. After each step `drawer.txt` in OCTET_SNAPSHOT_DIR says
    /// what the drawer holds and who has the keys.
    private static var debugKeysRan = false

    func runDebugKeys(ui: UIState, workspace: @escaping () -> String) {
        guard let keys = ProcessInfo.processInfo.environment["OCTET_DRAWER_KEYS"], !Self.debugKeysRan else { return }
        Self.debugKeysRan = true
        ui.terminalDrawerVisible = true
        let steps = keys.split(separator: " ").map(String.init)
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15 + Double(index) * 1.5) { [weak self] in
                self?.debugStep(step, workspace: workspace())
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.debugDump(after: step, workspace: workspace()) }
            }
        }
    }

    private func debugStep(_ step: String, workspace: String) {
        NSApp.activate(ignoringOtherApps: true)
        if step == "main" {
            // The main terminal straight, not via focusTerminal(), which may
            // hand the keys to the visual twin's composer instead.
            func mainSurface(in view: NSView) -> TerminalEngine.SurfaceView? {
                if let surface = view as? TerminalEngine.SurfaceView,
                   !surfaces.values.contains(where: { $0.view === surface }) { return surface }
                return view.subviews.lazy.compactMap(mainSurface).first
            }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let content = window.contentView, let surface = mainSurface(in: content) {
                window.makeFirstResponder(surface)
            }
            return
        }
        if step.hasPrefix("select:"), let n = Int(step.dropFirst(7)), n >= 1, n <= layout(workspace).terminals.count {
            select(layout(workspace).terminals[n - 1], workspace: workspace)
            return
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        var flags: NSEvent.ModifierFlags = []
        let parts = step.split(separator: "+")
        for part in parts.dropLast() {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let letter = String(parts.last ?? "")
        let codes: [String: UInt16] = ["d": 2, "n": 45, "w": 13, "t": 17]
        guard let code = codes[letter] else { return }
        let characters = flags.contains(.shift) ? letter.uppercased() : letter
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return }
        // Queued, not sent, so it passes the local monitors as a typed key does.
        NSApp.postEvent(event, atStart: false)
    }

    private func debugDump(after step: String, workspace: String) {
        guard let dir = ProcessInfo.processInfo.environment["OCTET_SNAPSHOT_DIR"] else { return }
        let layout = layout(workspace)
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        let responder = window?.firstResponder
        let holder = surfaces.first { $0.value.view === responder }?.key
            ?? (responder is TerminalEngine.SurfaceView ? "main terminal" : String(describing: responder.map { type(of: $0) }))
        // Every surface in the window, in view order, by drawer key or "main".
        func list(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            let own = (view as? TerminalEngine.SurfaceView).map { surface in
                [surfaces.first { $0.value.view === surface }?.key ?? "main"]
            } ?? []
            return own + view.subviews.flatMap(list)
        }
        var text = "after: \(step)\n"
        text += "drawerVisible=\(ui?.terminalDrawerVisible ?? false) workspace=\(workspace)\n"
        for group in layout.groups {
            text += "group \(group.id) \(group.axis.rawValue): \(group.terminals)\n"
        }
        text += "active=\(layout.active) primary=\(layout.primary.map(String.init) ?? "-") canSplit=\(layout.canSplit)\n"
        text += "sidebarRegistered=\(SidebarTerminals.shared.view(for: workspace).map { view in surfaces.first { $0.value.view === view }?.key ?? "another window's" } ?? "none")\n"
        text += "keys=\(holder)\nsurfaces=\(list(window?.contentView))\n"
        text += "windows=\(NSApp.windows.map { "\($0.title)|visible=\($0.isVisible)|\(list($0.contentView))" })\n\n"
        let path = dir + "/drawer.txt"
        let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (previous + text).write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif
}

/// Where the drawer sits: under the terminal, as tall as it's been dragged,
/// and folded to nothing while hidden. The shells stay laid out at full
/// height underneath, so hiding the drawer never squeezes them to no rows.
struct TerminalDrawerHost: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    /// The drawer's room under the terminal, changed without animation.
    @State private var room = false

    var body: some View {
        let height = clampedHeight
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            TerminalDrawer(store: store, ui: ui)
                .frame(height: height)
        }
        // Slides up into its room; the room itself changes at once, so the
        // terminal above resizes and reflows one time rather than on every
        // frame of an animated height.
        .offset(y: ui.terminalDrawerVisible ? 0 : height + 1)
        .frame(height: room ? height + 1 : 0, alignment: .top)
        .clipped()
        .onChange(of: ui.terminalDrawerVisible, initial: true) { _, visible in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { room = visible }
        }
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

/// One shell in the drawer, started in its workspace's folder and kept while
/// the workspace is open. Start Again starts a fresh one in whatever folder
/// is in front now. The workspace's first terminal also carries what agents
/// do with it: the command one suggested, and the note that they can read it.
private struct DrawerTerminal: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let terminals: DrawerTerminals
    /// The workspace this shell belongs to (`SidebarTerminals.key`).
    let workspace: String
    let id: Int
    /// The first terminal, the one `SidebarTerminals` lets agents reach.
    let isPrimary: Bool
    /// Room kept at the right of the bars above the shell for the floating
    /// strip, which would otherwise cover Run, Clear and Turn Off.
    var stripInset: CGFloat = 0
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
            if isPrimary, let suggestion = suggestions.pending[workspace] { suggestionStrip(suggestion.command) }
            if isPrimary, settings.values.agentsReadSidebarTerminal { readableNote }
            shell
        }
        .background(Theme.terminalBackground)
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
        .padding(.trailing, stripInset)
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
        .padding(.trailing, stripInset)
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
                onTitleChange: { terminals.titleChanged($0, workspace: workspace, id: id) },
                onExit: {
                    exited = true
                    terminals.exited(workspace: workspace, id: id)
                },
                onSurface: { terminals.surfaceMade($0, workspace: workspace, id: id) }
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

