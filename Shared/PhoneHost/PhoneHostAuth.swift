import CryptoKit
import Foundation

/// Who may talk to the phone host: one-time pairing codes, bearer tokens for
/// paired phones, and single-use tickets for the WebSocket upgrade. Tokens and
/// codes are kept only as hashes.
final class PhoneAuthStore {
    /// The permissions this host can honor today. A phone asking for more
    /// (filesystem, providers, settings) is granted the overlap, not refused.
    static let supportedScopes = ["orchestration:read", "orchestration:operate", "terminal:read", "terminal:operate"]
    static let pairingLifetime: TimeInterval = 5 * 60
    static let sessionLifetime: TimeInterval = 90 * 24 * 60 * 60
    static let ticketLifetime: TimeInterval = 60
    /// Wrong codes tolerated before exchanges pause.
    static let failureLimit = 8
    static let lockout: TimeInterval = 30

    struct Session: Codable, Equatable {
        var id: String
        var label: String
        var deviceType: String
        var os: String?
        var scopes: [String]
        var issuedAt: Date
        var expiresAt: Date
        var tokenHash: String
    }

    struct Pairing {
        var id: String
        var credential: String
        var label: String?
        var expiresAt: Date
    }

    enum ExchangeError: Error, Equatable {
        case invalidCredential
        /// Too many wrong codes recently.
        case locked
        case invalidScope
    }

    struct Ticket {
        var session: Session
        var use: String?
    }

    private struct PendingPairing {
        var id: String
        var label: String?
        var scopes: [String]
        var expiresAt: Date
    }

    private struct IssuedTicket {
        var sessionID: String
        var use: String?
        var expiresAt: Date
    }

    private let lock = NSLock()
    private let url: URL?
    private var sessions: [Session] = []
    /// Keyed by the hash of the code.
    private var pairings: [String: PendingPairing] = [:]
    private var tickets: [String: IssuedTicket] = [:]
    private var failures = 0
    private var lockedUntil = Date.distantPast

    /// `url` keeps paired phones across launches; nil keeps them in memory.
    init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = (try? decoder.decode([Session].self, from: data)) ?? []
        }
    }

    // MARK: - Pairing

    /// A code to type or scan once on the phone.
    func createPairing(label: String? = nil, scopes: [String]? = nil, now: Date = Date()) -> Pairing {
        let credential = Self.randomCode()
        let pairing = PendingPairing(id: Self.randomID(), label: label,
                                     scopes: Self.grant(scopes ?? Self.supportedScopes),
                                     expiresAt: now.addingTimeInterval(Self.pairingLifetime))
        lock.withLock {
            pairings = pairings.filter { $0.value.expiresAt > now }
            pairings[Self.hash(credential)] = pairing
        }
        return Pairing(id: pairing.id, credential: credential, label: label, expiresAt: pairing.expiresAt)
    }

    /// Trades a pairing code for a bearer token. The code is spent on success.
    func exchange(credential: String, requestedScopes: [String]?, label: String?, deviceType: String?, os: String?,
                  now: Date = Date()) -> Result<(token: String, session: Session), ExchangeError> {
        lock.lock()
        defer { lock.unlock() }
        if lockedUntil > now { return .failure(.locked) }
        let key = Self.hash(credential.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        guard let pairing = pairings[key], pairing.expiresAt > now else {
            failures += 1
            if failures >= Self.failureLimit {
                failures = 0
                lockedUntil = now.addingTimeInterval(Self.lockout)
            }
            return .failure(.invalidCredential)
        }
        var scopes = pairing.scopes
        if let requestedScopes {
            guard !requestedScopes.isEmpty else { return .failure(.invalidScope) }
            scopes = scopes.filter(requestedScopes.contains)
            guard !scopes.isEmpty else { return .failure(.invalidScope) }
        }
        pairings[key] = nil
        failures = 0

        let token = Self.randomToken()
        let session = Session(id: Self.randomID(), label: label ?? pairing.label ?? "Phone", deviceType: deviceType ?? "unknown",
                              os: os, scopes: scopes, issuedAt: now,
                              expiresAt: now.addingTimeInterval(Self.sessionLifetime), tokenHash: Self.hash(token))
        sessions.append(session)
        persistLocked()
        return .success((token, session))
    }

    // MARK: - Sessions

    func session(bearer token: String, now: Date = Date()) -> Session? {
        let hash = Self.hash(token)
        return lock.withLock { sessions.first { $0.tokenHash == hash && $0.expiresAt > now } }
    }

    func allSessions() -> [Session] { lock.withLock { sessions } }

    @discardableResult
    func revoke(sessionID: String) -> Bool {
        lock.withLock {
            let before = sessions.count
            sessions.removeAll { $0.id == sessionID }
            tickets = tickets.filter { $0.value.sessionID != sessionID }
            guard sessions.count != before else { return false }
            persistLocked()
            return true
        }
    }

    func revokeAll() {
        lock.withLock {
            sessions = []
            tickets = [:]
            persistLocked()
        }
    }

    // MARK: - WebSocket tickets

    /// `use` is "rpc" or "media"; nil is the older unbound ticket.
    func issueTicket(for session: Session, use: String?, now: Date = Date()) -> (ticket: String, expiresAt: Date) {
        let ticket = Self.randomToken()
        let expiresAt = now.addingTimeInterval(Self.ticketLifetime)
        lock.withLock {
            tickets = tickets.filter { $0.value.expiresAt > now }
            tickets[Self.hash(ticket)] = IssuedTicket(sessionID: session.id, use: use, expiresAt: expiresAt)
        }
        return (ticket, expiresAt)
    }

    /// Spends a ticket. A ticket bound to one use does not open another.
    func consumeTicket(_ ticket: String, use: String, now: Date = Date()) -> Session? {
        lock.withLock {
            let key = Self.hash(ticket)
            guard let issued = tickets.removeValue(forKey: key), issued.expiresAt > now,
                  issued.use == nil || issued.use == use else { return nil }
            return sessions.first { $0.id == issued.sessionID && $0.expiresAt > now }
        }
    }

    // MARK: - Helpers

    /// What the phone is granted out of what it asked for.
    static func grant(_ requested: [String]) -> [String] {
        supportedScopes.filter(requested.contains)
    }

    private func persistLocked() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "the system random source failed")
        return bytes
    }

    static func randomToken() -> String {
        Data(randomBytes(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomID() -> String { UUID().uuidString.lowercased() }

    /// 16 characters from Crockford's alphabet: 80 bits, no look-alikes, easy to read aloud.
    static func randomCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return String(randomBytes(16).map { alphabet[Int($0) % alphabet.count] })
    }
}
