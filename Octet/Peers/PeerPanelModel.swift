import AppKit
import SwiftUI

/// What the Peer window and Settings remember about other Macs between
/// openings: each Mac's agents as last read, with its version and how long
/// it took to answer, why the last request failed, and the tasks given from
/// here with their answers.
@MainActor
final class PeerPanelModel: ObservableObject {
    static let shared = PeerPanelModel()

    struct Task: Identifiable {
        let id: String
        let machine: String
        let summary: String
        var agent = "claude"
        var folder = ""
        var started = Date()
        var status: String
        var result: String?
    }

    @Published private(set) var agents: [String: [PeerProtocol.Agent]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// Each failure sorted by what to do about it, beside its message.
    @Published private(set) var issues: [String: PeerPresentation.Issue] = [:]
    /// The Octet version each Mac reported with its agents.
    @Published private(set) var versions: [String: String] = [:]
    /// How long each Mac took to list its agents, T3 Code's latency.
    @Published private(set) var latency: [String: TimeInterval] = [:]
    @Published private(set) var tasks: [Task] = []
    /// Macs a task is being handed to, waiting for an answer (someone there
    /// may have to allow it first).
    @Published private(set) var starting: Set<String> = []
    /// Why the last task given to a Mac didn't start.
    @Published private(set) var taskErrors: [String: String] = [:]
    /// What the menu asked the window to show: a Mac to open, and whether
    /// to start a task there.
    @Published var focusMachine: String?
    @Published var startTaskOn: String?

    /// Reads which agents run on `machine`.
    func loadAgents(_ machine: String) {
        #if DEBUG
        if PeerSamples.active { return }
        #endif
        loading.insert(machine)
        let asked = Date()
        PeerCenter.shared.request(.agents, ["machine": machine]) { [weak self] answer in
            guard let self else { return }
            self.loading.remove(machine)
            if let error = answer["error"] as? String {
                self.fail(machine, error, code: answer["code"] as? String)
                return
            }
            self.errors[machine] = nil
            self.issues[machine] = nil
            self.latency[machine] = Date().timeIntervalSince(asked)
            let result = answer["result"] as? [String: Any] ?? [:]
            self.versions[machine] = result["version"] as? String
            self.agents[machine] = (result["agents"] as? [[String: Any]] ?? []).compactMap(PeerProtocol.Agent.init)
        }
    }

    private func fail(_ machine: String, _ error: String, code: String?) {
        errors[machine] = error
        issues[machine] = PeerPresentation.Issue(code: code, message: error)
    }

    func send(_ text: String, to agent: PeerProtocol.Agent, on machine: String) {
        PeerCenter.shared.request(.send, ["machine": machine, "agent": agent.id, "text": text]) { answer in
            if let error = answer["error"] as? String {
                let issue = PeerPresentation.Issue(code: answer["code"] as? String, message: error)
                ToastCenter.shared.fail(nil, "Couldn't message \(agent.name) on \(machine)", detail: issue.advice(machine: machine))
            } else {
                ToastCenter.shared.info("Sent to \(agent.name) on \(machine)")
            }
        }
    }

    func read(_ agent: PeerProtocol.Agent, on machine: String, lines: Int = 120, done: @escaping (String) -> Void) {
        PeerCenter.shared.request(.read, ["machine": machine, "agent": agent.id, "lines": lines]) { answer in
            if let error = answer["error"] as? String { return done("Couldn't read it: \(error)") }
            let text = (answer["result"] as? [String: Any])?["text"] as? String ?? ""
            done(text.isEmpty ? "Nothing on screen yet." : text)
        }
    }

    /// Starts an agent on `machine` with `task`, then waits for its answer.
    /// `done` hears whether it started, so the form can stay open on a no.
    func delegate(_ task: String, agent: String, folder: String, on machine: String, done: ((Bool) -> Void)? = nil) {
        starting.insert(machine)
        taskErrors[machine] = nil
        PeerCenter.shared.request(.delegate, ["machine": machine, "agent_type": agent, "folder": folder, "task": task]) { [weak self] answer in
            guard let self else { return }
            self.starting.remove(machine)
            if let error = answer["error"] as? String {
                let issue = PeerPresentation.Issue(code: answer["code"] as? String, message: error)
                self.taskErrors[machine] = issue.advice(machine: machine)
                done?(false)
                return
            }
            guard let id = (answer["result"] as? [String: Any])?["task"] as? String else { done?(false); return }
            MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) {
                self.tasks.insert(Task(id: id, machine: machine, summary: task, agent: agent, folder: folder, status: "working"), at: 0)
            }
            done?(true)
            self.wait(for: id)
        }
    }

    private func wait(for id: String) {
        PeerCenter.shared.request(.wait, ["task": id, "timeout_seconds": 3600]) { [weak self] answer in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            let result = answer["result"] as? [String: Any] ?? [:]
            MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) {
                self.tasks[index].status = result["status"] as? String ?? self.tasks[index].status
                self.tasks[index].result = result["result"] as? String ?? (answer["error"] as? String)
            }
            if result["note"] != nil { self.wait(for: id) }  // Still going: keep waiting.
        }
    }

    func clearTaskError(_ machine: String) { taskErrors[machine] = nil }

    func clearFinished() {
        MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) {
            tasks.removeAll { $0.status != "working" }
        }
    }

    #if DEBUG
    /// Sample agents, failures and tasks for the verification hooks.
    func showSample(agents: [String: [PeerProtocol.Agent]], versions: [String: String], latency: [String: TimeInterval],
                    issues: [String: PeerPresentation.Issue], tasks: [Task]) {
        self.agents = agents
        self.versions = versions
        self.latency = latency
        self.issues = issues
        self.errors = issues.mapValues { $0.title }
        self.tasks = tasks
    }
    #endif
}
