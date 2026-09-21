import Foundation

/// How Claude and Codex are signed in, and how much of a subscription's
/// allowance is used. Subscriptions show allowance; API-key accounts show
/// cost. Checked at launch and every few minutes through each CLI, and
/// updated live from conversations' rate-limit events.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [String: AgentAccount] = [:]
    private var timer: Timer?
    private static let savedKey = "octet.accounts.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode([String: AgentAccount].self, from: data) {
            accounts = saved
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { AccountStore.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A conversation's stream reported Claude's plan windows.
    func updateClaudeWindows(_ windows: [UsageWindow]) { update("claude", windows) }

    /// A Codex conversation reported the account's windows mid-turn.
    func updateCodexWindows(_ windows: [UsageWindow]) { update("codex", windows) }

    private func update(_ agent: String, _ windows: [UsageWindow]) {
        var account = accounts[agent] ?? AgentAccount(agent: agent, kind: .subscription)
        account.windows = windows
        account.updatedAt = Date()
        set(account)
    }

    func refresh() {
        // Read here, on the main actor, and handed to the background work.
        let askAccount = SettingsStore.shared.values.readClaudeAccountUsage
        DispatchQueue.global(qos: .utility).async {
            var found: [AgentAccount] = []
            var refusal: String?
            // The CLI doesn't report windows, so they come from the account
            // itself (when allowed) or Claude Code's cache; `merge` keeps a
            // fresher stream's over either.
            if let output = Self.run("claude auth status") {
                var claude = AgentAccounts.claude(authStatus: Data(output.utf8))
                if claude.kind == .subscription {
                    let reading = ClaudeUsage.read(askAccount: askAccount)
                    refusal = reading.refusal
                    if let (windows, at) = reading.windows {
                        claude.windows = windows
                        claude.updatedAt = at
                    }
                }
                found.append(claude)
            }
            if let output = Self.run("codex login status") {
                var codex = AgentAccounts.codex(loginStatus: output)
                if codex.kind == .subscription, let (windows, at) = CodexUsage.windows() {
                    codex.windows = windows
                    codex.updatedAt = at
                }
                found.append(codex)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    found.forEach { AccountStore.shared.merge($0) }
                    if let refusal { AccountStore.shared.stopAskingAccount(refusal) }
                }
            }
        }
    }

    /// Asking the account can't work until something changes, so the switch
    /// goes off rather than retrying every five minutes, and says why once.
    private func stopAskingAccount(_ reason: String) {
        guard SettingsStore.shared.values.readClaudeAccountUsage else { return }
        SettingsStore.shared.values.readClaudeAccountUsage = false
        ToastCenter.shared.info("Stopped reading live usage from your Claude account",
                                detail: "\(reason) The chip uses Claude Code's cache instead. You can turn it back on in Settings.")
    }

    /// The switch was turned on: ask now rather than in five minutes, and
    /// let this read show the keychain dialog, since the person just asked.
    func accountUsageSettingChanged() {
        ClaudeUsage.allowPrompt()
        refresh()
    }

    /// Takes a refreshed account, keeping the windows already known when it
    /// brings none of its own. A refresh runs in a shell and takes seconds, so
    /// without this a refresh that started before a stream reported windows
    /// would land afterwards and erase them. Windows are dropped when the way
    /// the account signs in changes, since they no longer describe it.
    private func merge(_ account: AgentAccount) {
        var merged = account
        if let known = accounts[account.agent], known.kind == merged.kind, !known.windows.isEmpty,
           merged.windows.isEmpty || (known.updatedAt ?? .distantPast) > (merged.updatedAt ?? .distantPast) {
            merged.windows = known.windows
            merged.updatedAt = known.updatedAt
        }
        set(merged)
    }

    private func set(_ account: AgentAccount) {
        guard accounts[account.agent] != account else { return }
        accounts[account.agent] = account
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    /// Runs a command through the login shell (the CLIs live on the user's
    /// PATH); nil when it's missing or fails.
    private nonisolated static func run(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 || text.lowercased().contains("not logged in") ? text : nil
    }
}
