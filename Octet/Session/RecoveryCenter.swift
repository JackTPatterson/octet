import Foundation

/// What the recovery panel shows and does. The two controllers notice what
/// a crash or restart took (agent sessions, busy terminals) and know how to
/// bring each back; this holds the list in between: which rows are chosen,
/// how each one stands, and what was set aside to reopen from the palette.
@MainActor
final class RecoveryCenter: ObservableObject {
    enum Mode: Equatable {
        /// Lost to a crash, restart or shutdown.
        case lost
        /// Opened by hand: recent agent sessions that aren't running.
        case history
        /// The debug preview: sample rows, nothing runs.
        case preview
    }

    @Published private(set) var items: [RecoveryItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var mode: Mode = .lost
    @Published private(set) var isPresented = false
    /// The rows of the restore under way.
    @Published private(set) var batch: Set<String> = []

    private let agents: AgentRecoveryController?
    private let shells: ShellRecoveryController?
    /// Lost rows dismissed or closed without restoring, for the palette's
    /// Recover Sessions to bring back until Octet quits.
    private var setAside: [RecoveryItem] = []
    /// Restored this run, so a second drop doesn't offer them again.
    private var settled: Set<String> = []
    private var autoClose: DispatchWorkItem?

    init(agents: AgentRecoveryController?, shells: ShellRecoveryController?) {
        self.agents = agents
        self.shells = shells
        agents?.onLost = { [weak self] records in self?.offer(records.map { RecoveryItem(agent: $0) }) }
        shells?.onLost = { [weak self] records in self?.offer(records.map { RecoveryItem(terminal: $0) }) }
    }

    var restorable: [RecoveryItem] { items.filter(\.status.canRestore) }
    var chosen: [RecoveryItem] { restorable.filter { selected.contains($0.id) } }
    var isRestoring: Bool { !batch.isEmpty }
    var isFinished: Bool { RecoveryList.isFinished(items) && batch.isEmpty }
    /// Whether the palette's Recover Sessions has lost rows to bring back.
    var hasSetAside: Bool { !setAside.isEmpty }

    // MARK: - Showing

    /// Rows a crash took, added to any already listed.
    func offer(_ incoming: [RecoveryItem]) {
        guard !incoming.isEmpty else { return }
        let base = mode == .lost && isPresented ? items : []
        let ids = Set(incoming.map(\.id))
        setAside.removeAll { ids.contains($0.id) }
        let merged = RecoveryList.merge(base, incoming, settled: settled)
        let added = merged.filter { item in !base.contains { $0.id == item.id } }
        guard !added.isEmpty else { return }
        if mode != .lost { batch = [] }
        mode = .lost
        items = merged
        selected.formUnion(added.filter(\.status.canRestore).map(\.id))
        present()
        inspect(added)
    }

    /// The palette's and menu's Recover Sessions: what was set aside from a
    /// crash when there is any, else recent sessions that aren't running.
    func reopen() {
        guard !isRestoring else { return present() }
        if !setAside.isEmpty {
            let items = setAside.map { item -> RecoveryItem in
                var item = item
                if item.status.isFailed || item.status == .restoring { item.status = .ready }
                return item
            }
            setAside = []
            mode = .lost
            self.items = items
            selected = Set(items.filter(\.status.canRestore).map(\.id))
            present()
            inspect(items)
            return
        }
        let history = Array((agents?.resumableSessions() ?? []).prefix(30)).map { RecoveryItem(agent: $0) }
        mode = .history
        items = history
        // Nothing chosen up front: these weren't lost, only stopped.
        selected = []
        present()
        inspect(history)
    }

    private func present() {
        autoClose?.cancel()
        isPresented = true
    }

    /// Hides the panel. Lost rows not restored are set aside for reopening.
    func close() {
        autoClose?.cancel()
        if mode == .lost {
            let remaining = items.filter { $0.status != .restored && !batch.contains($0.id) }
            setAside = RecoveryList.merge(setAside, remaining, settled: settled)
            agents?.markHandled(remaining.compactMap(\.agentRecord))
        }
        isPresented = false
        items = []
        selected = []
    }

    // MARK: - Choosing

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var allSelected: Bool { !restorable.isEmpty && restorable.allSatisfy { selected.contains($0.id) } }

    func selectAll(_ on: Bool) {
        selected = on ? Set(restorable.map(\.id)) : []
    }

    // MARK: - Acting

    func restoreChosen() { restore(chosen.map(\.id)) }

    func restore(_ ids: [String]) {
        let targets = items.filter { ids.contains($0.id) && $0.status.canRestore && !batch.contains($0.id) }
        guard !targets.isEmpty else { return }
        autoClose?.cancel()
        for item in targets { set(item.id, .restoring) }
        batch.formUnion(targets.map(\.id))
        selected.subtract(targets.map(\.id))
        if mode == .preview { return simulate(targets) }
        let agentRecords = targets.compactMap(\.agentRecord)
        let terminalRecords = targets.compactMap(\.terminalRecord)
        agents?.resume(agentRecords) { [weak self] record, failure in
            self?.finish(RecoveryItem(agent: record).id, failure)
        }
        shells?.restore(terminalRecords) { [weak self] record, failure in
            self?.finish(RecoveryItem(terminal: record).id, failure)
        }
    }

    private func finish(_ id: String, _ failure: String?) {
        if let failure {
            set(id, .failed(failure))
            selected.insert(id)
        } else {
            set(id, .restored)
            settled.insert(id)
            setAside.removeAll { $0.id == id }
        }
        batch.remove(id)
        guard batch.isEmpty else { return }
        // All back with nothing to read: the panel steps aside by itself.
        if isPresented, items.allSatisfy({ $0.status == .restored }) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isFinished, self.items.allSatisfy({ $0.status == .restored }) else { return }
                MotionPreferences.shared.perform(.palette) { self.close() }
            }
            autoClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    /// Takes one row off the list. A lost one is set aside rather than
    /// forgotten, and isn't offered again after a later restart.
    func dismiss(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), !batch.contains(id) else { return }
        items.removeAll { $0.id == id }
        selected.remove(id)
        if mode == .lost, item.status != .restored {
            setAside = RecoveryList.merge(setAside, [item], settled: settled)
            if let record = item.agentRecord { agents?.markHandled([record]) }
        }
        if items.isEmpty { close() }
    }

