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

/// The todo panel: each agent's plan, with where it's got to.
struct TodoPanel: View {
    @ObservedObject var model: TodoModel
    @ObservedObject var ui: UIState
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if model.sections.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.sections) { section in
                            TodoSectionView(section: section, showsTitle: model.sections.count > 1)
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.sidebar)
        .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: model.sections)
    }

    private var header: some View {
        let todos = model.todos
        return HStack(spacing: 7) {
            Text("Todos").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if !todos.isEmpty {
                Text("\(todos.completedCount)/\(todos.count)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button { ui.todoPanelVisible = false } label: {
                OctetIcon("xmark", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close the todo panel")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.tabBarHeight)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No todos yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("When the agent in this tab plans its work (Claude Code's tasks, Codex's plan, OpenCode's todos), the steps and where it's got to show here.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Binding var isShowing: Bool
    @State private var hovered = false

    var body: some View {
        let todos = model.todos
        if !todos.isEmpty || isShowing {
            button(todos)
        }
    }

    private func button(_ todos: [AgentTodo]) -> some View {
        Button { isShowing.toggle() } label: {
            HStack(spacing: 5) {
                Text("Todos").font(Theme.uiFontMedium)
                if !todos.isEmpty {
                    Text("\(todos.completedCount)/\(todos.count)")
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(todos.completedCount == todos.count ? Color(hex: AgentStateColor.done) : Theme.textTertiary)
                }
            }
            .foregroundStyle(isShowing ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(isShowing ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(todos.current.map { "Now: \($0.shownText)" } ?? "Show the agent's todos")
        .accessibilityLabel(isShowing ? "Hide todo panel" : "Show todo panel")
    }
}
