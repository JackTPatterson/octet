import Foundation

/// Hold Space to talk: a tap types a space as always; held past a moment,
/// the space it typed is taken back and listening starts, until it's let go.
struct SpaceHold {
    /// Held this long, it's talking rather than typing.
    static let threshold: TimeInterval = 0.35

    enum Action: Equatable {
        /// Let the key through: a space.
        case type
        /// Eat the key: listening, or a repeat while it is.
        case swallow
        /// Start listening, with the text put back as it was before the
        /// key went down (its spaces taken back).
        case startListening(restore: String)
        case stopListening
    }

    private(set) var downAt: Date?
    private var textAtDown: String?
    private(set) var listening = false

    mutating func down(at date: Date, text: String) -> Action {
        if listening { return .swallow }
        downAt = date
        textAtDown = text
        return .type
    }

    /// The key repeating while held.
    mutating func repeated(at date: Date) -> Action {
        if listening { return .swallow }
        guard let downAt, let textAtDown, date.timeIntervalSince(downAt) >= Self.threshold else { return .type }
        listening = true
        return .startListening(restore: textAtDown)
    }

    mutating func up() -> Action {
        defer {
            downAt = nil
            textAtDown = nil
        }
        guard listening else { return .type }
        listening = false
        return .stopListening
    }

    /// Listening couldn't start (no permission, no microphone).
    mutating func cancel() {
        listening = false
        downAt = nil
        textAtDown = nil
    }

    /// `text` with what was said added at its end, a space between.
    static func inserting(_ transcript: String, into text: String) -> String {
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return text }
        guard let last = text.last else { return said }
        return last.isWhitespace ? text + said : text + " " + said
    }
}
