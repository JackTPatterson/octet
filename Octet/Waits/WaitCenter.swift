import AppKit
import Foundation

/// Keeps the waits: what work is set aside until something outside it
/// happens, and the step to take then. Checks each condition itself on a
/// schedule that slows as the wait grows old (no agent runs meanwhile),
/// catches up on launch, and when one is met says so (a notice, the Dock
/// badge, the sidebar's Ready list) and carries the work on: in the
/// conversation that set it if that's still open, resumed from the agent's
/// own session if not, else in a new conversation from the summary written
/// down when the wait was set. Agents set waits over a socket (`waits.sock`).
@MainActor
final class WaitCenter: ObservableObject {
    static let shared = WaitCenter()

    @Published private(set) var waits: [Wait] = []
    /// The wait being written in the sheet.
    @Published var draft: WaitDraft?

    private weak var store: SessionStore?
    private var server: PermissionSocketServer?
    private var timer: Timer?
    private var checking: Set<String> = []
    private var loaded = false

    private var url: URL { EngineSession.supportDirectory.appendingPathComponent("waits.json") }

    /// Met, with a step to take, newest first.
    var ready: [Wait] {
        waits.filter { $0.state == .ready && !$0.isSnooze }.sorted { ($0.readyAt ?? .distantPast) > ($1.readyAt ?? .distantPast) }
    }

    /// Still waiting, oldest first; workspaces snoozed until something are
    /// shown with the Idle dock instead.
    var waiting: [Wait] {
        waits.filter { $0.state == .waiting && !$0.isSnooze }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The snooze, if any, holding a workspace in Idle.
    func snooze(of workspaceId: String) -> Wait? {
        waits.first { $0.isSnooze && $0.state == .waiting && $0.origin.workspaceId == workspaceId }
    }

    // MARK: - Lifecycle

    func start(store: SessionStore) {
        self.store = store
        if !loaded {
            loaded = true
            waits = Self.load(from: url)
        }
        applyServer()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { WaitCenter.shared.tick() }
        }
        // Catch up on what happened while Octet was closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
        updateBadge()
    }

