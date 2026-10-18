import AppKit
import Foundation

/// Checks installed agent tools for newer releases once a day and, when
/// there's something new, asks with the agent updates dialog.
@MainActor
final class AgentUpdatePrompter {
    static let shared = AgentUpdatePrompter()

    private static let checkedKey = "octet.agentUpdates.checkedAt.v1"
    private static let promptedKey = "octet.agentUpdates.prompted.v1"
    static let skippedKey = "octet.agentUpdates.skipped.v1"
    private var checking = false

    func check(_ agents: [DiscoveredAgent], force: Bool = false) {
        guard SettingsStore.shared.values.checkForAgentUpdates, !checking else { return }
        // A throwaway copy (a build being checked from a temporary folder or
        // a worktree) never offers to update the real agent tools.
        guard AgentConfigWrites.allowedHere || force else { return }
        #if DEBUG
        // The preview hook's sample dialog must not be replaced by real
        // updates, whose buttons would run real commands.
        if ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"]?.hasPrefix("agent-updates-preview") == true { return }
        #endif
        if !force, let checked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date,
           Date().timeIntervalSince(checked) < 24 * 3600 { return }
        checking = true
        AgentUpdateChecker.check(agents) { updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(updates) }
            }
        }
    }

    private func finished(_ found: [AgentUpdate]) {
        checking = false
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        let updates = AgentUpdateSelection.pending(found, skipped: Self.skipped)
        // Kept for the title bar's updates button, whether or not it's asked about.
        AgentUpdateCenter.shared.setWaiting(updates)
        guard !updates.isEmpty else { return }
        // The same set again is the same news: asked about once.
        let signature = AgentUpdateSelection.signature(updates)
        guard signature != UserDefaults.standard.string(forKey: Self.promptedKey) else { return }
        UserDefaults.standard.set(signature, forKey: Self.promptedKey)
        AgentUpdateCenter.shared.present(updates)
    }

    static var skipped: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: skippedKey) ?? [])
    }

    /// "Skip These Versions": these releases aren't asked about again; a
    /// newer release of the same tool is.
    static func skip(_ updates: [AgentUpdate]) {
        let next = AgentUpdateSelection.skipping(updates, in: skipped)
        UserDefaults.standard.set(next.sorted(), forKey: skippedKey)
    }
}

/// The agent updates dialog's state: which updates are offered, which the
/// person picked, and how each one's command went.
@MainActor
final class AgentUpdateCenter: ObservableObject {
    static let shared = AgentUpdateCenter()

    enum RowState: Equatable {
        case idle
        /// Picked for this run, waiting its turn.
        case queued
        case running
        case done
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let update: AgentUpdate
        var included = true
        var state: RowState = .idle
        var id: String { update.id }
    }

    enum Phase: Equatable {
        /// Picking what to update.
        case choosing
        case running
        /// Ran with at least one failure; the dialog stays to show it.
        case finished
    }

    /// Updates found and not yet installed or skipped; the title bar's
    /// updates button lists them after "Later".
    @Published private(set) var waiting: [AgentUpdate] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var presented = false
    @Published var showCommands = false
    /// The failed row whose error is unfolded.
    @Published var expandedError: String?
    /// The window that draws the dialog; nil (or closed since) falls back
    /// to the terminal window.
    private(set) weak var window: NSWindow?
    /// The preview hook's sample session: nothing runs, nothing is saved.
    private var preview = false
    /// Put away while running: the result arrives as a toast instead.
    private var hidden = false

    var included: [Row] { rows.filter(\.included) }
    /// The rows in the current (or last) run.
    var ran: [Row] { rows.filter { $0.state != .idle } }

    func setWaiting(_ updates: [AgentUpdate]) { waiting = updates }

    /// Asks again about what's waiting.
    func reopen() { present(waiting) }

    func present(_ updates: [AgentUpdate]) {
        guard !updates.isEmpty, phase != .running else { return }
        rows = updates.map { Row(update: $0) }
        phase = .choosing
        showCommands = false
        expandedError = nil
        hidden = false
        preview = false
        // A terminal window in front draws it; anything else (Marketplace,
        // nothing key) falls back to the terminal window.
        window = MainWindow.isKey ? NSApp.keyWindow : nil
        presented = true
    }

