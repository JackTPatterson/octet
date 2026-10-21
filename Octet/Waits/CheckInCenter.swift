import AppKit
import Foundation

/// Long-haul check-ins, the part of the Waits system for work that takes
/// days or weeks to give a result. A check-in is a `Wait` (same list, same
/// file, same agent socket); this is what makes one come round: at the due
/// time it notifies, and per its mode wakes the agent's session and sends
/// the saved prompt. If the session is gone (the agent exited, Octet was
/// closed, the Mac slept or restarted) it resumes it with the agent's own
/// resume command in the same folder, or, when it can't be resumed, starts
/// a new conversation from the summary saved when the check-in was set, and
/// says which happened. Occurrences missed while Octet was off collapse into
/// one. It also notices a session that says it's working but has gone
/// quiet. Nothing here runs a shell command, and a wake only ever sends the
/// saved prompt to that agent's own session.
@MainActor
final class CheckInCenter: ObservableObject {
    static let shared = CheckInCenter()

    /// A session that looks stalled, waiting for Resume, Snooze or Ignore.
    struct StallNotice: Identifiable, Equatable {
        let id: String
        var label: String
        var quietFor: TimeInterval
        /// What the session looked like when it was noticed; a change means
        /// it has done something since.
        var token: String
        var workspaceId: String?
        var paneId: String?
        var conversationId: String?
    }

    @Published private(set) var stalls: [StallNotice] = []
    /// The check-in being written or edited in the sheet.
    @Published var draft: CheckInDraft?
    /// Check-ins being woken right now.
    @Published private(set) var waking: Set<String> = []

    private weak var store: SessionStore?
    private var tracker = StallTracker()
    private var recentResumes: [Date] = []
    private var screenPrints: [String: String] = [:]
    private var lastScreenSample = Date.distantPast
    private var sampling = false

    private var waits: WaitCenter { WaitCenter.shared }
    private var settings: OctetSettings { SettingsStore.shared.values }

    // MARK: - What there is

