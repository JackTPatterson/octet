import Foundation

/// A message sent from the twin that the agent hasn't written down yet.
/// Everything the twin shows comes from the agent's own session file, and an
/// agent writes a turn when it starts working on it — a second or two later.
/// Without this the message you just sent is nowhere.
struct TwinPendingMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let at: Date

    init(text: String, at: Date = Date(), id: String = UUID().uuidString) {
        self.id = id
        self.text = text
        self.at = at
    }
}

enum TwinPending {
    /// Drops the messages the agent has now written down, and the ones that
    /// are never going to arrive. A message sent twice is matched twice, so
    /// the second copy doesn't vanish with the first.
    static func settle(
        _ pending: [TwinPendingMessage],
        against rows: [TwinRow],
        now: Date = Date(),
        timeout: TimeInterval = 120
    ) -> [TwinPendingMessage] {
        var written: [String: Int] = [:]
        for row in rows {
            guard case .user(let text) = row.kind else { continue }
            written[key(text), default: 0] += 1
        }
        return pending.filter { message in
            let text = key(message.text)
            if let count = written[text], count > 0 {
                written[text] = count - 1
                return false
            }
            // An agent that never records it would otherwise leave the
            // message sitting there for the rest of the session.
            return now.timeIntervalSince(message.at) < timeout
        }
    }

    /// Agents reflow what you send them; the words are what identify it.
    private static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