    private static func load(from url: URL) -> [Wait] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Wait].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(waits) else { return }
        try? FileManager.default.createDirectory(at: EngineSession.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        updateBadge()
    }

    /// The Dock shows how many are ready, so they're seen with Octet behind other apps.
    private func updateBadge() {
        let count = ready.count
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - Keeping the list

    func add(_ wait: Wait) {
        waits.append(wait)
        save()
        tick()
    }

    func update(_ wait: Wait) {
        guard let index = waits.firstIndex(where: { $0.id == wait.id }) else { return add(wait) }
        waits[index] = wait
        save()
    }

    func remove(_ id: String) {
        waits.removeAll { $0.id == id }
        save()
    }

    /// "Still waiting".
    func confirm(_ id: String) {
        mutate(id) { $0.confirm() }
    }

    /// The person says it's happened.
    func markReady(_ id: String) {
        mutate(id) { $0.markReady() }
        if let wait = waits.first(where: { $0.id == id }) { becameReady(wait) }
    }

    private func mutate(_ id: String, _ change: (inout Wait) -> Void) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        change(&waits[index])
        save()
    }

    // MARK: - Checking

    /// Checks every wait that's due.
    func tick() {
        let now = Date()
        for wait in waits where wait.isDue(now: now) && !checking.contains(wait.id) {
            check(wait)
        }
    }

    func checkNow(_ id: String) {
        guard let wait = waits.first(where: { $0.id == id }), wait.state == .waiting, !checking.contains(id) else { return }
        if wait.isManual { return markReady(id) }
        check(wait)
    }

    private func check(_ wait: Wait) {
        checking.insert(wait.id)
        objectWillChange.send()
        DispatchQueue.global(qos: .utility).async {
            let outcome = WaitChecker.evaluate(wait)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WaitCenter.shared.finishCheck(wait.id, outcome) }
            }
        }
    }

    func isChecking(_ id: String) -> Bool { checking.contains(id) }

    private func finishCheck(_ id: String, _ outcome: (check: WaitCheck, baseline: String?)) {
        checking.remove(id)
        guard let index = waits.firstIndex(where: { $0.id == id }), waits[index].state == .waiting else {
            objectWillChange.send()
            return
        }
        waits[index].record(outcome.check, baseline: outcome.baseline)
        let wait = waits[index]
        save()
        if wait.state == .ready { becameReady(wait) }
    }

    // MARK: - When one is met

    private func becameReady(_ wait: Wait) {
        if wait.isSnooze {
            // Only brings the workspace back.
            remove(wait.id)
            guard let store, let workspaceId = wait.origin.workspaceId,
                  store.snapshot.workspaces.contains(where: { $0.workspaceId == workspaceId }) else { return }
            store.keepInView(workspaceId)
            ToastCenter.shared.info("\(wait.origin.workspaceLabel ?? "A workspace") is back from Idle",
                                    detail: wait.lastResult.map { "\(wait.title): \($0)" } ?? wait.title, after: 12,
                                    action: .init(title: "Show") { WindowRegistry.shared.key?.focusWorkspace(workspaceId) })
            return
        }
        if wait.autoContinue {
            continueWait(wait.id)
            return
        }
        ToastCenter.shared.info("Ready: \(wait.title)", detail: "Next: " + HandoffBrief.clip(wait.next, 140),
                                after: NSApp.isActive ? 15 : 60,
                                action: .init(title: "Continue") { WaitCenter.shared.continueWait(wait.id) })
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        if SettingsStore.shared.values.agentSounds { NSSound(named: "Glass")?.play() }
    }

    /// The message the agent gets when the work comes back.
    static func message(for wait: Wait) -> String {
        let what = wait.lastResult.map { "\(wait.title) (\($0))" } ?? wait.title
        return "The wait is over: \(what).\n\n\(wait.next)"
    }

    /// Carries the work on where it was, and takes the wait off the list.
    func continueWait(_ id: String, in window: WindowContext? = nil) {
        guard let wait = waits.first(where: { $0.id == id }), let store else { return }
        let window = window ?? WindowRegistry.shared.key
        let text = Self.message(for: wait)
        remove(id)

        // The conversation that set it, still open.
        if let conversationId = wait.origin.conversationId,
           let session = AgentCenter.shared.sessions.first(where: { $0.id == conversationId }) {
            show(session.workspaceId, in: window)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
            session.send(text)
            return done(wait, "in the same conversation")
        }

        // The agent still running in a terminal, waiting at its prompt.
        if let sessionId = wait.origin.sessionId,
           let agent = store.snapshot.agents.first(where: { agent in
               agent.sessionReference == sessionId || agent.terminalId.flatMap(store.recovery.sessionId(forTerminal:)) == sessionId
           }),
           agent.agentStatus == .idle || agent.agentStatus == .done {
            let client = store.client
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? client.call("pane.send_text", ["pane_id": agent.paneId, "text": line])
                Thread.sleep(forTimeInterval: 0.15)
                _ = try? client.call("pane.send_text", ["pane_id": agent.paneId, "text": "\r"])
            }
            if let workspaceId = agent.workspaceId { show(workspaceId, in: window) }
            window?.focusAgent(paneId: agent.paneId)
            return done(wait, "in the same terminal")
        }

        // Somewhere to carry it on: its workspace, one on the same folder,
        // or a new one there.
        let snapshot = store.snapshot
        let workspaceId = wait.origin.workspaceId.flatMap { id in snapshot.workspaces.contains { $0.workspaceId == id } ? id : nil }
            ?? snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == wait.origin.cwd }?.workspaceId
        if let workspaceId {
            carryOn(wait, text: text, workspaceId: workspaceId, window: window)
        } else {
            let label = wait.origin.workspaceLabel ?? URL(fileURLWithPath: wait.origin.cwd).lastPathComponent
            store.call("workspace.create", ["cwd": wait.origin.cwd, "label": label, "focus": false],
                       failure: "Couldn't open \(label)") { [weak self] created in
                guard let newWorkspace = created.workspaceId else { return }
                self?.carryOn(wait, text: text, workspaceId: newWorkspace, window: window)
            }
        }
    }

    /// Resumes the agent's own session as a conversation here, or starts a
    /// new one with the summary.
    private func carryOn(_ wait: Wait, text: String, workspaceId: String, window: WindowContext?) {
        show(workspaceId, in: window)
        let engine = wait.origin.agent.flatMap(AgentSession.Engine.init(rawValue:))
        if let engine, let sessionId = wait.origin.sessionId {
            let session = AgentCenter.shared.resume(engine: engine, sessionId: sessionId, cwd: wait.origin.cwd,
                                                    workspaceId: workspaceId, title: wait.title, start: false)
            session.send(text)
            return done(wait, "resumed")
        }
        let session = AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: wait.origin.cwd, engine: engine ?? .claude)
        session.title = String(wait.title.prefix(60))
        let opening = wait.brief ?? "Carrying on work in \(HandoffBrief.abbreviate(wait.origin.cwd))"
            + (wait.origin.branch.map { " on \($0)" } ?? "") + ". Look at `git status` and `git log` for where it stands."
        session.send(opening + "\n\n" + text)
        done(wait, "in a new conversation")
    }

    private func show(_ workspaceId: String, in window: WindowContext?) {
        store?.keepInView(workspaceId)
        (WindowRegistry.shared.window(showing: workspaceId) ?? window)?.focusWorkspace(workspaceId)
    }

    private func done(_ wait: Wait, _ how: String) {
        ToastCenter.shared.info("Continued \(how)", detail: wait.title)
    }

    // MARK: - Snoozing a workspace

    /// Moves a workspace to Idle until `condition` happens, then brings it back.
    func snooze(workspaceId: String, until condition: WaitCondition, title: String = "") {
        guard let store, let workspace = store.snapshot.workspaces.first(where: { $0.workspaceId == workspaceId }) else { return }
        if let existing = snooze(of: workspaceId) { waits.removeAll { $0.id == existing.id } }
        let origin = Wait.Origin(cwd: store.snapshot.directory(ofWorkspace: workspaceId) ?? NSHomeDirectory(),
                                 branch: store.branches[workspaceId], workspaceId: workspaceId, workspaceLabel: workspace.label)
        add(Wait(title: title, condition: condition, next: "", origin: origin))
        store.markIdle(workspaceId)
        ToastCenter.shared.info("\(workspace.label) is in Idle until \(title.isEmpty ? condition.description : title)")
    }

    func cancelSnooze(of workspaceId: String) {
        guard let wait = snooze(of: workspaceId) else { return }
        remove(wait.id)
    }

    // MARK: - Writing one

    /// Opens the sheet for a new wait on a workspace, or on a conversation.
    func compose(workspaceId: String?, session: AgentSession? = nil, prefill: WaitSuggestion.Found? = nil, snooze: Bool = false) {
        guard let store else { return }
        let id = session?.workspaceId ?? workspaceId
        let cwd = session?.cwd ?? id.flatMap { store.snapshot.directory(ofWorkspace: $0) } ?? NSHomeDirectory()
        var draft = WaitDraft(origin: origin(workspaceId: id, session: session, cwd: cwd),
                              windowId: WindowRegistry.shared.key?.id)
        draft.snooze = snooze && id != nil
        if let prefill {
            draft.title = prefill.waitingFor
            draft.next = prefill.next
            if let condition = prefill.condition { draft.load(condition) } else { draft.kind = .manual; draft.target = prefill.waitingFor }
        }
        self.draft = draft
        if prefill == nil { offerPullRequest(of: cwd, draft: draft.id) }
    }

    /// Fills in the branch's pull request, when it has one, as the likeliest
    /// thing to wait on.
    private func offerPullRequest(of cwd: String, draft id: UUID) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "pr", "view", "--json", "url,state"], in: cwd)
            let json = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            guard result.status == 0, json?["state"] as? String == "OPEN", let url = json?["url"] as? String,
                  let condition = WaitCondition.pullRequest(in: url) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = WaitCenter.shared
                    guard var draft = center.draft, draft.id == id, draft.isUntouched else { return }
                    draft.load(condition)
                    center.draft = draft
                }
            }
        }
    }

    /// Where a wait set now would come back to.
    func origin(workspaceId: String?, session: AgentSession?, cwd: String) -> Wait.Origin {
        let workspace = workspaceId.flatMap { id in store?.snapshot.workspaces.first { $0.workspaceId == id } }
        var origin = Wait.Origin(cwd: cwd, branch: workspaceId.flatMap { store?.branches[$0] },
                                 workspaceId: workspaceId, workspaceLabel: workspace?.label)
        if let session {
            origin.agent = session.engine.rawValue
            origin.sessionId = session.engine == .claude ? session.sessionId : session.threadId
            origin.conversationId = session.id
        } else if let workspaceId, let store,
                  let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspaceId)) {
            origin.agent = AgentBrand.forAgent(agent.agent)?.id ?? agent.agent
            origin.sessionId = agent.sessionReference ?? agent.terminalId.flatMap(store.recovery.sessionId(forTerminal:))
        }
        return origin
    }

    /// The summary a new conversation would start from, for a conversation of Octet's own.
    static func brief(for session: AgentSession?, branch: String?, waitingFor: String) -> String? {
        guard let session, session.conversation.items.contains(where: { if case .user = $0.kind { return true } else { return false } })
        else { return nil }
        return HandoffBrief.build(.init(agentName: session.engine.displayName, cwd: session.cwd, branch: branch,
                                        items: session.conversation.items, reason: .waited(on: waitingFor)))
    }

    /// The same, read from Claude Code's own log, for a conversation in a terminal.
    static func brief(origin: Wait.Origin, waitingFor: String) -> String? {
        guard origin.agent == "claude", let sessionId = origin.sessionId,
              let path = AgentConversation.findLog(sessionIds: [sessionId], cwd: origin.cwd),
              let log = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let items = AgentConversation.replay(lines: log.components(separatedBy: "\n")).items
        guard !items.isEmpty else { return nil }
        return HandoffBrief.build(.init(agentName: "Claude Code", cwd: origin.cwd, branch: origin.branch,
                                        items: items, reason: .waited(on: waitingFor)))
    }

    // MARK: - Agents

    func applyServer() {
        let enabled = SettingsStore.shared.values.agentsSetWaits
        if enabled, server == nil {
            try? FileManager.default.createDirectory(at: EngineSession.supportDirectory, withIntermediateDirectories: true)
            let server = PermissionSocketServer(path: EngineSession.supportDirectory.appendingPathComponent(WaitControl.socketName).path)
            do {
                try server.start { request, reply in
                    MainActor.assumeIsolated { WaitCenter.shared.handle(request, reply: reply) }
                }
                self.server = server
            } catch {
                ToastCenter.shared.fail(nil, "Agents can't set waits", detail: "\(error)")
            }
        } else if !enabled, let server {
            server.stop()
            self.server = nil
        }
    }

    private func handle(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard SettingsStore.shared.values.agentsSetWaits else {
            return reply(["error": "Letting agents set waits is off (Octet Settings › Agents)."])
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch (request["method"] as? String).flatMap(WaitControl.Method.init(rawValue:)) {
        case .add:
            guard let until = params["until"] as? String, let condition = WaitCondition.parse(until),
                  let next = params["then"] as? String, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reply(["error": "Give both what to wait for and the next step."])
            }
            let origin = agentOrigin(params)
            let session = origin.conversationId.flatMap { id in AgentCenter.shared.sessions.first { $0.id == id } }
            let title = (params["title"] as? String) ?? ""
            let agentName = origin.agent.flatMap { AgentBrand.forAgent($0)?.displayName } ?? origin.agent ?? "An agent"
            let waitingFor = title.isEmpty ? condition.description : title
            let wait = Wait(title: title, condition: condition, next: next, origin: origin, createdBy: agentName,
                            brief: Self.brief(for: session, branch: origin.branch, waitingFor: waitingFor)
                                ?? Self.brief(origin: origin, waitingFor: waitingFor))
            add(wait)
            ToastCenter.shared.info("\(agentName) set a wait", detail: "\(wait.title). Octet brings the work back when it happens.",
                                    after: 8)
            var result = WaitControl.describe(wait)
            result["checked_by_octet"] = !wait.isManual
            reply(["result": result])
        case .list:
            reply(["result": ["waits": waits.filter { !$0.isSnooze }.map { WaitControl.describe($0) }]])
        case .cancel:
            guard let id = params["id"] as? String, waits.contains(where: { $0.id == id }) else {
                return reply(["error": "There's no wait with that id."])
            }
            remove(id)
            reply(["result": [String: Any]()])
        case nil:
            reply(["error": "Unknown request."])
        }
    }

    /// Where an agent's request comes from: its conversation here, or the
    /// agent in its pane, else just the folder.
    private func agentOrigin(_ params: [String: Any]) -> Wait.Origin {
        let cwd = params["cwd"] as? String ?? NSHomeDirectory()
        if let id = params["conversation_id"] as? String,
           let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) {
            return origin(workspaceId: session.workspaceId, session: session, cwd: session.cwd)
        }
        guard let store else { return Wait.Origin(cwd: cwd) }
        let snapshot = store.snapshot
        if let pane = params["from_pane"] as? String,
           let paneInfo = snapshot.panes.first(where: { $0.paneId == pane }) {
            let workspace = snapshot.workspaces.first { $0.workspaceId == paneInfo.workspaceId }
            var origin = Wait.Origin(cwd: paneInfo.effectiveCwd ?? cwd, branch: store.branches[paneInfo.workspaceId],
                                     workspaceId: paneInfo.workspaceId, workspaceLabel: workspace?.label)
            if let agent = snapshot.agents.first(where: { $0.paneId == pane }) {
                origin.agent = AgentBrand.forAgent(agent.agent)?.id ?? agent.agent
                origin.sessionId = agent.sessionReference ?? agent.terminalId.flatMap(store.recovery.sessionId(forTerminal:))
                if let agentCwd = agent.cwd { origin.cwd = agentCwd }
            }
            return origin
        }
        let workspace = snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == cwd }
        return Wait.Origin(cwd: cwd, branch: workspace.flatMap { store.branches[$0.workspaceId] },
                           workspaceId: workspace?.workspaceId, workspaceLabel: workspace?.label)
    }
}

