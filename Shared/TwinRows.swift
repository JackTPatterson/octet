import Foundation

/// The conversation flattened into what the twin actually draws: a tool call
/// and the result that came back are one row, not two, and the bookkeeping
/// messages agents write around them never appear at all.
struct TwinRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case thinking(String)
        case tool(name: String, summary: String, result: String, isError: Bool)
    }

    let id: String
    let kind: Kind
    var at: Date?

    var isTool: Bool { if case .tool = kind { return true } else { return false } }
}

enum TwinRows {
    static func build(_ conversation: TwinConversation) -> [TwinRow] {
        // Results arrive after the call that asked for them, so they are
        // gathered first and then folded into their call.
        var results: [String: (summary: String, isError: Bool)] = [:]
        for message in conversation.messages {
            for block in message.blocks {
                if case .toolResult(let id, let summary, let isError) = block, !id.isEmpty {
                    results[id] = (summary, isError)
                }
            }
        }

        var rows: [TwinRow] = []
        for message in conversation.messages {
            for (index, block) in message.blocks.enumerated() {
                let id = "\(message.id)#\(index)"
                switch block {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !isNoise(trimmed) else { continue }
                    rows.append(TwinRow(id: id,
                                        kind: message.role == .user ? .user(trimmed) : .assistant(trimmed),
                                        at: message.at))
                case .thinking(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    rows.append(TwinRow(id: id, kind: .thinking(trimmed), at: message.at))
                case .toolCall(let callId, let name, let summary):
                    let result = results[callId]
                    rows.append(TwinRow(
                        id: id,
                        kind: .tool(name: name, summary: summary,
                                    result: result?.summary ?? "", isError: result?.isError ?? false),
                        at: message.at
                    ))
                case .toolResult:
                    // Shown on its call's row.
                    continue
                }
            }
        }
        return rows
    }

    /// Lines agents inject that are plumbing rather than conversation.
    static func isNoise(_ text: String) -> Bool {
        if text.hasPrefix("<") && text.contains(">") && text.count < 4_000 {
            // `<command-name>`, `<local-command-stdout>`, reminders.
            let tags = ["<command-name>", "<command-message>", "<local-command", "<system-reminder>",
                        "<user-prompt-submit-hook>", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]
            if tags.contains(where: text.hasPrefix) { return true }
        }
        return text.hasPrefix("Caveat: The messages below")
            || text.hasPrefix("[Request interrupted")
            || text == "(no content)"
    }
}
