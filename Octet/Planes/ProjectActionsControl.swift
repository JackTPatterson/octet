import SwiftUI

/// The panel strip's project actions, after T3 Code's: a play button that
/// runs the project's first action, and a chevron for the rest, for adding
/// one and for changing them. A project with none is offered what its
/// package.json, Makefile or Cargo.toml already say.
struct ProjectActionsControl: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var ui: UIState
    let directory: String?
    @ObservedObject private var store = ProjectActionsStore.shared
    @State private var draft: ProjectActionDraft?
    @State private var showingJobs = false

    private var root: String? { directory.map(ProjectActionsStore.root(of:)) }
    private var checkout: String? {
        guard let directory else { return nil }
        return WorktreeSetup.linkedWorktree(containing: directory,
            exists: { FileManager.default.fileExists(atPath: $0) },
            read: { try? String(contentsOfFile: $0, encoding: .utf8) })?.checkout ?? root
    }
    private var actions: [ProjectAction] { root.map { store.actions(for: $0, checkout: checkout) } ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            OctetIconButton(icon: "calendar", help: "Scheduled project jobs") { showingJobs = true }
            WorkspaceIssueControl(directory: directory)
            WorkspaceSetupControl(directory: directory, store: window.store)
            OctetIconButton(icon: "play",
                            help: actions.first.map { "Run \($0.name)" } ?? "Project actions") {
                if let root { store.refreshConfiguration(root: root, checkout: checkout) }
                if let root, store.configurationErrors[checkout ?? root] != nil { presentMenu() }
                else if let first = actions.first { run(first) } else { presentMenu() }
            }
            OctetIconButton(icon: "chevron.down", help: "Project actions", compact: true) { presentMenu() }
        }
        .disabled(directory == nil)
        .onChange(of: directory, initial: true) { _, value in
            if let root { store.refreshConfiguration(root: root, checkout: checkout) }
        }
        .sheet(isPresented: $showingJobs) { if let root { ProjectJobsView(root: root) } }
        .sheet(item: $draft) { draft in
            if let root {
                ProjectActionSheet(draft: draft, root: root) { self.draft = nil }
            }
        }
    }

    private func presentMenu() {
        guard let root else { return }
        store.refreshConfiguration(root: root, checkout: checkout)
        if let error = store.configurationErrors[checkout ?? root] {
            ConfirmCenter.shared.show(title: "Project configuration error", detail: error)
            return
        }
        var items: [OctetMenuItem] = actions.map { action in
            .action(action.name, icon: action.icon, help: action.command) { run(action) }
        }
        if actions.isEmpty {
            let suggested = ProjectActionSuggestions.suggestions(in: root)
            if !suggested.isEmpty {
                items.append(.header("Found in this project"))
                items += suggested.map { suggestion in
                    .action(suggestion.name, icon: suggestion.icon, help: suggestion.command) {
                        run(ProjectActionsStore.shared.save(suggestion, root: root, isNew: true))
                    }
                }
            }
        }
        items.append(.divider)
        items.append(.action("Add Action…", icon: "plus") { draft = ProjectActionDraft(action: nil) })
        items.append(.submenu("Edit Action", icon: "pencil", actions.map { action in
            .action(action.name, icon: action.icon) { draft = ProjectActionDraft(action: action) }
        }))
        OctetContextMenu.present(items)
    }

    private func run(_ action: ProjectAction) {
        guard let directory else { return }
        ProjectActionRunner.run(action, in: directory,
                                workspace: SidebarTerminals.key(window.focusedWorkspace?.workspaceId), ui: ui)
    }
}

/// Runs an action at the prompt of the terminal drawer's first shell.
@MainActor
enum ProjectActionRunner {
    /// Shows the drawer, waits for its shell to exist, then types the command
    /// in `directory` and presses Return. A shell busy with something else
    /// is left alone.
    static func run(_ action: ProjectAction, in directory: String, workspace: String, ui: UIState, attempt: Int = 0) {
        if !ui.terminalDrawerVisible { ui.terminalDrawerVisible = true }
        guard let view = SidebarTerminals.shared.view(for: workspace) else {
            // The drawer starts its shell as it appears.
            guard attempt < 30 else {
                ToastCenter.shared.info("Couldn't reach the terminal", detail: "Open the terminal drawer, then try again.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                run(action, in: directory, workspace: workspace, ui: ui, attempt: attempt + 1)
            }
            return
        }
        do {
            try SidebarTerminals.shared.stage(line(for: action, in: directory), in: view)
            SidebarTerminals.shared.run(in: view)
        } catch {
            ToastCenter.shared.info("The terminal is busy", detail: "Stop what's running in it, then run \(action.name) again.")
        }
    }

    /// The command as typed: in the folder, whatever the shell was left in.
    static func line(for action: ProjectAction, in directory: String) -> String {
        "cd \(quoted(directory)) && \(action.command)"
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// An action being added (none yet) or changed.
struct ProjectActionDraft: Identifiable {
    let id = UUID()
    let action: ProjectAction?
}

/// The editor for one action: name, command and mark, with Delete for one
/// that exists.
struct ProjectActionSheet: View {
    let draft: ProjectActionDraft
    let root: String
    let close: () -> Void
    @State private var name: String
    @State private var command: String
    @State private var icon: String

    init(draft: ProjectActionDraft, root: String, close: @escaping () -> Void) {
        self.draft = draft
        self.root = root
        self.close = close
        _name = State(initialValue: draft.action?.name ?? "")
        _command = State(initialValue: draft.action?.command ?? "")
        _icon = State(initialValue: draft.action?.icon ?? ProjectActionIcon.play.rawValue)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.action == nil ? "Add action" : "Edit action")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Runs in this project's terminal drawer, from the folder in front.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                field("Name") { OctetTextField(placeholder: "Test", text: $name) }
                field("Command") { OctetTextField(placeholder: "npm run test", text: $command) }
                field("Icon") {
                    OctetSelect(selection: $icon,
                                options: ProjectActionIcon.allCases.map { ($0.rawValue, $0.title) }, width: 160)
                        .accessibilityLabel("Icon")
                }
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                if let action = draft.action, ProjectActionsStore.shared.actions[root]?.contains(where: { $0.id == action.id }) == true {
                    OctetButton(title: "Remove local action", kind: .destructive, compact: true) {
                        ProjectActionsStore.shared.delete(action.id, root: root)
                        close()
                    }
                }
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, compact: true, action: close).keyboardShortcut(.cancelAction)
                OctetButton(title: "Save", kind: .primary, compact: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 420)
        .background(Theme.chrome)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func save() {
        let action = ProjectAction(id: draft.action?.id ?? "", name: name.trimmingCharacters(in: .whitespaces),
                                   command: command.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon)
        ProjectActionsStore.shared.save(action, root: root, isNew: draft.action == nil)
        close()
    }
}
