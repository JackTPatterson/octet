import AppKit
import SwiftUI

/// What's left to do in the workspace in front, for the Todos tab: what the
/// agents are doing (each one's plan, read from wherever it keeps it), your
/// own list for this checkout, the project's `TODO.md`, and what the
/// workspace is linked to (its issue, its waits). Each agent keeps its plan
/// its own way (Claude Code's task files, Codex's plan, OpenCode's database,
/// a TodoWrite call); `AgentTodos` reads them into one shape.
@MainActor
final class TodoModel: ObservableObject {
    /// One agent's plan.
    struct Section: Identifiable, Equatable {
        let id: String
        /// The agent's id, for its logo and name.
        let agent: String?
        let title: String
        let todos: [AgentTodo]
        /// Whether its turn is still going. A finished turn's plan folds to
        /// one line: progress belongs to the work under way.
        var running = true
        /// Where it is, for Open: an Octet conversation or a terminal pane.
        var conversationId: String?
        var paneId: String?
        var tabId: String?
    }

    /// Which list a personal or project item is in.
    enum ListKind: String, CaseIterable, Identifiable {
        case mine, project
        var id: String { rawValue }
        var title: String { self == .mine ? "Mine" : "Project" }
    }

    /// The sections the filter can hide.
    enum Source: String, CaseIterable, Identifiable {
        case agents, mine, project, linked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .agents: "Agents"
            case .mine: "Mine"
            case .project: "Project"
            case .linked: "Linked"
            }
        }
    }

    struct Filter: Codable, Equatable {
        var showDone = true
        var hidden: Set<String> = []
        func shows(_ source: Source) -> Bool { !hidden.contains(source.rawValue) }
    }

    /// A plan an agent's last turn ended on in plan mode, not yet carried out.
    struct ProposedPlan: Equatable {
        let sessionId: String
        let agent: String
        let plan: ComposerPlanFollowUp.Plan
    }

    /// The issue this checkout is linked to, and what the tracker says of it.
    struct LinkedIssue: Equatable {
        let link: WorkspaceIssueLink
        var status: String?
        var closed = false
        /// The description's own checkboxes, read-only.
        var steps: [AgentTodo] = []
    }

    @Published private(set) var sections: [Section] = []
    @Published private(set) var mine: ProjectTodoList?
    /// Where your own list is (or would be made) for this checkout.
    @Published private(set) var minePath: String?
    /// The project's list, from `TODO.md` at its root.
    @Published private(set) var project: ProjectTodoList?
    /// The root of the project in front, where `TODO.md` is or would go.
    @Published private(set) var projectRoot: String?
    @Published private(set) var links = TodoLinks()
    @Published private(set) var proposed: ProposedPlan?
    @Published private(set) var issue: LinkedIssue?
    @Published private(set) var waits: [Wait] = []
    @Published var filter = Filter() { didSet { saveFilter() } }
    /// Items just ticked, left where they were a moment so the tick is seen
    /// before they fold into "n done".
    @Published private(set) var lingering: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var listsLoading = false

    private weak var window: WindowContext?
    private var timer: Timer?
    private var listsLoaded = false
    /// The files last read, so each is parsed again only when it changes.
    private var lastRead: [String: Date] = [:]
    private var watchers: [String: TodoFileWatcher] = [:]
    /// A Codex rollout is re-read only when it has changed.
    private var rollouts: [String: (modified: Date, plan: [AgentTodo]?)] = [:]
    /// Steps finished per plan, to say so when one more is.
    private var finishedSteps: [String: Int] = [:]
    private var lastAnnouncement = Date.distantPast
    private var issueFetched: String?
    static let interval: TimeInterval = 2.5

    /// Set while the sample is up, so reading the real lists doesn't replace it.
    private var sampling = false

    /// All steps across the plans, for the tab bar's count.
    var todos: [AgentTodo] { sections.flatMap(\.todos) }

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Nothing is read while neither Todos nor the Overview is on screen.
                guard let self, self.isVisible else { return }
                self.refresh()
            }
        }
    }

    /// Whether the panel that shows these is on screen.
    var isVisible: Bool {
        guard let ui = window?.ui else { return false }
        return ui.showing(.todos) || ui.showing(.overview)
    }

    func list(_ kind: ListKind) -> ProjectTodoList? { kind == .mine ? mine : project }

    func path(of kind: ListKind) -> String? {
        switch kind {
        case .mine: minePath
        case .project: project?.path ?? projectRoot.map { ProjectTodos.path(inRoot: $0) }
        }
    }

    // MARK: - Agent plans

    private enum PlanSource {
        case conversation(AgentSession)
        case claudeTasks(sessionId: String)
        case codexRollout(sessionId: String)
        case openCode(sessionId: String)
    }

    private struct PlanEntry {
        let section: Section
        let source: PlanSource
    }

    func refresh() {
        if sampling { return }
        guard let window else { return }
        refreshLists(window)
        refreshLinked(window)
        guard !loading else { return }
        let store = window.store
        let workspaceId = window.focusedWorkspace?.workspaceId
        var entries: [PlanEntry] = []
        // Every conversation in the workspace, the ones working first.
        let sessions = AgentCenter.shared.sessions(in: workspaceId)
            .sorted { $0.conversation.isRunning && !$1.conversation.isRunning }
        for session in sessions {
            entries.append(PlanEntry(section: Section(id: "conversation:\(session.id)", agent: session.engine.agent,
                                                      title: session.title, todos: [],
                                                      running: session.conversation.isRunning, conversationId: session.id),
                                     source: .conversation(session)))
        }
        // The terminal agents in the tab in front.
        if let tabId = window.displayedFocusedTabId {
            for agent in store.snapshot.agents where agent.tabId == tabId && !agent.isSubagentViewer {
                let brand = AgentBrand.forAgent(agent.agent)
                guard let brandId = brand?.id,
                      let sessionId = store.recovery.sessionId(of: agent)
                else { continue }
                let section = Section(id: "pane:\(agent.paneId)", agent: brandId, title: brand?.displayName ?? brandId, todos: [],
                                      running: [.working, .blocked].contains(agent.agentStatus),
                                      paneId: agent.paneId, tabId: agent.tabId)
                switch brandId {
                case "claude": entries.append(PlanEntry(section: section, source: .claudeTasks(sessionId: sessionId)))
                case "codex": entries.append(PlanEntry(section: section, source: .codexRollout(sessionId: sessionId)))
                case "opencode": entries.append(PlanEntry(section: section, source: .openCode(sessionId: sessionId)))
                default: continue
                }
            }
        }
        proposed = Self.proposedPlan(in: sessions)
        // A conversation's own list is already in memory; files are read off
        // the main thread.
        var ready: [String: [AgentTodo]] = [:]
        var claudeFiles: [String: String] = [:]
        for entry in entries {
            if case .conversation(let session) = entry.source {
                if session.engine == .claude {
                    claudeFiles[entry.section.id] = session.conversation.sessionId ?? session.sessionId
                }
                ready[entry.section.id] = session.conversation.plan ?? AgentTodos.latest(in: session.conversation.items)
            }
        }
        loading = true
        let rollouts = self.rollouts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found = ready
            var seenRollouts: [String: (modified: Date, plan: [AgentTodo]?)] = [:]
            for entry in entries {
                let id = entry.section.id
                switch entry.source {
                case .conversation:
                    // Claude Code keeps its tasks in files whichever way it runs.
                    if let file = claudeFiles[id],
                       let tasks = AgentTodos.claudeTasks(in: AgentTodos.claudeTasksDirectory(sessionId: file)) {
                        found[id] = tasks
                    }
                case .claudeTasks(let sessionId):
                    found[id] = AgentTodos.claudeTasks(in: AgentTodos.claudeTasksDirectory(sessionId: sessionId))
                case .codexRollout(let sessionId):
                    guard let path = AgentSessionFiles.codexPath(forSession: sessionId) else { continue }
                    let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    if let cached = rollouts[path], cached.modified == modified {
                        seenRollouts[path] = cached
                        found[id] = cached.plan
                    } else {
                        let plan = AgentTodos.codexPlan(inRollout: path)
                        seenRollouts[path] = (modified, plan)
                        found[id] = plan
                    }
                case .openCode(let sessionId):
                    found[id] = AgentTodos.openCodeTodos(sessionId: sessionId)
                }
            }
            let sections = entries.compactMap { entry -> Section? in
                guard let todos = found[entry.section.id], !todos.isEmpty else { return nil }
                var section = entry.section
                section = Section(id: section.id, agent: section.agent, title: section.title, todos: todos,
                                  running: section.running, conversationId: section.conversationId,
                                  paneId: section.paneId, tabId: section.tabId)
                return section
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.loaded = true
                self.rollouts = seenRollouts
                self.announceProgress(sections)
                if sections != self.sections { self.sections = sections }
            }
        }
    }

    /// The plan a conversation's last turn ended on while it's in plan
    /// mode, as the composer's banner reads it.
    private static func proposedPlan(in sessions: [AgentSession]) -> ProposedPlan? {
        for session in sessions {
            if let plan = ComposerPlanFollowUp.latestPlan(in: session.conversation.items, planMode: session.isPlanning,
                                                          running: session.conversation.isRunning) {
                return ProposedPlan(sessionId: session.id, agent: session.engine.agent, plan: plan)
            }
        }
        return nil
    }

    /// "Claude: 4 of 5 done" to VoiceOver as a step finishes, at most every
    /// five seconds, and only while the list is on screen.
    private func announceProgress(_ sections: [Section]) {
        defer { finishedSteps = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.todos.completedCount) }) }
        guard isVisible, Date().timeIntervalSince(lastAnnouncement) >= 5 else { return }
        for section in sections {
            guard let before = finishedSteps[section.id], section.todos.completedCount > before else { continue }
            let name = AgentBrand.forAgent(section.agent)?.displayName ?? section.title
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(name): \(section.todos.completedCount) of \(section.todos.count) done",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            lastAnnouncement = Date()
            return
        }
    }
}