    /// Dismisses every row that isn't on its way back, and hides the panel.
    func dismissAll() {
        for item in items where !batch.contains(item.id) { dismiss(item.id) }
        if isPresented, batch.isEmpty { close() }
    }

    func copyCommand(_ item: RecoveryItem) {
        if let record = item.agentRecord, mode != .preview { agents?.copyCommand(record) }
    }

    private func set(_ id: String, _ status: RecoveryStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    // MARK: - Looking

    /// Off the main thread: which rows can't come back (their folder or
    /// session file is gone), and what each last said.
    private func inspect(_ targets: [RecoveryItem]) {
        guard mode != .preview, !targets.isEmpty else { return }
        let dumps = Dictionary(targets.compactMap { item in
            item.terminalRecord.map { (item.id, shells?.dumpURL(for: $0)) }
        }, uniquingKeysWith: { first, _ in first })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [String: (reason: String?, preview: String?)] = [:]
            for item in targets {
                let folderExists = FileManager.default.fileExists(atPath: item.cwd)
                switch item.kind {
                case .agent(let record):
                    let reason = RecoveryList.unavailableReason(
                        record, folderExists: folderExists, sessionFileExists: RecoveryList.sessionFileExists(record))
                    let preview = RecoveryList.transcriptPath(record).flatMap { path in
                        RecoveryList.lastMessage(agent: record.agent, lines: CodexThreads.tail(path: path, bytes: 256 * 1024))
                    }
                    found[item.id] = (reason, preview)
                case .terminal(let record):
                    let reason = RecoveryList.unavailableReason(record, folderExists: folderExists)
                    let preview = (dumps[item.id] ?? nil)
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                        .flatMap { ShellRecovery.lastOutputLine($0) }
                    found[item.id] = (reason, preview)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, result) in found {
                    guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                    if let preview = result.preview { self.items[index].preview = preview }
                    if let reason = result.reason, self.items[index].status.canRestore {
                        self.items[index].status = .unavailable(reason)
                        self.selected.remove(id)
                    }
                }
            }
        }
    }

