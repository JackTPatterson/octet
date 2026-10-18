import Foundation

/// Warns about a prompt long enough to matter before it's sent, after T3
/// Code's prompt-length check. Tokens are estimated at four characters each,
/// close enough for English and code to say "this is a lot".
enum ComposerPromptLength {
    /// From here the composer notes the size under the message.
    static let noticeTokens = 8_000
    /// From here sending asks first (T3 Code refuses past 120,000 characters).
    static let confirmTokens = 30_000
    /// A nearly full context never makes a short prompt ask.
    static let minimumConfirmTokens = 2_000

    enum Verdict: Equatable {
        case fine
        /// Worth a note: about this many tokens.
        case long(tokens: Int)
        /// Worth asking before sending; `message` says why.
        case tooLong(tokens: Int, message: String)
    }

    static func estimatedTokens(_ text: String) -> Int {
        // UTF-16 length: cheap to take on every keystroke of a huge paste.
        (text.utf16.count + 3) / 4
    }

    /// How a prompt measures up. `contextLeft`, when the agent has said how
    /// much of its context window is free, lowers the bar to what fits.
    static func check(_ text: String, contextLeft: Int? = nil) -> Verdict {
        let tokens = estimatedTokens(text)
        let limit = min(confirmTokens, contextLeft.map { max(minimumConfirmTokens, $0) } ?? .max)
        if tokens >= limit {
            let size = CompactFormat.count(tokens)
            let message: String
            if let contextLeft, contextLeft <= tokens {
                message = "About \(size) tokens, more than the \(CompactFormat.count(contextLeft)) left in this conversation's context."
            } else {
                message = "About \(size) tokens. A prompt this long uses a large share of the model's context."
            }
            return .tooLong(tokens: tokens, message: message)
        }
        return tokens >= noticeTokens ? .long(tokens: tokens) : .fine
    }

    /// The note under the composer, or nil when there's nothing to say.
    static func notice(_ verdict: Verdict) -> String? {
        switch verdict {
        case .fine: nil
        case .long(let tokens): "Long prompt: about \(CompactFormat.count(tokens)) tokens"
        case .tooLong(_, let message): message
        }
    }
}