// MARK: - Your list and the project's

extension TodoModel {
    /// Re-reads your list and the project's when the project in front
    /// changed, or a file did. Watched files say so themselves; the rest are
    /// looked at on each tick.
    fileprivate func refreshLists(_ window: WindowContext, force: Bool = false) {
        if sampling { return }
        let directory = window.focusedWorkspace.flatMap { window.store.snapshot.directory(ofWorkspace: $0.workspaceId) }
        let root = directory.map { GitBranch.location(for: $0)?.root ?? $0 }
        if root != projectRoot {
            projectRoot = root
            project = nil
            mine = nil
            minePath = nil
            links = TodoLinks()
            lastRead = [:]
            watchers = [:]
            listsLoaded = false
            listsLoading = false
            issue = nil
            issueFetched = nil
            filter = Self.loadFilter(for: root)
        }
        guard let root, let directory else { return }
        // Both files watched: they say when they change, so the tick needn't look.
        if !force, listsLoaded, let minePath, watchers[minePath]?.isWatching == true,
           watchers[ProjectTodos.path(inRoot: root)]?.isWatching == true { return }
        if !listsLoaded { listsLoading = true }
        let last = lastRead
        let support = EngineSession.supportDirectory
        let knownMine = minePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let minePath = knownMine ?? PersonalTodos.path(in: directory, fallback: support)
            let projectPath = ProjectTodos.path(inRoot: root)
            func modified(_ path: String) -> Date? {
                (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            }
            let mineDate = modified(minePath), projectDate = modified(projectPath)
            let linksPath = PersonalTodos.linksPath(besideList: minePath)
            let linksDate = modified(linksPath)
            func read(_ path: String, _ date: Date?) -> ProjectTodoList?? {
                if let date, last[path] == date { return .none }
                return .some(date == nil ? nil : (try? String(contentsOfFile: path, encoding: .utf8)).map { ProjectTodos.parse($0, path: path) })
            }
            let mine = read(minePath, mineDate)
            let project = read(projectPath, projectDate)
            let links = linksDate != nil && last[linksPath] == linksDate ? nil : TodoLinks.load(from: linksPath)
            DispatchQueue.main.async {
                guard let self, self.projectRoot == root else { return }
                self.listsLoading = false
                self.listsLoaded = true
                self.minePath = minePath
                self.lastRead[minePath] = mineDate
                self.lastRead[projectPath] = projectDate
                self.lastRead[linksPath] = linksDate
                if case .some(let list) = mine, list != self.mine { self.mine = list }
                if case .some(let list) = project, list != self.project { self.project = list }
                if let links, links != self.links { self.links = links }
                self.watch([minePath, projectPath])
            }
        }
    }