    func setIncluded(_ id: String, _ on: Bool) {
        guard phase == .choosing, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].included = on
    }

    // MARK: Actions

    /// Return: the footer's primary button.
    func primary() {
        switch phase {
        case .choosing: if !included.isEmpty { run(included.map(\.id)) }
        case .finished: retryFailed()
        case .running: break
        }
    }

    /// Escape, or a click outside: Later, Hide, or Close.
    func dismiss() {
        switch phase {
        case .choosing, .finished: close()
        case .running: hide()
        }
    }

    func skip() {
        guard phase == .choosing else { return }
        if !preview {
            AgentUpdatePrompter.skip(rows.map(\.update))
            waiting.removeAll { update in rows.contains { $0.id == update.id } }
        }
        close()
    }

    func close() {
        guard phase != .running else { return hide() }
        presented = false
        preview = false
    }

    /// Lets a long update carry on out of the way; a toast says how it went.
    func hide() {
        hidden = true
        presented = false
    }

    func retryFailed() {
        let failed = rows.compactMap { row -> String? in
            if case .failed = row.state { return row.id }
            return nil
        }
        guard !failed.isEmpty else { return }
        run(failed)
    }

    private func run(_ ids: [String]) {
        guard phase != .running else { return }
        phase = .running
        expandedError = nil
        showCommands = false
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].state = .queued }
        step(ids)
    }

    /// One at a time: package managers lock their global installs, and the
    /// rows read top to bottom.
    private func step(_ remaining: [String]) {
        guard let id = remaining.first, let index = rows.firstIndex(where: { $0.id == id }) else {
            return complete()
        }
        rows[index].state = .running
        let update = rows[index].update
        let rest = Array(remaining.dropFirst())
        let finish: (RowState) -> Void = { [weak self] state in
            guard let self, let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.rows[index].state = state
            self.step(rest)
        }
        if preview {
            // Sample outcomes for the hook; no command runs.
            let failure = update.id == "codex"
                ? "npm error code EACCES\nnpm error syscall rename\nnpm error path /usr/local/lib/node_modules/@openai/codex\nnpm error errno -13\nnpm error Error: EACCES: permission denied"
                : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                finish(failure.map(RowState.failed) ?? .done)
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = AgentUpdateRunner.execute(update.command)
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let state: RowState = result.status == 0 ? .done
                : .failed(detail.isEmpty ? "\(update.command) exited with status \(result.status)." : detail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(state) }
            }
        }
    }

    private func complete() {
        let ran = rows.filter { $0.state != .idle }
        let failures = ran.compactMap { row -> String? in
            if case .failed(let error) = row.state { return "\(row.update.displayName): \(error)" }
            return nil
        }
        if !preview, ran.contains(where: { $0.state == .done }) {
            AgentDiscoveryStore.shared.scan()
            let done = Set(ran.filter { $0.state == .done }.map(\.id))
            waiting.removeAll { done.contains($0.id) }
        }
        if failures.isEmpty {
            phase = .choosing
            presented = false
            hidden = false
            preview = false
            let names = ran.map(\.update.displayName)
            ToastCenter.shared.succeed(nil, names.count == 1 ? "Updated \(names[0])" : "Updated \(names.count) agents",
                                       detail: names.count == 1 ? nil : names.joined(separator: ", "))
            return
        }
        phase = .finished
        expandedError = rows.first { if case .failed = $0.state { return true } else { return false } }?.id
        if hidden {
            hidden = false
            ToastCenter.shared.fail(nil, failures.count == 1 ? "An agent update didn't finish" : "Some agent updates didn't finish",
                                    detail: failures.joined(separator: "\n"),
                                    action: .init(title: "Show") { AgentUpdateCenter.shared.reveal() })
        }
    }

    /// Brings back a dialog that was hidden while it ran.
    func reveal() {
        guard !rows.isEmpty else { return }
        hidden = false
        window = MainWindow.isKey ? NSApp.keyWindow : nil
        presented = true
    }

    // MARK: Preview

    #if DEBUG
    /// Verification hook (OCTET_OPEN_WINDOW=agent-updates-preview): the
    /// dialog with sample updates. Updating plays out sample outcomes, one
    /// of them a failure; no command ever runs and nothing is saved.
    /// ":run" starts updating straight away, to see the progress rows.
    func showPreview(stage: String? = nil) {
        present([
            AgentUpdate(id: "claude", displayName: "Claude Code", current: "2.4.1", latest: "2.5.0", command: "claude update"),
            AgentUpdate(id: "codex", displayName: "Codex", current: "0.98.0", latest: "0.99.0-beta.2", command: "codex update"),
            AgentUpdate(id: "opencode", displayName: "OpenCode", current: "0.15.2", latest: "0.15.8", command: "opencode upgrade"),
        ])
        preview = true
        if stage == "run" { primary() }
    }
    #endif
}

enum AgentUpdateRunner {
    /// Runs an update command in the person's login shell, as they would.
    nonisolated static func execute(_ command: String) -> (status: Int32, output: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data.suffix(2_000), as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
