import Combine
import Foundation

/// The phone host's view of this Octet: native agent conversations and the
/// agents running in terminal panes, read from the live session. Reads are
/// answered from a cache the main actor keeps fresh, so the network queue
/// never waits on the interface.
final class OctetPhoneBackend: PhoneHostBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedProjects: [PhoneProject] = []
    private var cachedThreads: [PhoneThread] = []
    private var cachedItems: [String: [PhoneItem]] = [:]
    private var paneText: [String: (text: String, at: Date)] = [:]
    /// What each pane's agent is running, for the transcript reader.
    private var paneAgents: [String: PaneAgent] = [:]
    private var tails: [String: TwinTail] = [:]
    private var tailSources: [String: TwinSource] = [:]
    private var firstSeen: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var sessionSubscriptions: [String: AnyCancellable] = [:]
    private var refreshScheduled = false
    private let reader = DispatchQueue(label: "octet.phonehost.transcripts", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private weak var store: SessionStore?

    var onChange: (() -> Void)?

    private struct PaneAgent {
        var agent: String
        var sessionRef: String?
        var cwds: [String]
        var since: Date
    }

    static let maxItems = 300

    var machineName: String { lock.withLock { name } }
    private var name = Host.current().localizedName ?? "This Mac"
    var homeFolder: String { lock.withLock { cachedProjects.first?.folder } ?? NSHomeDirectory() }

    // MARK: - Lifecycle

    @MainActor
    func start(store: SessionStore, machineName: String) {
        self.store = store
        lock.withLock { name = machineName }
        store.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        AgentCenter.shared.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: reader)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollPanes() }
        timer.resume()
        pollTimer = timer
    }

    @MainActor
    func stop() {
        cancellables = []
        sessionSubscriptions = [:]
        pollTimer?.cancel()
        pollTimer = nil
        onChange = nil
    }

    @MainActor
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // objectWillChange fires before the change lands, and bursts of
        // tokens shouldn't each rebuild everything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    // MARK: - Reading the session (main actor)

    @MainActor
    private func refresh() {
        guard let store else { return }
        let snapshot = store.snapshot
        let now = Date()

        var projects: [PhoneProject] = []
        for workspace in snapshot.workspaces {
            let folder = snapshot.directory(ofWorkspace: workspace.workspaceId) ?? NSHomeDirectory()
            projects.append(PhoneProject(id: workspace.workspaceId, title: workspace.label, folder: folder,
                                         createdAt: first(seen: "w:" + workspace.workspaceId, now), updatedAt: now))
        }

        var threads: [PhoneThread] = []
        var items: [String: [PhoneItem]] = [:]
        var panes: [String: PaneAgent] = [:]

        // Native conversations.
        let sessions = AgentCenter.shared.sessions
        for session in sessions {
            guard projects.contains(where: { $0.id == session.workspaceId }) else { continue }
            let (thread, list) = Self.thread(for: session, createdAt: first(seen: "s:" + session.id, now))
            threads.append(thread)
            items[thread.id] = list
        }
        resubscribe(to: sessions)

        // Agents running in terminal panes.
        for agent in snapshot.agents where agent.agent != nil && !agent.isSubagentViewer {
            let folder = agent.foregroundCwd ?? agent.cwd ?? snapshot.workingDirectory(ofPane: agent.paneId) ?? ""
            let workspace = agent.workspaceId ?? snapshot.panes.first { $0.paneId == agent.paneId }?.workspaceId
            guard let workspace, projects.contains(where: { $0.id == workspace }) else { continue }
            let id = "p:" + agent.paneId
            let brand = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
            let started = first(seen: id, now)
            threads.append(PhoneThread(
                id: id, projectID: workspace, title: folder.isEmpty ? brand : "\(brand) · \((folder as NSString).lastPathComponent)",
                agent: AgentBrand.forAgent(agent.agent)?.id ?? agent.agent ?? "agent", model: nil, status: Self.status(agent.agentStatus),
                createdAt: started, updatedAt: now, approval: nil))
            panes[id] = PaneAgent(agent: agent.agent ?? "", sessionRef: agent.sessionReference,
                                  cwds: [agent.foregroundCwd, agent.cwd].compactMap { $0 }, since: started)
        }

        lock.withLock {
            cachedProjects = projects
            cachedThreads = threads
            paneAgents = panes
            for (id, list) in items { cachedItems[id] = list }
            let live = Set(threads.map(\.id))
            cachedItems = cachedItems.filter { live.contains($0.key) }
            tails = tails.filter { live.contains($0.key) }
            tailSources = tailSources.filter { live.contains($0.key) }
        }
        onChange?()
    }

    private func first(seen key: String, _ now: Date) -> Date {
        lock.withLock {
            if let date = firstSeen[key] { return date }
            firstSeen[key] = now
            return now
        }
    }

    /// A session's own changes (tokens, tool results) don't touch the
    /// center, so each is watched.
    @MainActor
    private func resubscribe(to sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.id))
        sessionSubscriptions = sessionSubscriptions.filter { ids.contains($0.key) }
        for session in sessions where sessionSubscriptions[session.id] == nil {
            sessionSubscriptions[session.id] = session.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
        }
    }

    @MainActor
    static func thread(for session: AgentSession, createdAt: Date) -> (PhoneThread, [PhoneItem]) {
        let all = session.conversation.items.filter { $0.parent == nil }
        var list: [PhoneItem] = []
        for item in all.suffix(maxItems) {
            switch item.kind {
            case .user(let text): list.append(.user(id: item.id, text: text, at: item.createdAt))
            case .text(let text): list.append(.assistant(id: item.id, text: text, at: item.createdAt))
            case .thinking(let text): list.append(.reasoning(id: item.id, text: text, at: item.createdAt))
            case .tool(let call):
                list.append(.tool(id: item.id, name: call.name, input: call.summary, output: call.result ?? call.liveOutput,
                                  failed: call.isError, at: item.createdAt))
            case .notice: continue
            }
        }
        var approval: PhoneApproval?
        if let request = session.pendingPermission {
            approval = PhoneApproval(id: request.id, kind: kind(ofTool: request.toolName),
                                     prompt: "\(request.toolName): \(request.summary)", createdAt: Date())
        }
        let waiting = approval != nil || session.pendingQuestion != nil
        let status: PhoneThreadStatus = waiting ? .waiting
            : session.conversation.isRunning ? .running
            : session.conversation.lastError != nil ? .failed
            : session.hasTurns ? .completed : .idle
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = PhoneThread(
            id: "s:" + session.id, projectID: session.workspaceId,
            title: title.isEmpty ? session.engine.displayName : title,
            agent: session.engine.agent, model: session.model, status: status,
            createdAt: all.first?.createdAt ?? createdAt, updatedAt: all.last?.createdAt ?? createdAt, approval: approval)
        return (thread, list)
    }

    static func kind(ofTool name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell": "command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "file-change"
        case "Read", "Glob", "Grep", "LS": "file-read"
        default: "permission"
        }
    }

    static func status(_ status: EngineAgentStatus) -> PhoneThreadStatus {
        switch status {
        case .working: .running
        case .blocked: .waiting
        case .done: .completed
        case .idle, .unknown: .idle
        }
    }

    // MARK: - Terminal-pane transcripts (background)

    /// Reads whatever the pane agents' session files gained since last time.
    private func pollPanes() {
        let agents = lock.withLock { paneAgents }
        guard !agents.isEmpty else { return }
        var changed = false
        for (id, agent) in agents {
            var tail = lock.withLock { tails[id] } ?? TwinTail(format: AgentBrand.forAgent(agent.agent)?.id)
            let cached = lock.withLock { tailSources[id] }
            guard let source = cached ?? TwinSources.locate(agent: agent.agent, sessionId: agent.sessionRef, cwds: agent.cwds, since: agent.since) else { continue }
            let updated = tail.pull(path: source.path)
            let conversation = tail.conversation
            lock.withLock {
                tails[id] = tail
                tailSources[id] = source
            }
            guard updated || lock.withLock({ cachedItems[id] }) == nil else { continue }
            let list = Self.items(from: conversation)
            lock.withLock { cachedItems[id] = list }
            changed = true
        }
        if changed { onChange?() }
    }

    static func items(from conversation: TwinConversation) -> [PhoneItem] {
        var list: [PhoneItem] = []
        var open: [String: Int] = [:]
        for message in conversation.messages {
            let at = message.at ?? Date()
            for (index, block) in message.blocks.enumerated() {
                let id = "\(message.id)-\(index)"
                switch block {
                case .text(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    list.append(message.role == .user ? .user(id: id, text: text, at: at) : .assistant(id: id, text: text, at: at))
                case .thinking(let text):
                    list.append(.reasoning(id: id, text: text, at: at))
                case .toolCall(let callID, let name, let summary):
                    open[callID] = list.count
                    list.append(.tool(id: id, name: name, input: summary, output: nil, failed: false, at: at))
                case .toolResult(let callID, let summary, let isError):
                    if let position = open[callID], case .tool(let id, let name, let input, _, _, let at) = list[position] {
                        list[position] = .tool(id: id, name: name, input: input, output: summary, failed: isError, at: at)
                    }
                }
            }
        }
        return Array(list.suffix(maxItems))
    }

    // MARK: - PhoneHostBackend

    func projects() -> [PhoneProject] { lock.withLock { cachedProjects } }
    func threads() -> [PhoneThread] { lock.withLock { cachedThreads } }
    func transcript(of threadID: String) -> [PhoneItem] { lock.withLock { cachedItems[threadID] ?? [] } }

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private static func paneID(_ threadID: String) -> String? {
        threadID.hasPrefix("p:") ? String(threadID.dropFirst(2)) : nil
    }

    private static func sessionID(_ threadID: String) -> String? {
        threadID.hasPrefix("s:") ? String(threadID.dropFirst(2)) : nil
    }

    func providers() -> [PhoneProvider] {
        onMainSync {
            let installed = Set(AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id))
            var list: [PhoneProvider] = []
            if installed.contains("claude") {
                let models = AgentSession.models.map { PhoneModel(id: $0.id, name: $0.title, isDefault: $0.id == AgentSession.defaultModel) }
                list.append(PhoneProvider(id: "claude", name: "Claude", models: models))
            }
            if installed.contains("codex") {
                let catalog = CodexCatalogStore.shared
                list.append(PhoneProvider(id: "codex", name: "Codex",
                                          models: catalog.models.map { PhoneModel(id: $0.id, name: $0.displayName, isDefault: $0.isDefault) }))
            }
            return list.filter { !$0.models.isEmpty }
        }
    }

    func setModel(_ model: String, provider: String, for threadID: String, completion: @escaping (Result<String, PhoneHostError>) -> Void) {
        guard let sessionID = Self.sessionID(threadID) else {
            return completion(.failure(.failed("Change the model of a terminal agent in its terminal.")))
        }
        onMain { [weak self] in
            guard let session = AgentCenter.shared.sessions.first(where: { $0.id == sessionID }) else {
                return completion(.failure(.notFound("That conversation is closed.")))
            }
            guard let engine = AgentSession.Engine(rawValue: provider) else {
                return completion(.failure(.failed("Octet can't run \(provider) from here.")))
            }
            if engine == session.engine {
                session.model = model
                completion(.success(threadID))
                return
            }
            // Another agent can't take over a live process, so the work
            // carries on there from a brief of what's been done.
            guard let store = self?.store, ConversationHandoff.otherEngines(than: session).contains(engine) else {
                return completion(.failure(.failed("\(engine.displayName) isn't installed here.")))
            }
            guard ConversationHandoff.canHandOff(session) else {
                return completion(.failure(.failed("There's nothing to carry over yet. Start a new conversation in \(engine.displayName) instead.")))
            }
            let next = ConversationHandoff.continueConversation(session, in: engine, store: store)
            next.model = model
            completion(.success("s:" + next.id))
        }
    }

    func send(_ text: String, to threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        if let sessionID = Self.sessionID(threadID) {
            onMain {
                guard let session = AgentCenter.shared.sessions.first(where: { $0.id == sessionID }) else {
                    return completion(.failure(.notFound("That conversation is closed.")))
                }
                completion(session.send(text) ? .success(()) : .failure(.failed("Octet couldn't send that just now.")))
            }
        } else if let pane = Self.paneID(threadID) {
            onMain { [weak self] in
                guard let client = self?.store?.client else { return completion(.failure(.failed("Octet has no session open."))) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let failed = Broadcast.deliver(text, to: [.init(paneId: pane, name: pane, isAgent: true)]) { method, params in
                        _ = try client.call(method, params)
                    }
                    completion(failed.isEmpty ? .success(()) : .failure(.failed("Octet couldn't deliver that to the agent.")))
                }
            }
        } else {
            completion(.failure(.notFound("No such agent.")))
        }
    }

    func interrupt(_ threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        if let sessionID = Self.sessionID(threadID) {
            onMain {
                guard let session = AgentCenter.shared.sessions.first(where: { $0.id == sessionID }) else {
                    return completion(.failure(.notFound("That conversation is closed.")))
                }
                session.interrupt()
                completion(.success(()))
            }
        } else if let pane = Self.paneID(threadID) {
            type("\u{1b}", paneID: pane, completion: completion)
        } else {
            completion(.failure(.notFound("No such agent.")))
        }
    }

    func answer(approval: String, in threadID: String, allow: Bool, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        guard let sessionID = Self.sessionID(threadID) else {
            return completion(.failure(.failed("Answer this one on the Mac: it's in a terminal.")))
        }
        onMain {
            guard let session = AgentCenter.shared.sessions.first(where: { $0.id == sessionID }),
                  session.pendingPermission?.id == approval else {
                return completion(.failure(.notFound("That request was already answered.")))
            }
            session.answerPermission(allow: allow, note: allow ? nil : "Declined from the Octet phone app.")
            completion(.success(()))
        }
    }

    func terminal(of threadID: String) -> PhoneTerminalView? {
        guard let pane = Self.paneID(threadID), let client = onMainSync({ self.store?.client }) else { return nil }
        let now = Date()
        if let cached = lock.withLock({ paneText[pane] }), now.timeIntervalSince(cached.at) < 1 {
            return PhoneTerminalView(text: cached.text, cols: 100, rows: 30, running: true)
        }
        let read = (try? client.call("pane.read", ["pane_id": pane, "source": "recent", "lines": 200]))?["read"] as? [String: Any]
        guard let text = read?["text"] as? String else { return nil }
        lock.withLock { paneText[pane] = (text, now) }
        return PhoneTerminalView(text: text, cols: 100, rows: 30, running: true)
    }

    /// The session client, read once from the main actor.
    private func onMainSync<T>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
    }

    func type(_ data: String, into threadID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        guard let pane = Self.paneID(threadID) else { return completion(.failure(.failed("This conversation has no terminal."))) }
        type(data, paneID: pane, completion: completion)
    }

    private func type(_ data: String, paneID: String, completion: @escaping (Result<Void, PhoneHostError>) -> Void) {
        onMain { [weak self] in
            guard let client = self?.store?.client else { return completion(.failure(.failed("Octet has no session open."))) }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try client.call("pane.send_text", ["pane_id": paneID, "text": data])
                    completion(.success(()))
                } catch {
                    completion(.failure(.failed("Couldn't type into the pane.")))
                }
            }
        }
    }
}
