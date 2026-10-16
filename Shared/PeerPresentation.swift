import Foundation

/// What the Other Macs screens say about a paired Mac, after T3 Code's
/// Connections settings: one quiet status line per machine ("Online · 3
/// agents", "Last seen 2h ago"), and a failure sorted into something the
/// person can act on rather than a raw error. Pure, so the wording is tested
/// once and the Settings rows, the Peer window and the menu all agree.
enum PeerPresentation {
    /// How a status reads at a glance: the dot's colour and the text's.
    enum Tone: Equatable {
        case online
        case idle
        case warning
        case error
    }

    struct Status: Equatable {
        let text: String
        let tone: Tone
    }

    // MARK: - Why a request failed

    /// A failed request to another Mac, sorted by what to do about it. The
    /// app passes the remote error's code where it has one; older answers
    /// carry only a message, so the message is read too.
    enum Issue: Equatable {
        /// Other Macs is off on this Mac.
        case off
        /// Nothing answered: Octet closed there, Other Macs off, asleep, or
        /// another network.
        case offline
        /// It answered once, then went quiet.
        case timedOut
        /// The person at that Mac said no.
        case refused
        /// Its Octet doesn't know the request: it needs updating.
        case versionTooOld
        /// It answered with another key than it paired with.
        case identityChanged
        /// It doesn't know this Mac (forgotten there).
        case notPaired
        case other(String)

        init(code: String?, message: String) {
            let text = message.lowercased()
            switch code {
            case PeerProtocol.ErrorCode.declined.rawValue:
                self = .refused
                return
            case PeerProtocol.ErrorCode.badRequest.rawValue where text.hasPrefix("unknown request"):
                self = .versionTooOld
                return
            default:
                break
            }
            if text.contains("other macs is off") {
                self = .off
            } else if text.contains("isn't reachable") || text.contains("connection refused")
                        || text.contains("host is down") || text.contains("no route to host") {
                self = .offline
            } else if text.hasPrefix("no answer within") || text.contains("timed out") {
                self = .timedOut
            } else if text.contains("declined") {
                self = .refused
            } else if text.hasPrefix("unknown request") {
                self = .versionTooOld
            } else if text.contains("different identity") {
                self = .identityChanged
            } else if text.contains("isn't paired") {
                self = .notPaired
            } else {
                self = .other(message)
            }
        }

        /// Two or three words for a status line.
        var title: String {
            switch self {
            case .off: "Other Macs is off"
            case .offline: "Offline"
            case .timedOut: "Not answering"
            case .refused: "Declined"
            case .versionTooOld: "Needs a newer Octet"
            case .identityChanged: "Key changed"
            case .notPaired: "Not paired there"
            case .other: "Couldn't reach it"
            }
        }

        /// What to do, naming the machine.
        func advice(machine: String) -> String {
            switch self {
            case .off:
                "Turn on Talk to Other Macs in Settings › Other Macs."
            case .offline:
                "Open Octet on \(machine) with Other Macs on, on this network or your tailnet."
            case .timedOut:
                "\(machine) stopped answering. It may be asleep or busy; try again in a moment."
            case .refused:
                "The person at \(machine) declined. Ask them, or let \(machine) do more in its trust setting there."
            case .versionTooOld:
                "\(machine) runs an older Octet that doesn't know this request. Update Octet there."
            case .identityChanged:
                "\(machine) answered with a different key than it paired with. If Octet was reinstalled there, forget it and pair again."
            case .notPaired:
                "\(machine) has forgotten this Mac. Forget it here and pair again."
            case .other(let message):
                message
            }
        }

        var tone: Tone {
            switch self {
            case .offline, .off: .idle
            case .timedOut, .versionTooOld, .notPaired: .warning
            case .refused, .identityChanged, .other: .error
            }
        }
    }

    // MARK: - Status lines

    /// A paired Mac's line: an issue wins, then online with its agents and
    /// version, then when it was last seen.
    static func status(online: Bool, agents: Int?, issue: Issue?, lastSeen: Date?,
                       remoteVersion: String? = nil, localVersion: String? = nil, now: Date = Date()) -> Status {
        // A stale "offline" from an earlier request gives way once it's back.
        if let issue, !(issue == .offline && online) {
            if issue == .offline { return Status(text: lastSeenText(lastSeen, now: now), tone: .idle) }
            return Status(text: issue.title, tone: issue.tone)
        }
        guard online else { return Status(text: lastSeenText(lastSeen, now: now), tone: .idle) }
        var parts = ["Online"]
        if let agents { parts.append(agentCount(agents)) }
        if let remoteVersion, let localVersion, isOlder(remoteVersion, than: localVersion) {
            parts.append("Octet \(remoteVersion)")
            return Status(text: parts.joined(separator: " · "), tone: .warning)
        }
        return Status(text: parts.joined(separator: " · "), tone: .online)
    }

    static func agentCount(_ count: Int) -> String {
        switch count {
        case 0: "No agents"
        case 1: "1 agent"
        default: "\(count) agents"
        }
    }

