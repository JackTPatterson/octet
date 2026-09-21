import Foundation
import LocalAuthentication
import Security

/// Claude's allowance, from the freshest source that answers.
///
/// Claude's CLI reports its windows only while a conversation streams, so on
/// its own the title bar would stay empty until you took a turn. These are the
/// standing sources, tried in order:
///
/// 1. `/api/oauth/usage`, the call Claude Code's own usage display makes,
///    signed with the token it keeps in the login keychain. Only when the
///    person turns on "Read live usage from your Claude account": it touches
///    another app's credential and an endpoint Anthropic doesn't document.
/// 2. `cachedUsageUtilization` in `~/.claude.json`, the answer Claude Code
///    kept the last time it asked. As old as its `fetchedAtMs` says.
/// 3. Nothing, and `AccountStore` keeps what it already had.
///
/// A running conversation reports newer windows than any of these, and wins in
/// `AccountStore.merge`.
enum ClaudeUsage {
    struct Reading {
        var windows: ([UsageWindow], Date)?
        /// Set when asking the account can't work until something changes,
        /// so the setting should turn itself off rather than keep trying.
        var refusal: String?
    }

    /// What asking the account came to.
    enum AccountAnswer {
        case windows([UsageWindow], Date)
        /// Worth another try later: offline, a timeout, a busy server, or no
        /// token right now (Claude Code refreshes its own).
        case unavailable
        /// Won't work until something changes: the keychain prompt was
        /// declined, or the endpoint refuses or is gone.
        case refused(String)
    }

    static func read(askAccount: Bool) -> Reading {
        var reading = Reading()
        if askAccount {
            switch fromAccount() {
            case .windows(let windows, let at): reading.windows = (windows, at)
            case .unavailable: break
            case .refused(let reason): reading.refusal = reason
            }
        }
        reading.windows = reading.windows ?? fromCache()
        return reading
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static func fromAccount() -> AccountAnswer {
        let token: String
        let fresh: Bool
        switch self.token() {
        case .token(let value, let isFresh): (token, fresh) = (value, isFresh)
        case .missing: return .unavailable
        case .declined: return .refused("Keychain access to Claude Code's sign-in was declined.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        // Called from `AccountStore`'s background queue, where waiting is fine.
        var payload: Data?
        var status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            payload = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)

        switch status {
        case 200?:
            guard let payload, let json = try? JSONSerialization.jsonObject(with: payload) else { return .unavailable }
            let windows = AgentAccounts.claudeWindows(utilization: json)
            return windows.isEmpty ? .unavailable : .windows(windows, Date())
        case 401?, 403?:
            // A held token may simply have been rotated by Claude Code: drop
            // it and read a fresh one next time. Only a token straight from
            // the keychain being refused means this won't work.
            forgetToken()
            return fresh ? .refused("Your Claude account didn't accept the request (\(status!)).") : .unavailable
        case 404?, 410?:
            return .refused("The usage endpoint is gone (\(status!)); Anthropic may have changed it.")
        default:
            // Offline, a timeout, rate limited, or a server error.
            return .unavailable
        }
    }

    private static func fromCache() -> ([UsageWindow], Date)? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cached = json["cachedUsageUtilization"],
              let (windows, fetched) = AgentAccounts.claudeWindows(cachedUsage: cached) else { return nil }
        // A cache with no date is of unknown age; treat it as just read, and
        // let the windows' own reset times retire it.
        return (windows, fetched ?? Date())
    }

    private enum Token {
        /// `fresh` when just read from the keychain rather than held.
        case token(String, fresh: Bool)
        /// Not signed in through the keychain, or the token has run out;
        /// Claude Code refreshes its own in place.
        case missing
        /// The person answered the keychain prompt with Deny.
        case declined
    }

    /// The token, held in memory for as long as it's good, so the keychain is
    /// read about once a launch instead of on every five-minute refresh. It is
    /// never written anywhere: it's Claude Code's credential, not Octet's.
    private static var held: (token: String, expiresAt: Date?)?
    /// Whether a read may still put the keychain dialog up. The first read of
    /// a launch may, and so may one right after the person turns the setting
    /// on; after that, reads ask macOS not to show UI, so a timer can't put a
    /// dialog in front of you.
    private static var mayPrompt = true
    private static let lock = NSLock()

    /// The person just turned the setting on: the next read may ask.
    static func allowPrompt() {
        lock.lock()
        mayPrompt = true
        lock.unlock()
    }

    /// The account refused the token; read a fresh one next time.
    private static func forgetToken() {
        lock.lock()
        held = nil
        lock.unlock()
    }

    /// Claude Code's OAuth token: the one held, else from the login keychain
    /// item Claude Code writes. Octet only reads it, and macOS asks first.
    private static func token() -> Token {
        lock.lock()
        defer { lock.unlock() }
        // A minute's margin, so a token isn't sent in its last seconds.
        if let held, held.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return .token(held.token, fresh: false)
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !mayPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        mayPrompt = false

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // Cancel and Deny on the prompt are answers. A locked keychain, or a
        // read that wasn't allowed to show UI (errSecInteractionNotAllowed),
        // is not, and is tried again later.
        if status == errSecUserCanceled || status == errSecAuthFailed { return .declined }
        guard status == errSecSuccess,
              let data = item as? Data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return .missing }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        // Claude Code refreshes an expired token in place; until it does,
        // there's nothing to hold.
        if let expiresAt, expiresAt < Date() { return .missing }
        held = (token, expiresAt)
        return .token(token, fresh: true)
    }
}
