import Foundation

/// Agents inject blocks into the conversation that are addressed to
/// themselves — a subagent finishing, a hook firing, a reminder. Left alone
/// they land in the twin as a page of XML, which is exactly the kind of thing
/// an interface is supposed to spare you. The ones worth knowing about become
/// one quiet line; the rest are dropped.
enum TwinNotes {
    /// A line for this block, or nil when it isn't one Herd summarises.
    static func summarise(_ text: String) -> String? {
        guard text.hasPrefix("<task-notification>") else { return nil }
        let summary = tag("summary", in: text) ?? "A background agent finished"
        var line = summary
        if let status = tag("status", in: text), status != "completed" {
            line += " · \(status)"
        }
        if let result = tag("result", in: text), !result.isEmpty {
            line += " · \(TwinTranscript.condense(result, limit: 80))"
        }
        return line
    }

    /// The text inside `<name>…</name>`, if it is there.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