    /// Reminders waiting first, then by when they're next due; paused and
    /// finished ones last.
    var checkIns: [Wait] {
        waits.waits.filter(\.isCheckIn).sorted { lhs, rhs in
            func rank(_ wait: Wait) -> Int {
                guard let info = wait.checkIn else { return 4 }
                if info.hasReminder { return 0 }
                if info.isFinished { return 3 }
                if info.paused { return 2 }
                return 1
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.nextCheckAt < rhs.nextCheckAt
        }
    }

    func checkIn(_ id: String) -> Wait? { waits.waits.first { $0.id == id && $0.isCheckIn } }

    /// Check-ins with a reminder waiting for the person, for the Dock badge.
    var dueCount: Int { waits.waits.filter { $0.checkIn?.hasReminder == true }.count }

    var isPaused: Bool { settings.checkInsPaused }

    var quietHours: QuietHours {
        QuietHours(enabled: settings.quietHours, startMinute: settings.quietStartMinute, endMinute: settings.quietEndMinute)
    }

    var defaultMode: CheckInMode { CheckInMode(rawValue: settings.checkInDefaultMode) ?? .both }

    /// System notifications are for the installed app only: never a
    /// verification copy or a build run from a temporary folder (see
    /// `AgentConfigWrites`, which honours OCTET_NO_AGENT_CONFIG), the debug
    /// sample or a test run.
    var allowsSystemNotifications: Bool {
        !waits.isSample && AgentConfigWrites.allowedHere
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    // MARK: - Lifecycle

    func start(store: SessionStore) {
        self.store = store
        guard allowsSystemNotifications else { return }
        CheckInNotifier.shared.attach()
        syncNotifications()
    }

    /// Called every minute by the Waits timer, and once shortly after launch
    /// to catch up on what came round while Octet was closed.
    func tick(now: Date = Date()) {
        guard !waits.isSample, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        pruneFinished(now)
        if !isPaused {
            let due = checkIns.filter { wait in
                guard let info = wait.checkIn else { return false }
                return !info.paused && !info.isFinished && wait.nextCheckAt <= now
            }.sorted { $0.nextCheckAt < $1.nextCheckAt }
            for wait in due { comeRound(wait.id, now: now) }
            drainQueue(now)
        }
        sampleStalls(now)
        syncNotifications()
    }

    /// Makes the macOS notifications match the check-ins.
    func syncNotifications() {
        guard allowsSystemNotifications else { return }
        CheckInNotifier.shared.sync(waits.waits.filter(\.isCheckIn),
                                    enabled: settings.checkInsNotifyWhenClosed && !settings.checkInsPaused)
    }

    private func pruneFinished(_ now: Date) {
        for wait in waits.waits {
            guard let finished = wait.checkIn?.finishedAt, now.timeIntervalSince(finished) > 14 * 86_400,
                  wait.checkIn?.hasReminder != true else { continue }
            waits.remove(wait.id)
        }
    }

    // MARK: - Keeping the list

    func add(_ wait: Wait) {
        waits.add(wait)
        if allowsSystemNotifications, settings.checkInsNotifyWhenClosed { CheckInNotifier.shared.explainAndRequest() }
        syncNotifications()
    }

    func delete(_ id: String) {
        waits.remove(id)
        if allowsSystemNotifications { CheckInNotifier.shared.clearDelivered(for: id) }
        syncNotifications()
    }

    func setPaused(_ id: String, _ paused: Bool) {
        waits.mutateWait(id) { $0.checkIn?.paused = paused }
        if !paused { tick() }
        syncNotifications()
    }

    /// The reminder is seen: take it off the list of what's due.
    func dismissReminder(_ id: String) {
        waits.mutateWait(id) {
            $0.checkIn?.dueSince = nil
            $0.checkIn?.dueMissed = 0
        }
        updateBadge()
    }

    /// Lets this occurrence go by without anything happening.
    func skipNext(_ id: String, now: Date = Date()) {
        guard let wait = checkIn(id), var info = wait.checkIn, info.recurrence != nil, !info.isFinished else { return }
        let due = wait.nextCheckAt
        let result = info.occur(due: due, now: due)
        info.append(CheckInLogEntry(at: now, due: due, sessionAlive: nil, outcome: .skipped, note: "Skipped by you", manual: true))
        waits.mutateWait(id) { wait in
            wait.checkIn = info
            if let next = result.next {
                wait.nextCheckAt = next
                wait.condition = .date(next)
            }
        }
        syncNotifications()
    }

    func edit(_ id: String) {
        guard let wait = checkIn(id) else { return }
        draft = CheckInDraft(editing: wait, windowId: WindowRegistry.shared.key?.id)
    }

    /// Writes (or rewrites) a check-in from the sheet's fields.
    func save(_ draft: CheckInDraft, now: Date = Date()) {
        guard let first = draft.firstDate(now: now) else { return }
        let recurrence = draft.recurrence(first: first, now: now)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = draft.editingId, var wait = checkIn(id) {
            wait.title = title.isEmpty ? CheckInDraft.defaultTitle(prompt: draft.prompt) : title
            wait.next = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            wait.checkIn?.mode = draft.mode
            wait.checkIn?.recurrence = recurrence
            wait.checkIn?.finishedAt = nil
            wait.nextCheckAt = recurrence?.start ?? first
            wait.condition = .date(wait.nextCheckAt)
            waits.update(wait)
            syncNotifications()
            return
        }
        let session = draft.origin.conversationId.flatMap { id in AgentCenter.shared.sessions.first { $0.id == id } }
        let name = title.isEmpty ? CheckInDraft.defaultTitle(prompt: draft.prompt) : title
        let wait = Wait.makeCheckIn(
            title: name, prompt: draft.prompt, mode: draft.mode, first: recurrence?.start ?? first, recurrence: recurrence,
            origin: draft.origin,
            brief: WaitCenter.brief(for: session, branch: draft.origin.branch, waitingFor: name)
                ?? WaitCenter.brief(origin: draft.origin, waitingFor: name), now: now)
        add(wait)
        ToastCenter.shared.info("Check-in set: \(wait.title)",
                                detail: (recurrence?.summary ?? "Once") + ". It's in the sidebar under Check-ins.")
    }

    // MARK: - Writing one

    /// Opens the sheet for a check-in on a workspace, or on a conversation.
    func compose(workspaceId: String?, session: AgentSession? = nil, prompt: String? = nil, first: Date? = nil,
                 title: String? = nil, pickTime: Bool = false) {
        guard let store else { return }
        let id = session?.workspaceId ?? workspaceId
        let cwd = session?.cwd ?? id.flatMap { store.snapshot.directory(ofWorkspace: $0) } ?? NSHomeDirectory()
        var draft = CheckInDraft(origin: waits.origin(workspaceId: id, session: session, cwd: cwd),
                                 windowId: WindowRegistry.shared.key?.id, mode: defaultMode)
        if let prompt { draft.prompt = prompt }
        if let first { draft.setFirst(first) }
        if let title { draft.title = title }
        draft.startPicking = pickTime
        self.draft = draft
    }

    // MARK: - When one comes round

    /// An occurrence is due: the schedule moves on (missed ones collapse
    /// into this), the person is told, and the mode says what else.
    /// `person` is true when they asked for it (clicked its notification).
    func comeRound(_ id: String, now: Date = Date(), person: Bool = false) {
        guard var wait = checkIn(id), var info = wait.checkIn, !info.isFinished else { return }
        let due = wait.nextCheckAt
        let result = info.occur(due: due, now: now)
        // An earlier prompt still waiting to be sent is replaced by this one.
        for entry in info.log where entry.outcome == .queued {
            info.update(entry.id) { $0.outcome = .skipped; $0.note = "Replaced by the next check-in" }
        }
        let entry = CheckInLogEntry(at: now, due: due, sessionAlive: nil,
                                    outcome: info.mode.wakesAgent ? .queued : .reminded, missed: result.missed)
        info.append(entry)
        if info.mode.leavesReminder {
            info.dueSince = info.dueSince ?? now
            info.dueMissed += result.missed
        }
        info.wakeQueued = info.mode.wakesAgent
        info.queuedReason = nil
        wait.checkIn = info
        if let next = result.next {
            wait.nextCheckAt = next
            wait.condition = .date(next)
        }
        waits.update(wait)
        announce(wait, missed: result.missed)
        if info.mode.wakesAgent { tryWake(id, logId: entry.id, person: person, now: now) }
    }

    private func announce(_ wait: Wait, missed: Int) {
        let mode = wait.checkIn?.mode ?? .both
        var detail = HandoffBrief.clip(wait.next.replacingOccurrences(of: "\n", with: " "), 120)
        if missed > 0 { detail = "\(missed) earlier \(missed == 1 ? "one was" : "ones were") missed while Octet was off. " + detail }
        if allowsSystemNotifications { CheckInNotifier.shared.clearDelivered(for: wait.id) }
        let id = wait.id
        ToastCenter.shared.info("Check-in: \(wait.title)", detail: detail, after: NSApp.isActive ? 12 : 60,
                                action: mode == .wake ? nil : ToastCenter.Action(title: "Run") { CheckInCenter.shared.runNow(id) })
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        if settings.agentSounds { NSSound(named: "Glass")?.play() }
        updateBadge()
    }

    /// One Dock count for agents, waits and check-ins: `AttentionRouter`'s.
    func updateBadge() {
        AttentionRouter.shared.refreshDockBadge()
    }

    // MARK: - Waking

    /// Run now: send the saved prompt to the agent's session, however the
    /// schedule stands. Does not move the schedule.
    func runNow(_ id: String, now: Date = Date()) {
        guard let wait = checkIn(id), wait.checkIn != nil else { return }
        let entry = CheckInLogEntry(at: now, due: wait.nextCheckAt, sessionAlive: nil, outcome: .queued, manual: true)
        waits.mutateWait(id) {
            $0.checkIn?.append(entry)
            $0.checkIn?.wakeQueued = true
        }
        tryWake(id, logId: entry.id, person: true, now: now)
    }

    /// A reminder's link, opened (`octet://checkin?id=`): catches up and
    /// runs it if it's due, else just shows where it is.
    func open(link id: String) {
        guard let wait = checkIn(id), let info = wait.checkIn else {
            ToastCenter.shared.info("That check-in is gone")
            return
        }
        let now = Date()
        if !info.isFinished, wait.nextCheckAt <= now, !info.paused {
            comeRound(id, now: now, person: true)
        } else if info.wakeQueued || (info.hasReminder && info.mode.wakesAgent) {
            runNow(id, now: now)
        } else if let workspaceId = wait.origin.workspaceId {
            show(workspaceId)
        }
    }

    private func drainQueue(_ now: Date) {
        for wait in checkIns {
            guard let info = wait.checkIn, info.wakeQueued, !info.paused else { continue }
            let logId = info.log.last { $0.outcome == .queued }?.id
            tryWake(wait.id, logId: logId, person: false, now: now)
        }
    }

    private enum Target {
        case conversation(AgentSession)
        case terminal(EngineAgent)
        case busy
        case dead
    }

    private func classify(_ origin: Wait.Origin) -> Target {
        if let id = origin.conversationId, let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) {
            return .conversation(session)
        }
        guard let sessionId = origin.sessionId else { return .dead }
        // A conversation here already carrying this session on (an earlier wake).
        if let session = AgentCenter.shared.sessions.first(where: { $0.sessionId == sessionId || $0.threadId == sessionId }) {
            return .conversation(session)
        }
        guard let store, let agent = store.snapshot.agents.first(where: { agent in
            agent.sessionReference == sessionId || agent.terminalId.flatMap(store.recovery.sessionId(forTerminal:)) == sessionId
        }) else { return .dead }
        return agent.agentStatus == .idle || agent.agentStatus == .done ? .terminal(agent) : .busy
    }

    /// What the agent reads.
    static func message(for wait: Wait, missed: Int, now: Date = Date()) -> String {
        var text = "Scheduled check-in: \(wait.title)."
        if missed > 0 {
            text += " (\(missed) earlier check-in\(missed == 1 ? "" : "s") came round while Octet or the Mac was off; this one stands for all of them.)"
        }
        return text + "\n\n" + wait.next
    }

    private func tryWake(_ id: String, logId: String?, person: Bool, now: Date = Date()) {
        guard let wait = checkIn(id), let info = wait.checkIn, info.wakeQueued, !waking.contains(id) else { return }
        if waits.isSample {
            return finishWake(id, logId, .simulated, alive: nil, note: "Nothing was sent: this is the debug sample", person: person)
        }
        if !person, let end = quietHours.end(after: now) {
            return queue(id, logId, "Quiet hours until " + CheckInInfo.dayTime(end))
        }
        let text = Self.message(for: wait, missed: info.dueMissed, now: now)
        switch classify(wait.origin) {
        case .conversation(let session):
            show(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
            session.send(text)
            finishWake(id, logId, .sentToConversation, alive: true, note: nil, person: person)
        case .terminal(let agent):
            sendToTerminal(agent, text)
            if let workspaceId = agent.workspaceId { show(workspaceId) }
            finishWake(id, logId, .sentToTerminal, alive: true, note: nil, person: person)
        case .busy:
            queue(id, logId, "The agent is busy; sends when it's free")
        case .dead:
            guard person || WakeThrottle.slots(recent: recentResumes, now: now) > 0 else {
                return queue(id, logId, "Waiting for a free slot: \(WakeThrottle.limit) sessions were just resumed")
            }
            wakeDead(wait, text: text, logId: logId, person: person)
        }
    }

    private func queue(_ id: String, _ logId: String?, _ reason: String) {
        waits.mutateWait(id) { wait in
            wait.checkIn?.queuedReason = reason
            if let logId { wait.checkIn?.update(logId) { $0.note = reason } }
        }
    }

    /// Records how a wake went, and settles the reminder.
    private func finishWake(_ id: String, _ logId: String?, _ outcome: CheckInLogEntry.Outcome, alive: Bool?, note: String?,
                            person: Bool) {
        waking.remove(id)
        waits.mutateWait(id) { wait in
            wait.checkIn?.wakeQueued = false
            wait.checkIn?.queuedReason = nil
            // A reminder stays until looked at, unless the person ran it themselves.
            if person || wait.checkIn?.mode.leavesReminder != true {
                wait.checkIn?.dueSince = nil
                wait.checkIn?.dueMissed = 0
            }
            if let logId {
                wait.checkIn?.update(logId) {
                    $0.outcome = outcome
                    $0.sessionAlive = alive
                    $0.note = note
                }
            }
        }
        updateBadge()
        guard let wait = checkIn(id) else { return }
        let how: String
        switch outcome {
        case .sentToConversation: how = "sent to the open conversation"
        case .sentToTerminal: how = "sent to the agent"
        case .resumedSession: how = "its session was gone, so resumed it"
        case .newConversation: how = "it couldn't be resumed, so started a new conversation"
        case .failed: how = "couldn't wake it" + (note.map { ": " + $0 } ?? "")
        default: how = outcome == .simulated ? "sample run, nothing sent" : "done"
        }
        ToastCenter.shared.info("Check-in: \(wait.title)", detail: how.prefix(1).uppercased() + how.dropFirst(), after: 10,
                                action: wait.origin.workspaceId.map { workspaceId in
                                    ToastCenter.Action(title: "Show") { WindowRegistry.shared.key?.focusWorkspace(workspaceId) }
                                })
    }

    private func sendToTerminal(_ agent: EngineAgent, _ text: String) {
        guard let store else { return }
        let client = store.client
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? client.call("pane.send_text", ["pane_id": agent.paneId, "text": line])
            Thread.sleep(forTimeInterval: 0.15)
            _ = try? client.call("pane.send_text", ["pane_id": agent.paneId, "text": "\r"])
        }
    }

    private func show(_ workspaceId: String) {
        store?.keepInView(workspaceId)
        WindowRegistry.shared.window(showing: workspaceId)?.focusWorkspace(workspaceId)
            ?? WindowRegistry.shared.key?.focusWorkspace(workspaceId)
    }

    /// The session is gone: find its workspace (or make one on the folder),
    /// then resume it with the agent's own resume command, or start over
    /// from the saved summary.
    private func wakeDead(_ wait: Wait, text: String, logId: String?, person: Bool) {
        guard let store else {
            return finishWake(wait.id, logId, .failed, alive: false, note: "Octet isn't ready yet", person: person)
        }
        let origin = wait.origin
        guard FileManager.default.fileExists(atPath: origin.cwd) else {
            return finishWake(wait.id, logId, .failed, alive: false, note: "Its folder no longer exists", person: person)
        }
        waking.insert(wait.id)
        let id = wait.id
        // Never stuck "waking" if the engine doesn't answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated {
                let center = CheckInCenter.shared
                guard center.waking.contains(id) else { return }
                center.finishWake(id, logId, .failed, alive: false, note: "Timed out opening the workspace", person: person)
            }
        }
        let snapshot = store.snapshot
        let existing = origin.workspaceId.flatMap { id in snapshot.workspaces.contains { $0.workspaceId == id } ? id : nil }
            ?? snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == origin.cwd }?.workspaceId
        if let existing {
            return resume(wait, text: text, workspaceId: existing, logId: logId, person: person)
        }
        let label = origin.workspaceLabel ?? URL(fileURLWithPath: origin.cwd).lastPathComponent
        store.call("workspace.create", ["cwd": origin.cwd, "label": label, "focus": false],
                   failure: "Couldn't open \(label)") { [weak self] created in
            guard let workspaceId = created.workspaceId else { return }
            self?.resume(wait, text: text, workspaceId: workspaceId, logId: logId, person: person)
        }
    }

    private func resume(_ wait: Wait, text: String, workspaceId: String, logId: String?, person: Bool) {
        let origin = wait.origin
        let now = Date()
        show(workspaceId)
        let engine = origin.agent.flatMap(AgentSession.Engine.init(rawValue:))
        let record = AgentSessionRecord(agent: origin.agent ?? "claude", sessionId: origin.sessionId, cwd: origin.cwd,
                                        workspaceLabel: origin.workspaceLabel ?? "", tabLabel: wait.title,
                                        terminalId: "checkin-" + wait.id, firstSeen: now, lastSeen: now)
        // The agent's own record of the session; nil for agents Octet can't look inside.
        let sessionFileGone = RecoveryList.sessionFileExists(record) == false
        if let sessionId = origin.sessionId, !sessionFileGone {
            if let engine {
                let session = AgentCenter.shared.resume(engine: engine, sessionId: sessionId, cwd: origin.cwd,
                                                        workspaceId: workspaceId, title: wait.title, start: false)
                session.send(text)
                recentResumes.append(now)
                return finishWake(wait.id, logId, .resumedSession, alive: false,
                                  note: "with \(engine.displayName)'s own resume, in \(HandoffBrief.abbreviate(origin.cwd))", person: person)
            }
            if record.resumeCommand != nil, let store {
                recentResumes.append(now)
                return resumeInTerminal(wait, record: record, text: text, workspaceId: workspaceId, store: store, logId: logId, person: person)
            }
        }
        // Can't be resumed: a new conversation that starts from the summary.
        let session = AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: origin.cwd, engine: engine ?? .claude)
        session.title = String(wait.title.prefix(60))
        let opening = wait.brief ?? "Carrying on work in \(HandoffBrief.abbreviate(origin.cwd))"
            + (origin.branch.map { " on \($0)" } ?? "") + ". Look at `git status` and `git log` for where it stands."
        session.send(opening + "\n\n" + text)
        finishWake(wait.id, logId, .newConversation, alive: false,
                   note: origin.sessionId == nil ? "no session id was saved" : "its session file is gone", person: person)
    }

    /// For agents Octet has no conversation view for: their own resume
    /// command in a new tab, then the prompt once the agent is at its prompt.
    private func resumeInTerminal(_ wait: Wait, record: AgentSessionRecord, text: String, workspaceId: String,
                                  store: SessionStore, logId: String?, person: Bool) {
        let client = store.client
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let before = Set(store.snapshot.agents.map(\.paneId))
        let request = AgentRecovery.resumeRequest(record, shell: shell, workspaceId: workspaceId, tabId: nil)
        let id = wait.id
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String? = {
                do { try client.call("layout.apply", request); return nil } catch { return RecoveryError.describe(error) }
            }()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = CheckInCenter.shared
                    if let failure {
                        return center.finishWake(id, logId, .failed, alive: false, note: failure, person: person)
                    }
                    center.sendWhenReady(id, text: text, cwd: record.cwd, before: before, attempts: 0, logId: logId, person: person)
                }
            }
        }
    }

    private func sendWhenReady(_ id: String, text: String, cwd: String, before: Set<String>, attempts: Int,
                               logId: String?, person: Bool) {
        guard let store else { return }
        if let agent = store.snapshot.agents.first(where: { !before.contains($0.paneId) && ($0.cwd ?? cwd) == cwd
            && ($0.agentStatus == .idle || $0.agentStatus == .done) }) {
            sendToTerminal(agent, text)
            return finishWake(id, logId, .resumedSession, alive: false, note: "with the agent's own resume command, in a new tab", person: person)
        }
        guard attempts < 24 else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return finishWake(id, logId, .resumedSession, alive: false,
                              note: "resumed in a new tab, but it didn't reach its prompt; the prompt is on your clipboard", person: person)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                CheckInCenter.shared.sendWhenReady(id, text: text, cwd: cwd, before: before, attempts: attempts + 1,
                                                   logId: logId, person: person)
            }
        }
    }

    // MARK: - Stalls

    /// Looks at every session marked working for signs of life. A session
    /// that has done nothing for the threshold gets a notice; nothing is
    /// stopped or sent.
    private func sampleStalls(_ now: Date) {
        let threshold = settings.stallDetection ? settings.stallHours * 3600 : 0
        guard let store else { return }
        var subjects: [StallTracker.Subject] = []
        var notices: [String: StallNotice] = [:]
        for session in AgentCenter.shared.sessions {
            let id = "c:" + session.id
            let working = session.conversation.isRunning && session.pendingPermission == nil && session.pendingQuestion == nil
            let token = Self.activityToken(session.conversation)
            subjects.append(.init(id: id, label: session.title, isWorking: working, token: token))
            notices[id] = StallNotice(id: id, label: session.title, quietFor: 0, token: token,
                                      workspaceId: session.workspaceId, paneId: nil, conversationId: session.id)
        }
        let snapshot = store.snapshot
        var workingPanes: [String] = []
        for agent in snapshot.agents where !agent.isSubagentViewer {
            let id = "p:" + agent.paneId
            let name = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
            let tab = agent.tabId.flatMap { tabId in snapshot.tabs.first { $0.tabId == tabId } }
            let label = tab.map { "\(name) · \(TabAutoName.display(label: $0.label, number: $0.number))" } ?? name
            let working = agent.agentStatus == .working
            if working { workingPanes.append(agent.paneId) }
            let token = "\(agent.stateChangeSeq ?? 0)|\(screenPrints[agent.paneId] ?? "")"
            subjects.append(.init(id: id, label: label, isWorking: working, token: token))
            notices[id] = StallNotice(id: id, label: label, quietFor: 0, token: token,
                                      workspaceId: agent.workspaceId, paneId: agent.paneId, conversationId: nil)
        }
        sampleScreens(of: workingPanes, store: store, now: now)
        let found = tracker.observe(subjects, now: now, threshold: threshold)
        // Notices whose session has moved on, or is gone, drop away.
        stalls = stalls.filter { notice in
            guard let subject = subjects.first(where: { $0.id == notice.id }) else { return false }
            return subject.isWorking && subject.token == notice.token
        }
        for stall in found {
            guard var notice = notices[stall.id] else { continue }
            notice.quietFor = stall.quietFor
            stalls.removeAll { $0.id == notice.id }
            stalls.append(notice)
            ToastCenter.shared.info("\(notice.label) looks stalled",
                                    detail: "Marked working, but nothing for \(WaitSchedule.span(stall.quietFor)). Resume, snooze or ignore it in the sidebar.",
                                    after: 15, action: notice.workspaceId.map { workspaceId in
                                        ToastCenter.Action(title: "Show") { WindowRegistry.shared.key?.focusWorkspace(workspaceId) }
                                    })
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// Reads what each working terminal agent shows, a few minutes apart and
    /// off the main thread, as a fingerprint of the words on screen.
    private func sampleScreens(of panes: [String], store: SessionStore, now: Date) {
        guard !sampling, !panes.isEmpty, now.timeIntervalSince(lastScreenSample) >= 240 else { return }
        sampling = true
        lastScreenSample = now
        let client = store.client
        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            for pane in panes {
                guard let read = (try? client.call("pane.read", ["pane_id": pane, "source": "visible"]))?["read"] as? [String: Any],
                      let text = read["text"] as? String else { continue }
                found[pane] = StallTracker.fingerprint(screen: text)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = CheckInCenter.shared
                    center.sampling = false
                    center.screenPrints = center.screenPrints.filter { panes.contains($0.key) }.merging(found) { _, new in new }
                }
            }
        }
    }

    /// Changes whenever a conversation does anything: a new item, more of
    /// the latest one, a tool's output arriving.
    static func activityToken(_ conversation: AgentConversation) -> String {
        guard let last = conversation.items.last else { return "empty" }
        var size = 0
        switch last.kind {
        case .user(let text), .text(let text), .thinking(let text), .notice(let text): size = text.utf8.count
        case .tool(let call): size = (call.result?.utf8.count ?? 0) + (call.liveOutput?.utf8.count ?? 0) + call.input.utf8.count
        }
        return "\(conversation.items.count)|\(last.id)|\(size)|\(conversation.isRunning)"
    }

    func resumeStall(_ id: String) {
        guard let notice = stalls.first(where: { $0.id == id }) else { return }
        stalls.removeAll { $0.id == id }
        let nudge = "You seem to have stalled. Please carry on where you left off."
        if let conversationId = notice.conversationId,
           let session = AgentCenter.shared.sessions.first(where: { $0.id == conversationId }) {
            show(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
            session.send(nudge)
        } else if let paneId = notice.paneId, let agent = store?.snapshot.agents.first(where: { $0.paneId == paneId }) {
            if let workspaceId = agent.workspaceId { show(workspaceId) }
            WindowRegistry.shared.key?.focusAgent(paneId: paneId)
            sendToTerminal(agent, nudge)
        }
    }

    func snoozeStall(_ id: String, now: Date = Date()) {
        tracker.snooze(id, until: now.addingTimeInterval(max(1, settings.stallHours) * 3600))
        stalls.removeAll { $0.id == id }
    }

    func ignoreStall(_ id: String) {
        tracker.ignore(id)
        stalls.removeAll { $0.id == id }
    }

    func showStall(_ id: String) {
        guard let notice = stalls.first(where: { $0.id == id }), let workspaceId = notice.workspaceId else { return }
        show(workspaceId)
        if let paneId = notice.paneId { WindowRegistry.shared.key?.focusAgent(paneId: paneId) }
    }

    #if DEBUG
    /// A stall notice for the debug sample.
    func showSampleStall() {
        stalls = [StallNotice(id: "sample-stall", label: "Claude · mean-reversion paper run", quietFor: 7.5 * 3600, token: "sample",
                              workspaceId: nil, paneId: nil, conversationId: nil)]
    }
    #endif
}
