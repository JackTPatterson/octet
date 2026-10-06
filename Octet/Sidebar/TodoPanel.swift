import SwiftUI

/// The plan of the agent in front, whichever agent it is: a conversation in
/// Octet, or the agents running in the tab's terminal panes. Each agent keeps
/// its list its own way (Claude Code's task files, Codex's plan, OpenCode's
/// database, a TodoWrite call); `AgentTodos` reads them into one shape.
@MainActor
final class TodoModel: ObservableObject {
    struct Section: Identifiable, Equatable {
        let id: String
        /// The agent's id, for its logo and name.
        let agent: String?
        let title: String
        let todos: [AgentTodo]
    }

    @Published private(set) var sections: [Section] = []
    /// The project's own list, from `TODO.md` at its root.
    @Published private(set) var project: ProjectTodoList?
    /// The root of the project in front, where `TODO.md` is or would go.
    @Published private(set) var projectRoot: String?
    /// The file last read, so it's parsed again only when it changes.
    private var projectRead: (path: String, modified: Date)?
    private weak var window: WindowContext?
    private var timer: Timer?
    private var loading = false
    /// A Codex rollout is re-read only when it has changed.
    private var rollouts: [String: (modified: Date, plan: [AgentTodo]?)] = [:]
    static let interval: TimeInterval = 2.5

    /// All steps across the sections, for the tab bar's count.
    var todos: [AgentTodo] { sections.flatMap(\.todos) }

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Where each list comes from, for what's in front now.
    private enum Source {
        case conversation(AgentSession)
        case claudeTasks(sessionId: String)
        case codexRollout(sessionId: String)
        case openCode(sessionId: String)
    }

    func refresh() {
        guard let window, !loading else { return }
        let store = window.store
        var sources: [(id: String, agent: String?, title: String, source: Source)] = []
        if let session = AgentCenter.shared.active(in: window.focusedWorkspace?.workspaceId) {
            sources.append(("conversation:\(session.id)", session.engine.agent, session.title, .conversation(session)))
        } else if let tabId = window.displayedFocusedTabId {
            for agent in store.snapshot.agents where agent.tabId == tabId {
                let brand = AgentBrand.forAgent(agent.agent)
                guard let brandId = brand?.id,
                      let sessionId = agent.sessionReference ?? agent.terminalId.flatMap({ store.recovery.sessionId(forTerminal: $0) })
                else { continue }
                let title = brand?.displayName ?? brandId
                switch brandId {
                case "claude": sources.append(("pane:\(agent.paneId)", brandId, title, .claudeTasks(sessionId: sessionId)))
                case "codex": sources.append(("pane:\(agent.paneId)", brandId, title, .codexRollout(sessionId: sessionId)))
                case "opencode": sources.append(("pane:\(agent.paneId)", brandId, title, .openCode(sessionId: sessionId)))
                default: continue
                }
            }
        }
        refreshProject(window)
        // A conversation's own list is already in memory; files are read off
        // the main thread.
        var ready: [String: [AgentTodo]] = [:]
        var claudeFiles: [String: String] = [:]
        for entry in sources {
            if case .conversation(let session) = entry.source {
                if session.engine == .claude {
                    claudeFiles[entry.id] = session.conversation.sessionId ?? session.sessionId
                }
                ready[entry.id] = session.conversation.plan ?? AgentTodos.latest(in: session.conversation.items)
            }
        }
        loading = true
        let rollouts = self.rollouts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found = ready
            var seenRollouts: [String: (modified: Date, plan: [AgentTodo]?)] = [:]
            for entry in sources {
                switch entry.source {
                case .conversation:
                    // Claude Code keeps its tasks in files whichever way it runs.
                    if let id = claudeFiles[entry.id],
                       let tasks = AgentTodos.claudeTasks(in: AgentTodos.claudeTasksDirectory(sessionId: id)) {
                        found[entry.id] = tasks
                    }
                case .claudeTasks(let sessionId):
                    found[entry.id] = AgentTodos.claudeTasks(in: AgentTodos.claudeTasksDirectory(sessionId: sessionId))
                case .codexRollout(let sessionId):
                    guard let path = AgentSessionFiles.codexPath(forSession: sessionId) else { continue }
                    let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    if let cached = rollouts[path], cached.modified == modified {
                        seenRollouts[path] = cached
                        found[entry.id] = cached.plan
                    } else {
                        let plan = AgentTodos.codexPlan(inRollout: path)
                        seenRollouts[path] = (modified, plan)
                        found[entry.id] = plan
                    }
                case .openCode(let sessionId):
                    found[entry.id] = AgentTodos.openCodeTodos(sessionId: sessionId)
                }
            }
            let sections = sources.compactMap { entry -> Section? in
                guard let todos = found[entry.id], !todos.isEmpty else { return nil }
                return Section(id: entry.id, agent: entry.agent, title: entry.title, todos: todos)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.rollouts = seenRollouts
                if sections != self.sections { self.sections = sections }
            }
        }
    }
}

