import Foundation

/// Codex's allowance, from the freshest source that answers.
///
/// Codex reports its windows as it works, so on its own the title bar would
/// show whatever the last turn happened to say, however old. These are the
/// standing sources, tried in order:
///
/// 1. `account/rateLimits/read` on `codex app-server`, the CLI's own JSON-RPC
///    surface. It answers for the account as it stands, and the CLI carries
///    its own credentials, so Octet handles no token of its own.
/// 2. The `rate_limits` records Codex writes into its session logs, which are
///    only as new as the last turn that wrote one.
/// 3. Nothing, and `AccountStore` keeps what it already had.
enum CodexUsage {
    /// The windows and when the reading was taken, or nil when no source answered.
    static func windows() -> ([UsageWindow], Date)? {
        if let live = fromAppServer() { return (live, Date()) }
        return fromSessionLogs()
    }

    private static func fromAppServer() -> [UsageWindow]? {
        let answers = CodexRPC.ask([CodexRPC.Call(id: 2, method: "account/rateLimits/read")])
        guard let limits = answers[2]?["rateLimits"] as? [String: Any] else { return nil }
        let windows = AgentAccounts.codexWindows(rateLimits: limits)
        return windows.isEmpty ? nil : windows
    }

    /// The newest session log that recorded Codex's windows, and when.
    private static func fromSessionLogs() -> ([UsageWindow], Date)? {
        let root = NSHomeDirectory() + "/.codex/sessions"
        let manager = FileManager.default
        let files = (manager.enumerator(atPath: root)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .map { root + "/" + $0 }
            .compactMap { path -> (String, Date)? in
                guard let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .sorted { $0.1 > $1.1 }
        for (path, date) in files.prefix(60) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let windows = AgentAccounts.codexWindows(sessionLines: text.components(separatedBy: "\n")) else { continue }
            return (windows, date)
        }
        return nil
    }
}