    /// Watches each file for writes, so an agent ticking an item shows at
    /// once. A file that doesn't exist yet is looked for on the tick.
    private func watch(_ paths: [String]) {
        for path in paths where watchers[path]?.isWatching != true {
            watchers[path] = TodoFileWatcher(path: path) { [weak self] in
                guard let self, let window = self.window else { return }
                self.lastRead[path] = nil
                self.refreshLists(window, force: true)
            }
        }
    }

    /// Marks an item, checking first that its line still holds it: the file
    /// may have changed since it was read.
    func set(_ item: ProjectTodoList.Item, in kind: ListKind, to status: AgentTodo.Status) {
        if status == .completed, item.status != .completed { linger(item.id) }
        change(kind, item) { ProjectTodos.setting(status, line: item.line, in: $0) }
    }

    /// A ticked item stays a moment, then folds into "n done".
    private func linger(_ id: String) {
        lingering.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MotionPreferences.shared.perform(.sidebar) { _ = self?.lingering.remove(id) }
        }
    }

    /// Adds open items, one per line, making the file if there's none.
    func add(_ text: String, to kind: ListKind) {
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !entries.isEmpty, let path = path(of: kind) else { return }
        edit(path) { contents in entries.reduce(contents) { ProjectTodos.adding($1, to: $0) } }
    }

    func rename(_ item: ProjectTodoList.Item, in kind: ListKind, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        let newId = ProjectTodos.identity(section: item.section, text: trimmed, occurrence: 0)
        change(kind, item) { ProjectTodos.editing(trimmed, line: item.line, in: $0) }
        updateLinks { $0.rename(item.id, to: newId) }
    }

    /// Deletes an item, with Undo on the notice while the file is as it left it.
    func delete(_ item: ProjectTodoList.Item, in kind: ListKind) {
        guard let path = path(of: kind) else { return }
        edit(path, check: item) { ProjectTodos.removing(line: item.line, in: $0) } done: { [weak self] before, after in
            ToastCenter.shared.info("Deleted todo", detail: item.text, after: 6, action: .init(title: "Undo") {
                self?.edit(path) { current in current == after ? before : nil }
            })
        }
    }

    /// Moves an item up or down among the items under its heading.
    func move(_ item: ProjectTodoList.Item, in kind: ListKind, by offset: Int) {
        guard let list = list(kind) else { return }
        let group = list.items.filter { $0.section == item.section }
        guard let index = group.firstIndex(where: { $0.id == item.id }), group.indices.contains(index + offset) else { return }
        let target = group[index + offset]
        change(kind, item) { contents in
            offset < 0 ? ProjectTodos.moving(line: item.line, before: target.line, in: contents)
                : ProjectTodos.moving(line: item.line, after: target.line, in: contents)
        }
    }

    /// A drop: `item` lands just before `target`, under the same heading.
    func move(_ item: ProjectTodoList.Item, before target: ProjectTodoList.Item, in kind: ListKind) {
        guard item.id != target.id, item.section == target.section else { return }
        change(kind, item) { ProjectTodos.moving(line: item.line, before: target.line, in: $0) }
    }

    /// From your list to the project's or back: added there, then taken out
    /// here, so a failed write never loses it.
    func transfer(_ item: ProjectTodoList.Item, from kind: ListKind) {
        let other: ListKind = kind == .mine ? .project : .mine
        guard let from = path(of: kind), let to = path(of: other) else { return }
        edit(to) { ProjectTodos.adding(item.text, to: $0) } done: { [weak self] _, _ in
            self?.edit(from, check: item) { ProjectTodos.removing(line: item.line, in: $0) }
            ToastCenter.shared.info("Moved to \(other == .mine ? "your todos" : (to as NSString).lastPathComponent)", detail: item.text)
        }
    }

    /// A plan's steps added to the project's list under its own heading.
    func saveToProject(_ plan: ComposerPlanFollowUp.Plan) {
        guard let checklist = ProjectTodos.checklist(fromPlan: plan.markdown, title: plan.title),
              let path = path(of: .project) else {
            ToastCenter.shared.info("This plan has no steps to list", detail: "Only numbered or bulleted steps become todos.")
            return
        }
        edit(path) { ProjectTodos.appending(checklist, to: $0) } done: { _, _ in
            ToastCenter.shared.info("Added the plan to \((path as NSString).lastPathComponent)", detail: plan.title)
        }
    }

    /// Starts `TODO.md` at the project root, with nothing in it yet.
    func startProjectList() {
        guard let path = path(of: .project) else { return }
        edit(path) { $0.isEmpty ? "# TODO\n\n" : $0 }
    }

    func link(for item: ProjectTodoList.Item) -> TodoLink? { links[item.id] }

    func updateLink(_ item: ProjectTodoList.Item, _ change: @escaping (inout TodoLink) -> Void) {
        updateLinks { links in
            var link = links[item.id] ?? TodoLink()
            change(&link)
            links[item.id] = link
        }
    }

    /// Changes the links and saves them beside your list, dropping any for
    /// items that are gone.
    private func updateLinks(_ change: (inout TodoLinks) -> Void) {
        var next = links
        change(&next)
        let ids = Set((mine?.items ?? []).map(\.id) + (project?.items ?? []).map(\.id))
        next = TodoLinks(links: next.links.filter { ids.contains($0.key) || !links.links.keys.contains($0.key) })
        guard next != links, let minePath else { return }
        links = next
        let path = PersonalTodos.linksPath(besideList: minePath)
        let saved = next
        DispatchQueue.global(qos: .utility).async {
            do { try saved.save(to: path) } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't save the todo's links", detail: error.localizedDescription)
                }
            }
        }
    }

    /// Changes the item's list, checking the line still holds the item.
    private func change(_ kind: ListKind, _ item: ProjectTodoList.Item, _ transform: @escaping (String) -> String?) {
        guard let path = path(of: kind) else { return }
        edit(path, check: item, transform)
    }

    /// Reads, changes and writes the file off the main thread, then reads it
    /// back so the panel shows the result straight away. `check`: the item
    /// must still be on its line, or nothing is written. `done` hears the
    /// contents before and after, once written.
    private func edit(_ path: String, check item: ProjectTodoList.Item? = nil, _ transform: @escaping (String) -> String?,
                      done: ((String, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            var failure: String?
            var written: String?
            let current = item.flatMap { item in ProjectTodos.parse(contents, path: path).items.first { $0.line == item.line } }
            if let item, current?.text != item.text {
                failure = "The item moved in the file. Try again."
            } else if let changed = transform(contents) {
                if changed != contents {
                    do {
                        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                                withIntermediateDirectories: true)
                        try changed.write(toFile: path, atomically: true, encoding: .utf8)
                        written = changed
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            } else {
                failure = "The file changed since it was read. Try again."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    ToastCenter.shared.fail(nil, "Couldn't update \((path as NSString).lastPathComponent)", detail: failure)
                } else if let written {
                    done?(contents, written)
                }
                self.lastRead[path] = nil
                if let window = self.window { self.refreshLists(window, force: true) }
            }
        }
    }

    // MARK: - Filter

    private static func filterKey(_ root: String?) -> String { "octet.todos.filter." + (root ?? "") }

    private static func loadFilter(for root: String?) -> Filter {
        guard let data = UserDefaults.standard.data(forKey: filterKey(root)),
              let filter = try? JSONDecoder().decode(Filter.self, from: data) else { return Filter() }
        return filter
    }

    private func saveFilter() {
        guard !sampling, let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: Self.filterKey(projectRoot))
    }
}

