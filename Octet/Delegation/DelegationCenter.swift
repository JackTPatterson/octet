import AppKit
import Foundation

/// Agent Delegation's app side: takes an agent's request from the socket,
/// asks the person when the setting says to, starts the delegate in a tab
/// of the caller's workspace, and hands its answer back when it's done.
/// Off until the Agent Delegation plugin is on.
@MainActor
final class DelegationCenter: ObservableObject {
    static let shared = DelegationCenter()

    /// Whether to ask before a delegation starts.
    enum Approval: String, CaseIterable, Identifiable {
        /// Ask every time.
        case ask
        /// Reviews (read-only) go ahead; tasks ask.
        case reviews
        /// Everything goes ahead.
        case all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask every time"
            case .reviews: "Reviews without asking"
            case .all: "Reviews and tasks without asking"
            }
        }
    }

    struct Delegation: Identifiable {
        let id: String
        let agent: String
        let mode: DelegationMode
        let caller: String
        let summary: String
        let folder: String
        /// Where a task works, when it's in a worktree.
        let worktree: String?
        let directory: String
        let started = Date()
        var paneId: String?
        var status = "running"
        var result: String?
        var waiters: [([String: Any]) -> Void] = []
    }

    @Published private(set) var delegations: [String: Delegation] = [:]
    private weak var store: SessionStore?
    private var server: PermissionSocketServer?
    private var timer: Timer?

    private var enabled: Bool { SettingsStore.shared.values.delegationEnabled }
    var approval: Approval { Approval(rawValue: SettingsStore.shared.values.delegationApproval) ?? .reviews }

    /// Starts or stops with the setting.
    func apply(store: SessionStore? = nil) {
        if let store { self.store = store }
        if enabled, server == nil { start() } else if !enabled, server != nil { stop() }
    }

    private var socketPath: String {
        EngineSession.supportDirectory.appendingPathComponent(DelegationControl.socketName).path
    }

    private func start() {
        try? FileManager.default.createDirectory(at: EngineSession.supportDirectory, withIntermediateDirectories: true)
        let server = PermissionSocketServer(path: socketPath)
        do {
            try server.start { [weak self] request, reply in
                MainActor.assumeIsolated { self?.handle(request, reply: reply) }
            }
            self.server = server
        } catch {
            ToastCenter.shared.fail(nil, "Agent Delegation couldn't start", detail: "\(error)")
        }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { DelegationCenter.shared.checkFinished() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        server?.stop()
        server = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Requests

    private func handle(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let params = request["params"] as? [String: Any] ?? [:]
        let fail: (String) -> Void = { reply(["error": $0]) }
        guard let store, let pane = params["from_pane"] as? String, fromThisSession(params, store: store) else {
            return fail("This only works from an Octet pane.")
        }
        guard (params["depth"] as? Int ?? 0) < DelegationControl.maxDepth else {
            return fail("A delegate can't delegate again.")
        }
        switch (request["method"] as? String).flatMap(DelegationControl.Method.init(rawValue:)) {
        case .agents:
            reply(["result": ["agents": available.map { ["id": $0.id, "name": $0.displayName] }]])
        case .delegate:
            delegate(params, from: pane, store: store, reply: reply)
        case .wait:
            wait(params, reply: reply)
        case nil:
            fail("Unknown request.")
        }
    }

    /// A request counts only from a pane of this Octet's session.
    private func fromThisSession(_ params: [String: Any], store: SessionStore) -> Bool {
        guard let pane = params["from_pane"] as? String, let session = params["from_session"] as? String else { return false }
        let mine = URL(fileURLWithPath: store.client.socketPath).resolvingSymlinksInPath().path
        let theirs = URL(fileURLWithPath: session).resolvingSymlinksInPath().path
        return mine == theirs && store.snapshot.panes.contains { $0.paneId == pane }
    }

    private var available: [DiscoveredAgent] {
        DelegationPlan.agents.compactMap { id in
            AgentDiscoveryStore.shared.agents.first { $0.id == id && $0.executablePath != nil }
        }
    }

    private func delegate(_ params: [String: Any], from pane: String, store: SessionStore,
                          reply: @escaping ([String: Any]) -> Void) {
        let fail: (String) -> Void = { reply(["error": $0]) }
        guard let kind = params["agent"] as? String, let task = params["task"] as? String, !task.isEmpty else {
            return fail("Say which agent, and what to check or do.")
        }
        let mode = DelegationMode(rawValue: params["mode"] as? String ?? "review") ?? .review
        guard let agent = available.first(where: { $0.id == kind }), let executable = agent.executablePath else {
            return fail("\(kind) isn't installed here. Available: \(available.map(\.id).joined(separator: ", ")).")
        }
        let snapshot = store.snapshot
        guard let callerPane = snapshot.panes.first(where: { $0.paneId == pane }) else { return fail("That pane is gone.") }
        let folder = callerPane.effectiveCwd ?? snapshot.directory(ofWorkspace: callerPane.workspaceId) ?? NSHomeDirectory()
        let callerAgent = snapshot.agents.first { $0.paneId == pane }?.agent
        let caller = AgentBrand.forAgent(callerAgent)?.displayName ?? "An agent"
        startAfterApproval(agent: agent, executable: executable, mode: mode, task: task, caller: caller,
                           folder: folder, workspace: callerPane.workspaceId, store: store, reply: reply)
    }

    private func startAfterApproval(agent: DiscoveredAgent, executable: String, mode: DelegationMode, task: String,
                                    caller: String, folder: String, workspace: String, store: SessionStore,
                                    reply: @escaping ([String: Any]) -> Void) {
        let go = { self.start(agent: agent, executable: executable, mode: mode, task: task, caller: caller,
                              folder: folder, workspace: workspace, store: store, reply: reply) }
        let needsAsking = approval == .ask || (approval == .reviews && mode == .task)
        guard needsAsking else { return go() }
        let what = mode == .review ? "review its changes" : "work on a task in a separate worktree"
        var answered = false
        ConfirmCenter.shared.ask(ConfirmCenter.Request(
            title: "\(caller) wants \(agent.displayName) to \(what)",
            message: "In \((folder as NSString).abbreviatingWithTildeInPath). It runs in a new tab, and the answer goes back to \(caller).",
            detail: task, confirmTitle: mode == .review ? "Review" : "Start",
            onConfirm: { _ in
                guard !answered else { return }
                answered = true
                go()
            },
            onCancel: {
                guard !answered else { return }
                answered = true
                reply(["error": "The person didn't allow it."])
            }))
        // Left unanswered: the agent hears so rather than hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            guard !answered else { return }
            answered = true
            reply(["error": "Nobody answered the request to allow it."])
        }
    }

    private func start(agent: DiscoveredAgent, executable: String, mode: DelegationMode, task: String, caller: String,
                       folder: String, workspace: String, store: SessionStore, reply: @escaping ([String: Any]) -> Void) {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let directory = EngineSession.supportDirectory.appendingPathComponent("delegation/\(id)").path
        let promptFile = directory + "/prompt.md", resultFile = directory + "/result.md", doneFile = directory + "/done"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try DelegationPlan.prompt(task: task, mode: mode, caller: caller).write(toFile: promptFile, atomically: true, encoding: .utf8)
        } catch {
            return reply(["error": "Couldn't prepare the delegation: \(error.localizedDescription)"])
        }
        guard let command = DelegationPlan.command(agent: agent.id, executable: executable, mode: mode,
                                                   promptFile: promptFile, resultFile: resultFile, doneFile: doneFile) else {
            return reply(["error": "\(agent.displayName) can't take delegations."])
        }
        let label = "\(agent.displayName) · \(mode == .review ? "review" : "task") for \(caller)"
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            // A task works in a worktree of the tree as it is now, so its
            // edits can't collide with the caller's.
            var cwd = folder
            var worktree: String?
            if mode == .task, let top = Git().topLevel(folder),
               let base = Checkpoints.create(in: folder, label: "Octet: delegation \(id)", force: true)?.commit {
                let path = (top as NSString).deletingLastPathComponent + "/" + (top as NSString).lastPathComponent + "-delegate-\(id)"
                if (try? Git().run(["worktree", "add", "--detach", path, base], in: top)) != nil {
                    worktree = path
                    let relative = folder.hasPrefix(top) ? String(folder.dropFirst(top.count)) : ""
                    cwd = path + relative
                }
            }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let params: [String: Any] = [
                "tab_label": label, "focus": false, "workspace_id": workspace,
                "root": ["type": "pane", "label": label, "cwd": cwd,
                         "command": [shell, "-lic", "\(command); exec \(shell) -l"]] as [String: Any],
            ]
            let result = try? client.call("layout.apply", params)
            let pane = PeerProtocol.paneId(inLayoutResult: result)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var delegation = Delegation(id: id, agent: agent.displayName, mode: mode, caller: caller,
                                                summary: String(task.prefix(120)), folder: folder, worktree: worktree,
                                                directory: directory)
                    delegation.paneId = pane
                    self.delegations[id] = delegation
                    reply(["result": ["task": id, "agent": agent.displayName, "mode": mode.rawValue, "status": "running"]
                        .merging(worktree.map { ["worktree": $0] } ?? [:]) { $1 }])
                }
            }
        }
    }

    // MARK: - Finishing

    private func wait(_ params: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let id = params["task"] as? String, var delegation = delegations[id] else {
            return reply(["error": "No delegation \(params["task"] ?? "") was started here."])
        }
        if delegation.result != nil { return reply(["result": answer(delegation)]) }
        let timeout = min(3600, max(1, params["timeout_seconds"] as? Int ?? 900))
        var answered = false
        delegation.waiters.append { answer in
            guard !answered else { return }
            answered = true
            reply(["result": answer])
        }
        delegations[id] = delegation
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) {
            guard !answered else { return }
            answered = true
            let current = self.delegations[id] ?? delegation
            reply(["result": self.answer(current).merging(["note": "Still running after \(timeout) s; wait again with wait_for_delegate."]) { $1 }])
        }
    }

    /// Finishes delegations whose command has exited.
    private func checkFinished() {
        for (id, delegation) in delegations where delegation.result == nil {
            let done = delegation.directory + "/done"
            guard FileManager.default.fileExists(atPath: done) else { continue }
            let status = (try? String(contentsOfFile: done, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            var finished = delegation
            finished.result = (try? String(contentsOfFile: delegation.directory + "/result.md", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            finished.status = status == "0" ? "done" : "failed (exit \(status ?? "?"))"
            let waiters = finished.waiters
            finished.waiters = []
            delegations[id] = finished
            let answer = answer(finished)
            waiters.forEach { $0(answer) }
            let verdict = finished.mode == .review ? DelegationVerdict.read(finished.result ?? "") : nil
            let headline = verdict.map { $0.outcome == .pass ? "passed" : $0.outcome == .fail ? "found \($0.findings.count) problem\($0.findings.count == 1 ? "" : "s")" : "is done" } ?? "is done"
            ToastCenter.shared.info("\(finished.agent)'s \(finished.mode == .review ? "review" : "task") \(headline)",
                                    detail: "For \(finished.caller): \(finished.summary)")
        }
    }

    private func answer(_ delegation: Delegation) -> [String: Any] {
        var answer: [String: Any] = ["task": delegation.id, "agent": delegation.agent, "mode": delegation.mode.rawValue,
                                     "status": delegation.status]
        if let result = delegation.result {
            answer["result"] = result.isEmpty ? "(\(delegation.agent) gave no answer; its tab shows what happened.)" : result
            if delegation.mode == .review {
                let verdict = DelegationVerdict.read(result)
                answer["verdict"] = verdict.outcome.rawValue
                answer["problems"] = verdict.findings.count
            }
        }
        if let worktree = delegation.worktree {
            answer["worktree"] = worktree
            answer["note"] = "Its changes are in that worktree; look with git -C \(worktree) diff, and remove it with git worktree remove when done."
        }
        return answer
    }

    // MARK: - Agents' configuration

    /// Adds, or removes, the tools in the installed agents' MCP settings.
    func configureAgents(install: Bool) {
        let installed = AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id)
        let commands: [String]
        if install {
            guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else {
                return ToastCenter.shared.fail(nil, "octet-cli is missing from the app bundle")
            }
            commands = DelegationMCP.installCommands(cliPath: cli, agents: installed)
        } else {
            commands = DelegationMCP.removeCommands(agents: installed)
        }
        guard !commands.isEmpty else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for command in commands {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-lc", command]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try? process.run()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                // Already added, or already gone, counts as done.
                let lowered = text.lowercased()
                if process.terminationStatus != 0, !lowered.contains("already"), !lowered.contains("not found"), !lowered.contains("no mcp server") {
                    failures.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            DispatchQueue.main.async {
                if !failures.isEmpty {
                    ToastCenter.shared.fail(nil, install ? "Couldn't add the delegation tools everywhere" : "Couldn't remove the delegation tools everywhere",
                                            detail: failures.joined(separator: "\n"))
                } else if install {
                    ToastCenter.shared.info("Agents can now ask each other", detail: "New agent sessions pick up the delegation tools.")
                }
            }
        }
    }
}
