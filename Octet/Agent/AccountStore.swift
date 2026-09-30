import AppKit

/// How Claude and Codex are signed in, and how much of a subscription's
/// allowance is used. Subscriptions show allowance; API-key accounts show
/// cost. How each is signed in is checked every few minutes through its CLI.
/// Both allowances are read every minute or two, when Octet comes forward,
/// when a chip is hovered and when a conversation's turn ends, and live from
/// conversations' rate-limit events.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [String: AgentAccount] = [:]
    @Published private(set) var history: [String: [UsageHistorySample]] = [:]
    /// Why the last read didn't come from the Claude account, when it didn't.
    @Published private(set) var claudeFallback: ClaudeUsage.Fallback?
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var lastSignInCheck = Date.distantPast
    private var lastAccountAsk = Date.distantPast
    private var lastCodexRead = Date.distantPast
    /// How often each part runs: the sign-in checks start a login shell each;
    /// the cache read is a file; the account is one request.
    private static let tick: TimeInterval = 60
    private static let signInEvery: TimeInterval = 300
    private static let askAccountEvery: TimeInterval = 120
    /// Each read starts `codex app-server`, so not on every tick.
    private static let codexEvery: TimeInterval = 120
    private static let savedKey = "octet.accounts.v1"
    private static let historyKey = "octet.accounts.history.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode([String: AgentAccount].self, from: data) {
            accounts = saved
            // Saved before Codex was always labelled Codex.
            if accounts["codex"]?.plan == "ChatGPT" { accounts["codex"]?.plan = "Codex" }
        }
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([String: [UsageHistorySample]].self, from: data) {
            history = saved
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh(force: true)
        let timer = Timer(timeInterval: Self.tick, repeats: true) { _ in
            MainActor.assumeIsolated { AccountStore.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Back at the keyboard is when a stale number would mislead.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AccountStore.shared.refreshSoon() } }
    }

    /// Someone is looking: read now, unless a read just ran.
    func refreshSoon() {
        guard Date().timeIntervalSince(lastRefresh) > 20 else { return }
        refresh(eager: true)
    }

    /// A conversation's stream reported Claude's plan windows.
    func updateClaudeWindows(_ windows: [UsageWindow]) { update("claude", windows) }

    /// A Codex conversation reported the account's windows mid-turn.
    func updateCodexWindows(_ windows: [UsageWindow]) { update("codex", windows) }

    private func update(_ agent: String, _ windows: [UsageWindow]) {
        var account = accounts[agent] ?? AgentAccount(agent: agent, kind: .subscription)
        account.windows = AgentAccounts.mergeWindows(newer: windows, older: account.windows)
        account.updatedAt = Date()
        set(account)
    }

    /// `force` checks everything now; `eager` asks the account sooner than
    /// its usual spacing, for someone looking at the chip.
    func refresh(force: Bool = false, eager: Bool = false) {
        guard !refreshing else { return }
        let now = Date()
        let checkSignIn = force || now.timeIntervalSince(lastSignInCheck) >= Self.signInEvery
        // Read here, on the main actor, and handed to the background work.
        let askAccount = SettingsStore.shared.values.readClaudeAccountUsage
            && (force || now.timeIntervalSince(lastAccountAsk) >= (eager ? 30 : Self.askAccountEvery))
        let readCodex = checkSignIn || now.timeIntervalSince(lastCodexRead) >= (eager ? 30 : Self.codexEvery)
        let knownClaude = accounts["claude"]
        let knownCodex = accounts["codex"]
        refreshing = true
        lastRefresh = now
        if checkSignIn { lastSignInCheck = now }
        if askAccount { lastAccountAsk = now }
        if readCodex { lastCodexRead = now }
        DispatchQueue.global(qos: .utility).async {
            var found: [AgentAccount] = []
            var refusal: String?
            var fallback: ClaudeUsage.Fallback?
            // How Claude is signed in: asked every few minutes, else as last
            // known. A failed check (not on the login shell's PATH, an older
            // CLI) keeps what was known rather than hiding the allowance.
            var claude: AgentAccount?
            if checkSignIn, let output = Self.run("claude auth status") {
                claude = AgentAccounts.claude(authStatus: Data(output.utf8))
            } else if let knownClaude {
                claude = AgentAccount(agent: "claude", kind: knownClaude.kind, plan: knownClaude.plan)
            } else {
                // Never checked successfully: the cache can still say.
                claude = AgentAccount(agent: "claude", kind: .unknown)
            }
            // The CLI doesn't report windows, so they come from the account
            // itself (when allowed) or Claude Code's cache; `merge` keeps a
            // fresher stream's over either.
            if var account = claude, account.kind == .subscription || account.kind == .unknown {
                let reading = ClaudeUsage.read(askAccount: askAccount)
                refusal = reading.refusal
                fallback = reading.fallback
                if let (windows, at) = reading.windows {
                    account.windows = windows
                    account.updatedAt = at
                    if account.kind == .unknown { account.kind = .subscription }
                }
                claude = account
            }
            if let claude { found.append(claude) }
            // Codex the same way: how it signs in every few minutes, its
            // allowance more often, from the account itself.
            var codex: AgentAccount?
            if checkSignIn, let output = Self.run("codex login status") {
                codex = AgentAccounts.codex(loginStatus: output)
            } else if readCodex, let knownCodex {
                codex = AgentAccount(agent: "codex", kind: knownCodex.kind, plan: knownCodex.plan)
            }
            if var account = codex, account.kind == .subscription, readCodex, let (windows, at) = CodexUsage.windows() {
                account.windows = windows
                account.updatedAt = at
                codex = account
            }
            if let codex { found.append(codex) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = AccountStore.shared
                    store.refreshing = false
                    found.forEach { store.merge($0) }
                    // Only a read that asked the account can say why it didn't answer.
                    if askAccount, store.claudeFallback != fallback { store.claudeFallback = fallback }
                    if !SettingsStore.shared.values.readClaudeAccountUsage, store.claudeFallback != nil {
                        store.claudeFallback = nil
                    }
                    if let refusal { store.stopAskingAccount(refusal) }
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

    /// The switch was turned on: ask now rather than in a few minutes, and
    /// let this read show the keychain dialog, since the person just asked.
    func accountUsageSettingChanged() {
        ClaudeUsage.allowPrompt()
        claudeFallback = nil
        refresh(force: true)
    }

    /// Turns live account reads on from the chip's card.
    func enableAccountUsage() {
        SettingsStore.shared.values.readClaudeAccountUsage = true
        accountUsageSettingChanged()
    }

    /// Takes a refreshed account, window by window: the newer reading's
    /// windows win, and the older one fills in any still running that the
    /// newer didn't mention. A refresh runs in a shell and takes seconds, so
    /// a refresh that started before a stream reported windows can land
    /// afterwards; and a stream may report only one window. Windows are
    /// dropped when the way the account signs in changes, since they no
    /// longer describe it.
    private func merge(_ account: AgentAccount) {
        var merged = account
        if let known = accounts[account.agent], known.kind == merged.kind, !known.windows.isEmpty {
            if merged.windows.isEmpty || (known.updatedAt ?? .distantPast) > (merged.updatedAt ?? .distantPast) {
                merged.windows = AgentAccounts.mergeWindows(newer: known.windows, older: merged.windows)
                merged.updatedAt = known.updatedAt
            } else {
                merged.windows = AgentAccounts.mergeWindows(newer: merged.windows, older: known.windows)
            }
        }
        set(merged)
    }

    private func set(_ account: AgentAccount) {
        record(account)
        guard accounts[account.agent] != account else { return }
        accounts[account.agent] = account
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    private func record(_ account: AgentAccount) {
        guard account.kind == .subscription, !account.windows.isEmpty else { return }
        let sample = UsageHistorySample(at: account.updatedAt ?? Date(), windows: account.windows)
        var samples = history[account.agent] ?? []
        if let last = samples.last {
            if last == sample { return }
            // Several windows can arrive in one event. Keep its final reading
            // rather than creating a zero-width spike in the graph.
            if abs(last.at.timeIntervalSince(sample.at)) < 1 {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
        } else {
            samples.append(sample)
        }
        let cutoff = Date().addingTimeInterval(-8 * 24 * 3600)
        samples = Array(samples.filter { $0.at >= cutoff }.suffix(2048))
        history[account.agent] = samples
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
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
        let read = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        do { try process.run() } catch { return nil }
        // A login shell that hangs (a stuck profile script) would otherwise
        // stall every refresh after it.
        if read.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 || text.lowercased().contains("not logged in") ? text : nil
    }
}