// MARK: - Linked: the issue and the waits

extension TodoModel {
    fileprivate func refreshLinked(_ window: WindowContext) {
        if sampling { return }
        let workspaceId = window.focusedWorkspace?.workspaceId
        let found = WaitCenter.shared.waiting.filter { $0.origin.workspaceId == workspaceId }
        if found != waits { waits = found }
        guard let directory = window.focusedWorkspace.flatMap({ window.store.snapshot.directory(ofWorkspace: $0.workspaceId) }) else {
            issue = nil
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let link = try? WorkspaceIssueLink.read(in: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let link else {
                    if self.issue != nil { self.issue = nil }
                    return
                }
                if self.issue?.link != link { self.issue = LinkedIssue(link: link) }
                self.fetchIssue(link, directory: directory)
            }
        }
    }

    /// What the tracker says of the issue, once per link: its status and
    /// the checkboxes in its description.
    private func fetchIssue(_ link: WorkspaceIssueLink, directory: String) {
        let key = link.tracker + link.key
        guard issueFetched != key, let tracker = IssueTracker(rawValue: link.tracker)
                ?? IssueTracker.allCases.first(where: { $0.rawValue.lowercased() == link.tracker.lowercased() }) else { return }
        issueFetched = key
        Task { [weak self] in
            guard let found = try? await IssueService.issue(tracker: tracker, key: link.key, connectionId: link.connectionId,
                                                            directory: directory) else { return }
            let steps = ProjectTodos.parse(found.body, path: "").items.map {
                AgentTodo(id: $0.id, text: $0.text, activeText: nil, status: $0.status, detail: nil)
            }
            guard let self, self.issue?.link == link else { return }
            self.issue = LinkedIssue(link: link, status: found.stateName, closed: found.closed, steps: steps)
        }
    }

