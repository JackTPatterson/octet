import Foundation

/// A question an agent is asking on screen — "may I run this", "which of
/// these" — read off the terminal rather than from any one agent's API, so
/// the twin can answer it with buttons whoever is asking.
struct TwinApproval: Equatable {
    struct Option: Equatable, Identifiable {
        /// What to type to choose it.
        let key: String
        let label: String
        /// Whether choosing it lets the agent proceed, for colouring.
        var isAffirmative: Bool
        /// Whether the key needs a Return after it, as a letter answer does.
        var needsReturn: Bool
        var id: String { key + label }
    }

    /// The line above the choices, when there is one.
    let question: String
    /// What the agent is about to do, when the prompt shows it.
    var detail: String = ""
    let options: [Option]
}

enum TwinApprovals {
    /// Reads the visible screen and returns the question the agent is waiting
    /// on. Works on the shapes agents actually draw: a numbered menu, or a
    /// yes/no prompt.
    /// The whole visible screen is read, not just the foot of it: agents draw
    /// a prompt where the conversation reached, which on a tall pane is
    /// nowhere near the bottom.
    static func detect(screen: String, rows: Int = 200) -> TwinApproval? {
        let lines = screen.components(separatedBy: "\n").suffix(rows).map(clean)
        return numbered(lines) ?? yesNo(lines)
    }

    /// `1. Yes` / `❯ 2. No, tell Claude what to do differently`
    private static func numbered(_ lines: [String]) -> TwinApproval? {
        var options: [TwinApproval.Option] = []
        var firstIndex: Int?
        for (index, line) in lines.enumerated() {
            guard let option = option(in: line) else {
                // A blank line inside the menu is fine; anything else ends it.
                if !options.isEmpty, !line.isEmpty { options.removeAll(); firstIndex = nil }
                continue
            }
            // Menus restart at 1; a later one replaces what came before.
            if option.number == 1 { options.removeAll(); firstIndex = index }
            guard option.number == options.count + 1 else { continue }
            options.append(TwinApproval.Option(
                key: "\(option.number)",
                label: option.label,
                isAffirmative: affirmative(option.label),
                needsReturn: false
            ))
        }
        guard options.count >= 2, let firstIndex else { return nil }
        let (question, detail) = context(before: firstIndex, in: lines)
        return TwinApproval(question: question, detail: detail, options: options)
    }

    /// `Do you want to continue? (y/n)`
    private static func yesNo(_ lines: [String]) -> TwinApproval? {
        for (index, line) in lines.enumerated().reversed() {
            let lowered = line.lowercased()
            guard let range = lowered.range(of: "(y/n)") ?? lowered.range(of: "[y/n]")
                    ?? lowered.range(of: "(yes/no)") ?? lowered.range(of: "[y/n/a]") else { continue }
            var question = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if question.isEmpty { question = "The agent is asking for a yes or no." }
            let (_, detail) = context(before: index, in: lines)
            return TwinApproval(question: question, detail: detail, options: [
                .init(key: "y", label: "Yes", isAffirmative: true, needsReturn: true),
                .init(key: "n", label: "No", isAffirmative: false, needsReturn: true),
            ])
        }
        return nil
    }

    /// The question, and the context under it worth showing. Agents put the
    /// question first and what they are asking about beneath it, so a line
    /// that actually asks something outranks the line nearest the choices.
    private static func context(before index: Int, in lines: [String]) -> (question: String, detail: String) {
        var texts: [String] = []
        var cursor = index - 1
        while cursor >= 0, texts.count < 3 {
            let line = lines[cursor]
            cursor -= 1
            guard !line.isEmpty, option(in: line) == nil else { continue }
            texts.append(line)
        }
        guard !texts.isEmpty else { return ("The agent needs an answer.", "") }
        let asking = texts.firstIndex { $0.hasSuffix("?") } ?? 0
        let detail = texts.prefix(asking).reversed().joined(separator: " · ")
        return (texts[asking], detail)
    }

    /// `2. Yes, and don't ask again` → (2, "Yes, and don't ask again")
    private static func option(in line: String) -> (number: Int, label: String)? {
        var text = line
        // The cursor marker sits outside the number.
        for marker in ["❯", ">", "▸", "●", "•"] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first, first.isNumber else { return nil }
        let digits = text.prefix { $0.isNumber }
        guard let number = Int(digits), number >= 1, number <= 9 else { return nil }
        var rest = text.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count < 120 else { return nil }
        return (number, label)
    }

    /// Does this choice let the agent carry on?
    private static func affirmative(_ label: String) -> Bool {
        let lowered = label.lowercased()
        if lowered.hasPrefix("no") || lowered.contains("don't allow") || lowered.contains("cancel")
            || lowered.contains("reject") || lowered.contains("stop") { return false }
        return lowered.hasPrefix("yes") || lowered.hasPrefix("allow") || lowered.hasPrefix("approve")
            || lowered.hasPrefix("continue") || lowered.hasPrefix("proceed") || lowered.hasPrefix("accept")
    }

    /// Strips the box drawing agents frame their prompts in.
    static func clean(_ line: String) -> String {
        let drawing = CharacterSet(charactersIn: "│┃┆┇┊┋║╎╏|─━┄┈╌═╭╮╯╰┌┐└┘├┤┬┴┼╔╗╚╝ ")
        return line.trimmingCharacters(in: drawing).trimmingCharacters(in: .whitespaces)
    }
}