/// Reads a condition: the network, `gh`, the disk or a command. Runs off
/// the main thread; the deciding is `WaitEvaluation`'s.
enum WaitChecker {
    static func evaluate(_ wait: Wait, now: Date = Date()) -> (check: WaitCheck, baseline: String?) {
        let folder = FileManager.default.fileExists(atPath: wait.origin.cwd) ? wait.origin.cwd : NSHomeDirectory()
        switch wait.condition {
        case .pullRequest(let repo, let number, let event):
            let result = LoginShell.run(["gh", "pr", "view", String(number), "--repo", repo, "--json",
                                         "number,title,state,url,isDraft,reviewDecision,statusCheckRollup"], in: folder)
            guard result.status == 0, let pr = GitHubPullRequest.parse(Data(result.output.utf8)) else {
                return (.failed(failure(result.output, fallback: "Couldn't read it with gh")), nil)
            }
            return (WaitEvaluation.pullRequest(pr, event: event), nil)
        case .release(let repo, let tag):
            let result = LoginShell.run(["gh", "api", "repos/\(repo)/releases?per_page=30"], in: folder)
            guard result.status == 0, let tags = WaitEvaluation.releaseTags(Data(result.output.utf8)) else {
                return (.failed(failure(result.output, fallback: "Couldn't read its releases with gh")), nil)
            }
            return WaitEvaluation.release(tags: tags, wanted: tag, baseline: wait.baseline)
        case .package(let registry, let name, let version):
            let address = registry == .npm
                ? "https://registry.npmjs.org/" + (name.hasPrefix("@") ? name.replacingOccurrences(of: "/", with: "%2F") : name)
                : "https://pypi.org/pypi/\(name)/json"
            guard let url = URL(string: address) else { return (.failed("Not a package name"), nil) }
            let response = fetch(url)
            if response.status == 404 { return (version == nil ? .failed("No such package") : .notYet("Not published yet"), nil) }
            guard let body = response.body, response.status == 200,
                  let found = registry == .npm ? WaitEvaluation.npmVersions(body) : WaitEvaluation.pypiVersions(body) else {
                return (.failed("Couldn't reach \(registry.title)"), nil)
            }
            return WaitEvaluation.package(versions: found.versions, latest: found.latest, wanted: version, baseline: wait.baseline)
        case .url(let address, let page):
            guard let url = URL(string: address) else { return (.failed("Not a link"), nil) }
            let response = fetch(url)
            return WaitEvaluation.page(status: response.status, body: response.body, page: page, baseline: wait.baseline)
        case .file(let path):
            return (FileManager.default.fileExists(atPath: path) ? .met("It's there") : .notYet("Not there yet"), nil)
        case .command(let command):
            let status = run(command, in: folder)
            switch status {
            case 0?: return (.met("Succeeded"), nil)
            case nil: return (.failed("Took over a minute"), nil)
            case let code?: return (.notYet("Exits \(code)"), nil)
            }
        case .date(let date):
            return (now >= date ? .met("It's time") : .notYet("Not yet"), nil)
        case .manual:
            return (.notYet("Waiting on you to say"), nil)
        }
    }

    private static func failure(_ output: String, fallback: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? fallback : HandoffBrief.clip(line, 100)
    }

    private static func fetch(_ url: URL) -> (status: Int?, body: Data?) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Octet", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var result: (Int?, Data?) = (nil, nil)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode, data)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return result
    }

    /// The command's exit status, through the login shell so it has the
    /// person's PATH; nil when it ran past a minute and was stopped.
    private static func run(_ command: String, in folder: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return 127 }
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}