    // MARK: - Preview

    #if DEBUG
    /// Verification hook (OCTET_OPEN_WINDOW=recovery-preview[:stage]): the
    /// panel with sample rows. Restoring them only pretends; nothing runs.
    /// Stages: `restoring`, `done`, `history`, `empty`.
    func showPreview(stage: String?) {
        let now = Date()
        func agent(_ kind: String, _ session: String?, tab: String, workspace: String, cwd: String, ago: TimeInterval) -> AgentSessionRecord {
            AgentSessionRecord(agent: kind, sessionId: session, cwd: cwd, workspaceLabel: workspace, tabLabel: tab,
                               terminalId: "preview-\(kind)-\(tab)", firstSeen: now.addingTimeInterval(-ago - 3600),
                               lastSeen: now.addingTimeInterval(-ago))
        }
        let home = NSHomeDirectory()
        var sample: [RecoveryItem] = [
            RecoveryItem(agent: agent("claude", "4f1c2a9e", tab: "Migrate the schema", workspace: "octet",
                                      cwd: home + "/Developer/apps/octet", ago: 40),
                         preview: "Migrations pass locally. I've left the down-migration for you to review before it runs."),
            RecoveryItem(agent: agent("codex", "019e3e63-ed09", tab: "Review auth flow", workspace: "octet",
                                      cwd: home + "/Developer/apps/octet/Server", ago: 95),
                         preview: "Two findings: the refresh token is logged at debug level, and the session cookie lacks SameSite."),
            RecoveryItem(terminal: ShellSessionRecord(terminalId: "preview-term-dev", workspaceLabel: "octet", tabLabel: "dev server",
                                                      cwd: home + "/Developer/apps/octet/web", command: "npm run dev",
                                                      firstSeen: now.addingTimeInterval(-7200), lastSeen: now.addingTimeInterval(-40)),
                         preview: "ready - started server on 0.0.0.0:3000, url: http://localhost:3000"),
            RecoveryItem(agent: agent("opencode", "ses_7Hq2", tab: "opencode", workspace: "api",
                                      cwd: home + "/Developer/api", ago: 300),
                         preview: "Added the pagination cursor to /v2/orders."),
            RecoveryItem(agent: agent("pi", "pi-0021", tab: "Flaky test", workspace: "api",
                                      cwd: home + "/Developer/api", ago: 600),
                         status: .failed("layout.apply: workspace w4 was closed while restoring")),
            RecoveryItem(agent: agent("claude", "9b7d", tab: "Spike: old prototype", workspace: "",
                                      cwd: home + "/Developer/scratch/prototype", ago: 7200),
                         status: .unavailable("Its folder no longer exists")),
        ]
        switch stage {
        case "restoring":
            sample[0].status = .restored
            sample[1].status = .restoring
            sample[2].status = .restoring
        case "done":
            for index in sample.indices where sample[index].status.canRestore { sample[index].status = .restored }
        case "empty":
            sample = []
        default:
            break
        }
        mode = .preview
        items = stage == "history" ? sample.filter { $0.agentRecord != nil && $0.status == .ready } : sample
        batch = Set(items.filter { $0.status == .restoring }.map(\.id))
        selected = stage == "history" ? [] : Set(items.filter { $0.status == .ready }.map(\.id))
        present()
    }
    #endif

    /// The preview's restore: each row lands a moment after the last; the
    /// Pi one fails, to show how a failure reads.
    private func simulate(_ targets: [RecoveryItem]) {
        for (index, item) in targets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(index + 1)) { [weak self] in
                self?.finish(item.id, item.agent == "pi" ? "pi: no session pi-0021 in ~/.pi/sessions" : nil)
            }
        }
    }
}