// MARK: - The project's TODO.md

extension TodoModel {
    /// Re-reads the project's `TODO.md` when the project in front or the
    /// file has changed.
    fileprivate func refreshProject(_ window: WindowContext) {
        let directory = window.focusedWorkspace.flatMap { window.store.snapshot.directory(ofWorkspace: $0.workspaceId) }
        let root = directory.map { GitBranch.location(for: $0)?.root ?? $0 }
        if root != projectRoot {
            projectRoot = root
            project = nil
            projectRead = nil
        }
        guard let root else { return }
        let last = projectRead
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = ProjectTodos.path(inRoot: root)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            if let last, last.path == path, last.modified == modified { return }
            let list = modified == nil ? nil
                : (try? String(contentsOfFile: path, encoding: .utf8)).map { ProjectTodos.parse($0, path: path) }
            DispatchQueue.main.async {
                guard let self, self.projectRoot == root else { return }
                self.projectRead = modified.map { (path: path, modified: $0) }
                if list != self.project { self.project = list }
            }
        }
    }

    /// Marks an item, checking first that its line still holds it: the file
    /// may have changed since it was read.
    func set(_ item: ProjectTodoList.Item, to status: AgentTodo.Status) {
        guard let path = project?.path else { return }
        edit(path) { contents in
            let current = ProjectTodos.parse(contents, path: path).items.first { $0.line == item.line }
            guard current?.text == item.text else { return nil }
            return ProjectTodos.setting(status, line: item.line, in: contents)
        }
    }

    /// Adds an open item, making `TODO.md` if the project has none.
    func add(_ text: String) {
        guard let root = projectRoot else { return }
        let path = project?.path ?? ProjectTodos.path(inRoot: root)
        edit(path) { ProjectTodos.adding(text, to: $0) }
    }

    /// The agent in this window's tab that an item can be handed to.
    var agentInFront: EngineAgent? {
        guard let window, AgentCenter.shared.active(in: window.focusedWorkspace?.workspaceId) == nil,
              let tabId = window.displayedFocusedTabId else { return nil }
        return window.store.snapshot.agents.first { $0.tabId == tabId && $0.agent != nil && !$0.isSubagentViewer }
    }

    /// Sends the item to the agent in front as a prompt, asking it to tick
    /// the item off when done, and marks it under way.
    func handToAgent(_ item: ProjectTodoList.Item) {
        guard let window, let agent = agentInFront, let path = project?.path else { return }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        let fileName = (path as NSString).lastPathComponent
        window.store.broadcast(ProjectTodos.prompt(for: item, fileName: fileName),
                               to: [Broadcast.Target(paneId: agent.paneId, name: name, isAgent: true)])
        if item.status == .pending { set(item, to: .inProgress) }
    }

    /// Reads, changes and writes the file off the main thread, then reads it
    /// back so the panel shows the result straight away.
    private func edit(_ path: String, _ change: @escaping (String) -> String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            var failure: String?
            if let changed = change(contents) {
                if changed != contents {
                    do { try changed.write(toFile: path, atomically: true, encoding: .utf8) } catch {
                        failure = error.localizedDescription
                    }
                }
            } else {
                failure = "The item moved in the file. Try again."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    ToastCenter.shared.fail(nil, "Couldn't update \((path as NSString).lastPathComponent)", detail: failure)
                }
                self.projectRead = nil
                if let window = self.window { self.refreshProject(window) }
            }
        }
    }
}