    /// The wait set on an item, found by its title.
    func wait(for item: ProjectTodoList.Item) -> Wait? {
        waits.first { $0.title == item.text }
    }
}

// MARK: - Sample

#if DEBUG
extension TodoModel {
    /// Verification and demos: made-up plans and lists. "empty" has nothing;
    /// "partial" one finished plan and a project list; "linked" adds an
    /// issue and a wait; "done" has everything ticked; anything else is the
    /// full set.
    func loadSample(variant: String? = nil) {
        sampling = true
        projectRoot = NSHomeDirectory()
        minePath = NSHomeDirectory() + "/.git/octet-todos.md"
        filter = Filter()
        if variant == "empty" {
            sections = []
            project = nil
            mine = nil
            loaded = true
            return
        }
        func item(_ line: Int, _ text: String, _ status: AgentTodo.Status, _ section: String?) -> ProjectTodoList.Item {
            .init(line: line, text: text, status: status, section: section)
        }
        let allDone = variant == "done"
        sections = [
            Section(id: "sample-claude", agent: "claude", title: "Fix the upload retry", todos: [
                AgentTodo(id: "a1", text: "Find every retry call site", activeText: nil, status: .completed, detail: nil),
                AgentTodo(id: "a2", text: "Cap the backoff at 30 seconds", activeText: nil, status: .completed, detail: nil),
                AgentTodo(id: "a3", text: "Add jitter to the delay", activeText: "Adding jitter to the delay",
                          status: allDone ? .completed : .inProgress, detail: nil),
                AgentTodo(id: "a4", text: "Write tests for both", activeText: nil, status: allDone ? .completed : .pending, detail: nil),
            ], running: !allDone, conversationId: nil),
            Section(id: "sample-codex", agent: "codex", title: "Review the auth flow", todos: [
                AgentTodo(id: "b1", text: "Read the session code", activeText: nil, status: .completed, detail: nil),
                AgentTodo(id: "b2", text: "List the places a token is logged", activeText: nil, status: allDone ? .completed : .pending, detail: nil),
                AgentTodo(id: "b3", text: "Propose fixes", activeText: nil, status: allDone ? .completed : .pending, detail: nil),
            ], running: false),
        ]
        if variant == "partial" {
            sections = [Section(id: "sample-claude", agent: "claude", title: "Fix the upload retry", todos: [
                AgentTodo(id: "a1", text: "Find every retry call site", activeText: nil, status: .completed, detail: nil),
                AgentTodo(id: "a2", text: "Cap the backoff at 30 seconds", activeText: nil, status: .completed, detail: nil),
                AgentTodo(id: "a3", text: "Add jitter to the delay", activeText: nil, status: .completed, detail: nil),
            ], running: false)]
        }
        mine = ProjectTodoList(path: minePath!, items: allDone ? [item(0, "Reply to the design review", .completed, nil)] : [
            item(0, "Reply to the design review", .pending, nil),
            item(1, "Try the new scroll capture on the big repo", .inProgress, nil),
            item(2, "Clean up the stale worktrees", .completed, nil),
        ])
        project = ProjectTodoList(path: NSHomeDirectory() + "/TODO.md", items: [
            item(0, "Ship build 21", allDone ? .completed : .inProgress, "Release"),
            item(1, "Renew the notarization password", allDone ? .completed : .pending, "Release"),
            item(2, "Write the release notes", allDone ? .completed : .pending, "Release"),
            item(4, "Branch picker in the Git panel", allDone ? .completed : .pending, "Later"),
            item(7, "Project content search", .completed, "Done"),
        ])
        links = TodoLinks(links: [ProjectTodos.identity(section: nil, text: "Try the new scroll capture on the big repo", occurrence: 0):
                                    TodoLink(agent: "claude", agentName: "Claude", issueKey: "CLX-12")])
        if variant == "linked" || variant == nil {
            issue = LinkedIssue(link: WorkspaceIssueLink(tracker: "Linear", connectionId: nil, issueId: "1", key: "CLX-12",
                                                         title: "Uploads retry forever on a flaky network",
                                                         url: URL(string: "https://linear.app/octet/issue/CLX-12")),
                                status: "In Progress",
                                steps: [AgentTodo(id: "i1", text: "Backoff is capped", activeText: nil, status: .completed, detail: nil),
                                        AgentTodo(id: "i2", text: "Retries show in the share sheet", activeText: nil, status: .pending, detail: nil)])
            waits = [Wait(title: "Reply to the design review",
                          condition: .date(Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()),
                          next: "Reply to the design review",
                          origin: Wait.Origin(cwd: NSHomeDirectory()))]
        }
        loaded = true
        listsLoaded = true
    }
}
#endif
