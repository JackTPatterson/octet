import Foundation
import Combine

@MainActor
final class ProjectJobCenter: ObservableObject {
    static let shared = ProjectJobCenter()
    @Published private(set) var jobs: [ProjectJob] = []
    @Published private(set) var runs: [ProjectJobRun] = []
    @Published var failure: String?
    private weak var store: SessionStore?
    private var loaded = false
    private var ticking = false
    private let file: URL
    private let allowed: @MainActor () -> Bool
    private let connectionReady: (() -> Bool)?
    private let executeOverride: ((ProjectJob, UUID) -> Void)?
    init(file: URL = EngineSession.supportDirectory.appendingPathComponent("project-jobs.json"),
         allowed: @escaping @MainActor () -> Bool = { AgentConfigWrites.allowedHere && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil },
         connectionReady: (() -> Bool)? = nil,
         execute: ((ProjectJob, UUID) -> Void)? = nil) {
        self.file = file; self.allowed = allowed; self.connectionReady = connectionReady; self.executeOverride = execute
    }
    private struct Saved: Codable { var jobs: [ProjectJob]; var runs: [ProjectJobRun] }

    func start(store: SessionStore) {
        self.store = store
        guard !loaded, allowed() else { return }
        loaded = true
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                jobs = saved.jobs; runs = saved.runs
                for i in runs.indices where runs[i].active && runs[i].status != .running {
                    runs[i].status = .interrupted
                    runs[i].detail = "App closed during launch. Inspect workspace before running again."
                    if let j = jobs.firstIndex(where: { $0.id == runs[i].jobId }) { jobs[j].enabled = false }
                }
                try save()
            }
        } catch { failure = "Couldn't load scheduled jobs: " + error.localizedDescription }
    }
    private func save() throws {
        // Never discard active history when retaining recent completed runs.
        let retained = runs.filter(\.active) + runs.filter { !$0.active }.suffix(200)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Saved(jobs: jobs, runs: retained)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func upsert(_ job: ProjectJob) throws {
        try job.validate()
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
        try save()
    }
    func remove(_ id: UUID) {
        guard !runs.contains(where: { $0.jobId == id && $0.active }) else { failure = "Finish or acknowledge the active run before deleting its schedule."; return }
        jobs.removeAll { $0.id == id }
        persist()
    }
    func toggle(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].enabled.toggle(); persist()
    }
    private func persist() { do { try save() } catch { failure = error.localizedDescription } }
    private func update(_ id: UUID, _ change: (inout ProjectJobRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i]); persist()
    }
    /// Explicit acknowledgement only; never pretends an unknown agent finished.
    func acknowledge(_ id: UUID) {
        if let run = runs.first(where: { $0.id == id }), let i = jobs.firstIndex(where: { $0.id == run.jobId }) { jobs[i].enabled = false }
        update(id) { $0.status = .interrupted; $0.detail = "Tracking ended by user. The agent may still be running." }
    }
    func tick(now: Date = Date()) {
        guard loaded, !ticking, let store, connectionReady?() ?? store.isConnected else { return }
        observe(store.snapshot)
        guard !SettingsStore.shared.values.checkInsPaused else { return }
        ticking = true
        Task {
            defer { ticking = false }
            for job in jobs where job.enabled && job.nextRun <= now {
                do {
                    let next = try await Task.detached { try job.next(after: now) }.value
                    guard let i = jobs.firstIndex(where: { $0.id == job.id }), jobs[i].enabled, jobs[i] == job else { continue }
                    jobs[i].nextRun = next
                    try save() // Claim the occurrence durably before any external effect.
                    run(job.id)
                } catch { failure = error.localizedDescription }
            }
        }
    }
    private func observe(_ snapshot: EngineSnapshot) {
        for run in runs where run.status == .running {
            guard let pane = run.paneId else { continue }
            if let agent = snapshot.agents.first(where: { $0.paneId == pane }) {
                if agent.agentStatus == .working && !run.observedWorking { update(run.id) { $0.observedWorking = true } }
                if agent.agentStatus == .done || (run.observedWorking && agent.agentStatus == .idle) {
                    update(run.id) { $0.status = .completed; $0.detail = "Agent finished its turn." }
                }
            } else if Date().timeIntervalSince(run.started) > 120 {
                update(run.id) { $0.status = .interrupted; $0.detail = "Agent no longer observable; completion was not confirmed." }
                if let i = jobs.firstIndex(where: { $0.id == run.jobId }) { jobs[i].enabled = false; persist() }
            }
        }
    }
    func run(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), let store else { return }
        guard !runs.contains(where: { $0.jobId == id && $0.active }) else { failure = "This job already has an active run."; return }
        let run = ProjectJobRun(jobId: id)
        runs.append(run)
        do { try save() } catch { runs.removeAll { $0.id == run.id }; failure = error.localizedDescription; return }
        if let executeOverride { executeOverride(job, run.id); return }
        Task {
            do {
                try job.validate()
                guard let agent = AgentDiscoveryStore.shared.agents.first(where: { $0.id == job.provider && $0.executablePath != nil }) else { throw JobError("Selected agent is not installed.") }
                if !job.precheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var config = ProjectConfiguration()
                    config.archive = job.precheck; config.archiveTimeoutSeconds = job.precheckTimeout
                    do { try await ArchiveHook.run(config, checkout: job.root, root: job.root, label: "Precheck") }
                    catch { update(run.id) { $0.status = .skipped; $0.detail = "Precheck did not pass: " + error.localizedDescription }; return }
                }
                guard runs.contains(where: { $0.id == run.id && $0.active }) else { return }
                let result: [String: Any]
                if job.freshWorktree {
                    result = try await rpc("worktree.create", ["branch": "scheduled/" + String(job.id.uuidString.prefix(8)).lowercased() + "-" + String(run.id.uuidString.prefix(8)).lowercased(), "cwd": job.root, "focus": false], store: store)
                } else {
                    guard let workspace = store.snapshot.workspaces.first(where: { store.snapshot.directory(ofWorkspace: $0.workspaceId) == job.root }) else { throw JobError("Open the project's workspace before running an existing-workspace job.") }
                    result = ["workspace": ["workspace_id": workspace.workspaceId]]
                }
                guard let workspace = EngineCreated(result: result).workspaceId else { throw JobError("Engine returned no workspace.") }
                let checkout = WorktreeSetup.parse(result)?.checkoutPath ?? job.root
                update(run.id) { $0.workspaceId = workspace; $0.checkout = checkout; $0.status = .setup; $0.detail = "Waiting for setup; use the workspace setup control to retry failures." }
                let launch = { [weak self, weak store] in
                    guard let self, let store, self.runs.contains(where: { $0.id == run.id && $0.active }) else { return }
                    Task {
                        do {
                            guard var params = store.agentTabParams(agent, workspaceId: workspace, arguments: [job.prompt], label: "Scheduled · " + job.name) else { throw JobError("Couldn't prepare agent launch.") }
                            // The new workspace may not yet be in the UI snapshot.
                            if var root = params["root"] as? [String: Any] { root["cwd"] = checkout; params["root"] = root }
                            let created = try await self.rpc("layout.apply", params, store: store)
                            let pane = EngineCreated(result: created).paneId
                            self.update(run.id) { $0.status = .running; $0.paneId = pane; $0.detail = pane == nil ? "Launched; automatic completion tracking unavailable. Acknowledge when finished." : "Agent launched." }
                            store.scheduleRefresh()
                        } catch { self.update(run.id) { $0.status = .failed; $0.detail = error.localizedDescription } }
                    }
                }
                if job.freshWorktree { WorktreeSetupRunner.shared.run(after: result, store: store, whenReady: launch) }
                else { launch() }
            } catch { update(run.id) { $0.status = .failed; $0.detail = error.localizedDescription } }
        }
    }
    private func rpc(_ method: String, _ params: [String: Any], store: SessionStore) async throws -> [String: Any] {
        let client = store.client
        return try await Task.detached { try client.call(method, params) }.value
    }
}