    /// "Last seen 2h ago", coarse on purpose: the dot already says whether
    /// it's here now, and a ticking seconds count would only fidget.
    static func lastSeenText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Not seen yet" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "Last seen just now"
        case ..<3600: return "Last seen \(Int(seconds / 60))m ago"
        case ..<86_400: return "Last seen \(Int(seconds / 3600))h ago"
        default: break
        }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
            return "Last seen yesterday"
        }
        if seconds < 7 * 86_400 { return "Last seen \(max(2, Int(seconds / 86_400))) days ago" }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US"))
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let text = sameYear ? date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
            : date.formatted(style)
        return "Last seen \(text)"
    }

    /// A round trip, as people read it: "8 ms", "1.2 s".
    static func latency(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 1 { return "<1 ms" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }

    /// Whether `version` comes before `other`, comparing numbers part by
    /// part ("0.10.0" is after "0.9.2"); anything after a dash or space is
    /// ignored.
    static func isOlder(_ version: String, than other: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            let core = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "+" }).first.map(String.init) ?? text
            return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let a = parts(version), b = parts(other)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: - This Mac

    /// What to type on another Mac: "studio.local:52100", "[fe80::1]:52100".
    static func address(host: String?, port: UInt16?) -> String? {
        guard var host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty, let port else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return "\(host):\(port)"
    }

    // MARK: - Tasks and agents

    /// A delegated task's state, from the status the other Mac reports.
    static func taskStatus(_ raw: String) -> Status {
        switch raw {
        case "working": Status(text: "Working", tone: .online)
        case "done", "idle": Status(text: "Done", tone: .online)
        case "closed": Status(text: "Tab closed there", tone: .idle)
        case "blocked": Status(text: "Waiting on someone there", tone: .warning)
        default: Status(text: raw.prefix(1).uppercased() + raw.dropFirst(), tone: .idle)
        }
    }

    /// An agent's state on another Mac, as a word.
    static func agentStatus(_ raw: String) -> String {
        switch raw {
        case "working": "Working"
        case "blocked": "Needs input"
        case "done": "Done"
        case "idle": "Idle"
        default: "Unknown"
        }
    }

    /// How long a task has run: "45s", "3m", "1h 20m".
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }

    /// A pairing that didn't finish, said plainly.
    static func pairingFailure(_ message: String, machine: String?) -> String {
        let name = machine ?? "That Mac"
        let text = message.lowercased()
        if text.contains("declined") { return "\(name) didn't pair: someone said no, or the codes didn't match." }
        if text.contains("connection refused") || text.contains("isn't reachable") || text.contains("host is down")
            || text.contains("no route") {
            return "Nothing answered at that address. Is Octet open on \(name), with Other Macs on?"
        }
        if text.contains("timed out") || text.contains("didn't confirm") {
            return "\(name) didn't confirm in time. Try again, and compare the codes on both screens."
        }
        if text.contains("connection closed") { return "\(name) closed the connection before pairing finished." }
        if text.contains("host:port") { return "Give the address as host:port, e.g. studio.local:52100." }
        return message
    }
}

/// The steps of pairing two Macs, as the Pair a Mac dialog walks them:
/// pick a Mac, compare the code both screens show, done. Pure, so each
/// arrival (a code, the other side's answer, a failure) moves it the same
/// way whoever started the pairing.
enum PeerPairingStep: Equatable {
    /// Pick a nearby Mac or type an address.
    case choose
    /// Reaching it, before any code.
    case connecting(machine: String)
    /// Both screens show `code`; the person says whether they match.
    case confirm(machine: String, code: String, fingerprint: String, incoming: Bool)
    /// This side said yes; the other side hasn't yet.
    case waiting(machine: String)
    case paired(machine: String)
    case failed(machine: String?, reason: String)

    /// The headings over the dialog, one per stage.
    static let stages = ["Choose a Mac", "Compare Codes", "Paired"]

    /// Which of `stages` this step belongs to.
    var stage: Int {
        switch self {
        case .choose: 0
        case .connecting, .confirm, .waiting: 1
        case .paired, .failed: 2
        }
    }

    var machine: String? {
        switch self {
        case .choose: nil
        case .connecting(let machine), .waiting(let machine), .paired(let machine): machine
        case .confirm(let machine, _, _, _): machine
        case .failed(let machine, _): machine
        }
    }

    /// Whether closing the dialog now should answer a waiting code with no.
    var awaitsAnswer: Bool {
        if case .confirm = self { return true }
        return false
    }

    var isFinished: Bool {
        switch self {
        case .paired, .failed: true
        default: false
        }
    }

    /// A code arrived for `machine`. A code for another Mac while one is
    /// already being compared is left for later rather than swapped in.
    func receivedCode(machine: String, code: String, fingerprint: String, incoming: Bool) -> PeerPairingStep {
        if case .confirm = self { return self }
        return .confirm(machine: machine, code: code, fingerprint: fingerprint, incoming: incoming)
    }

    /// The person answered the code shown.
    func answered(_ accept: Bool) -> PeerPairingStep {
        guard case .confirm(let machine, _, _, _) = self else { return self }
        return accept ? .waiting(machine: machine) : .failed(machine: machine, reason: "You didn't pair with \(machine).")
    }

    /// The pairing finished, one way or the other.
    func finished(machine: String?, error: String?) -> PeerPairingStep {
        let name = machine ?? self.machine
        guard let error else { return .paired(machine: name ?? "That Mac") }
        return .failed(machine: name, reason: PeerPresentation.pairingFailure(error, machine: name))
    }
}
