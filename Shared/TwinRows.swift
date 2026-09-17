import Foundation

/// The conversation flattened into what the twin actually draws: a tool call
/// and the result that came back are one row, not two, and the bookkeeping
/// messages agents write around them never appear at all.
struct TwinRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case thinking(String)
        /// A shell command and what it printed, the way both agents show it.
        case command(command: String, output: String, isError: Bool)
        /// An edit, as the lines that changed.
        case diff(TwinDiff, result: String)
        /// The plan an agent is keeping as it works.
        case todos([TwinTodo])
        case tool(name: String, summary: String, result: String, isError: Bool)
    }

    let id: String
    let kind: Kind
    var at: Date?

    var isTool: Bool {
        switch kind {
        case .tool, .command, .diff, .todos: true
        case .user, .assistant, .thinking: false
        }
    }
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
                    let output = result?.summary ?? ""
                    let isError = result?.isError ?? false
                    // What the call was doing decides how it is drawn, which
                    // is how the agents' own interfaces work.
                    let kind: TwinRow.Kind
                    switch conversation.details[callId] {
                    case .command(let command):
                        kind = .command(command: command, output: output, isError: isError)
                    case .diff(let diff):
                        kind = .diff(diff, result: output)
                    case .todos(let todos):
                        kind = .todos(todos)
                    default:
                        kind = .tool(name: name, summary: summary, result: output, isError: isError)
                    }
                    rows.append(TwinRow(id: id, kind: kind, at: message.at))
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
