import Foundation

/// Agents answer in markdown, and a terminal can only approximate it. The
/// twin draws it properly, which starts with splitting fenced code out of the
/// prose around it.
enum TwinMarkdown {
    enum Segment: Equatable {
        case prose(String)
        case code(language: String, text: String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(.code(language: language, text: code.joined(separator: "\n")))
                    code.removeAll()
                    language = ""
                    inCode = false
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        // An unterminated fence is still code: the agent is mid-answer.
        if inCode, !code.isEmpty {
            segments.append(.code(language: language, text: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments
    }
}