/// The todo panel: each agent's plan, with where it's got to.
struct TodoPanel: View {
    @ObservedObject var model: TodoModel
    @ObservedObject var ui: UIState
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        let todos = model.todos
        let projectOpen = model.project?.open.count ?? 0
        SidePanelSectionView(.todos,
                             count: todos.isEmpty ? projectOpen : nil,
                             label: todos.isEmpty ? nil : "\(todos.completedCount)/\(todos.count)",
                             labelColor: !todos.isEmpty && todos.completedCount == todos.count ? Color(hex: AgentStateColor.done) : nil) {
            if model.sections.isEmpty && model.projectRoot == nil {
                empty
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.sections) { section in
                        TodoSectionView(section: section, showsTitle: model.sections.count > 1)
                    }
                    if let root = model.projectRoot {
                        if !model.sections.isEmpty { Rectangle().fill(Theme.divider).frame(height: 1) }
                        ProjectTodoSection(model: model, root: root)
                    }
                }
            }
        }
        .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: model.sections)
    }

    private var empty: some View {
        Text("No todos yet. When the agent in this tab plans its work, the steps and where it's got to show here, with the project's TODO.md.")
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The project's `TODO.md`: its open items by heading, the done ones
/// folded away, a field to add one, and a way to hand one to the agent.
private struct ProjectTodoSection: View {
    @ObservedObject var model: TodoModel
    let root: String
    @State private var draft = ""
    @State private var showsDone = false

    var body: some View {
        let list = model.project
        let fileName = (list?.path as NSString?)?.lastPathComponent ?? ProjectTodos.fileNames[0]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OctetIcon("folder", size: 12).foregroundStyle(Theme.textTertiary)
                Text((root as NSString).lastPathComponent)
                    .font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Text(fileName).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Spacer()
                if let list, !list.items.isEmpty {
                    Text("\(list.done.count) of \(list.items.count)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .help(list?.path ?? "Adding a todo makes \(fileName) in \(abbreviateHome(root))")
            if let list, !list.items.isEmpty {
                ProgressView(value: Double(list.done.count), total: Double(max(list.items.count, 1)))
                    .progressViewStyle(.linear)
                    .tint(list.open.isEmpty ? Color(hex: AgentStateColor.done) : Theme.accent)
                items(list.open)
                if !list.done.isEmpty {
                    Button {
                        showsDone.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            OctetIcon("chevron.down", size: 11).rotationEffect(.degrees(showsDone ? 0 : -90))
                            Text("\(list.done.count) done").font(Theme.captionFont)
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showsDone { items(list.done) }
                }
            } else {
                Text(list == nil
                     ? "No \(fileName) in this project yet. Add a todo to start one; agents can read and tick it too."
                     : "\(fileName) has no checkbox items yet (- [ ] like this).")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                OctetIcon("plus", size: 12).foregroundStyle(Theme.textTertiary)
                TextField("Add a todo", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .onSubmit {
                        model.add(draft)
                        draft = ""
                    }
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
        }
    }

    /// Rows with their heading above the first one under it.
    private func items(_ items: [ProjectTodoList.Item]) -> some View {
        let agent = model.agentInFront
        let agentName = agent.flatMap { AgentBrand.forAgent($0.agent)?.displayName ?? $0.agent }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let section = item.section, index == 0 || items[index - 1].section != section {
                    Text(section.uppercased())
                        .font(Theme.headerFont).kerning(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.top, index == 0 ? 0 : 6)
                        .padding(.horizontal, 6)
                }
                ProjectTodoRow(item: item, agentName: agentName,
                               toggle: { model.set(item, to: item.status == .completed ? .pending : .completed) },
                               hand: { model.handToAgent(item) })
            }
        }
    }
}

private struct ProjectTodoRow: View {
    let item: ProjectTodoList.Item
    /// The agent in the tab, when there is one to hand the item to.
    let agentName: String?
    let toggle: () -> Void
    let hand: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                OctetIcon(icon, size: 13)
                    .foregroundStyle(tint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .help(item.status == .completed ? "Mark as not done" : "Mark as done")
            Text(item.text)
                .font(item.status == .inProgress ? Theme.uiFontMedium : Theme.uiFont)
                .foregroundStyle(item.status == .completed ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(item.status == .completed, color: Theme.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let agentName, item.status != .completed {
                Button(action: hand) {
                    OctetIcon("arrow.right", size: 12)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .help("Hand to \(agentName): it works on this and ticks it off in the file")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(item.status == .inProgress ? Theme.accent.opacity(0.08) : hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(item.text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: item.status == .completed ? "Mark as not done" : "Mark as done", toggle)
    }

    private var icon: String {
        switch item.status {
        case .completed: "tool.todo.done"
        case .inProgress: "tool.todo.active"
        case .pending: "tool.todo.open"
        }
    }

    private var tint: Color {
        switch item.status {
        case .completed: Color(hex: AgentStateColor.done)
        case .inProgress: Theme.accent
        case .pending: Theme.textTertiary
        }
    }
}

private struct TodoSectionView: View {
    let section: TodoModel.Section
    let showsTitle: Bool

    var body: some View {
        let todos = section.todos
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let brand = AgentBrand.forAgent(section.agent) { AgentLogo(brand: brand, size: 12) }
                if showsTitle || AgentBrand.forAgent(section.agent) == nil {
                    Text(section.title).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(todos.completedCount == todos.count ? "Done" : "\(todos.completedCount) of \(todos.count)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            ProgressView(value: Double(todos.completedCount), total: Double(max(todos.count, 1)))
                .progressViewStyle(.linear)
                .tint(todos.completedCount == todos.count ? Color(hex: AgentStateColor.done) : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(todos) { todo in TodoRow(todo: todo) }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: AgentTodo
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            OctetIcon(icon, size: 13)
                .foregroundStyle(tint)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.shownText)
                    .font(todo.status == .inProgress ? Theme.uiFontMedium : Theme.uiFont)
                    .foregroundStyle(todo.status == .completed ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(todo.status == .completed, color: Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if hovered, let detail = todo.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(todo.status == .inProgress ? Theme.accent.opacity(0.08) : hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(todo.detail ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(status)
    }

    private var icon: String {
        switch todo.status {
        case .completed: "tool.todo.done"
        case .inProgress: "tool.todo.active"
        case .pending: "tool.todo.open"
        }
    }

    private var tint: Color {
        switch todo.status {
        case .completed: Color(hex: AgentStateColor.done)
        case .inProgress: Theme.accent
        case .pending: Theme.textTertiary
        }
    }

    private var status: String {
        switch todo.status {
        case .completed: "Done"
        case .inProgress: "In progress"
        case .pending: "Not started"
        }
    }
}

/// The tab bar's Todos button, with how far along the plan is.
struct TodoPanelButton: View {
    @ObservedObject var model: TodoModel
    @ObservedObject var ui: UIState
    @State private var hovered = false

    var body: some View {
        let todos = model.todos
        let projectOpen = model.project?.open.count ?? 0
        if !todos.isEmpty || projectOpen > 0 {
            button(todos, projectOpen: projectOpen)
        }
    }

    private func button(_ todos: [AgentTodo], projectOpen: Int) -> some View {
        Button { ui.showSidePanel(.todos) } label: {
            HStack(spacing: 5) {
                Text("Todos").font(Theme.uiFontMedium)
                if !todos.isEmpty {
                    Text("\(todos.completedCount)/\(todos.count)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(todos.completedCount == todos.count ? Color(hex: AgentStateColor.done) : Theme.textTertiary)
                } else if projectOpen > 0 {
                    // No agent plan: how many of the project's are open.
                    Text("\(projectOpen)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(todos.current.map { "Now: \($0.shownText)" }
              ?? (projectOpen > 0 ? "\(projectOpen) open in the project's TODO.md" : "Show todos"))
        .accessibilityLabel("Show todos")
    }
}
