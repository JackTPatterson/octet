import Foundation

/// The commands the session server saw a pane's shell run (OSC 133 marks,
/// `pane.marks`): where each prompt and its output are, how it ended and
/// how long it took. Rows share `pane.read` "recent"'s and `pane.scroll`'s
/// coordinates.
struct PromptMark: Equatable {
    let promptRow: Int
    let outputRow: Int?
    let endRow: Int?
    let exitCode: Int?
    let startedAt: Date?
    let finishedAt: Date?
    let command: String?

    var finished: Bool { exitCode != nil && endRow != nil }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

struct PromptMarks: Equatable {
    let marks: [PromptMark]
    let totalRows: Int
    let viewportRows: Int

    /// From a `pane.marks` response.
    init?(response: [String: Any]) {
        guard let raw = response["marks"] as? [[String: Any]],
              let total = (response["total_rows"] as? NSNumber)?.intValue,
              let viewport = (response["viewport_rows"] as? NSNumber)?.intValue else { return nil }
        func int(_ object: [String: Any], _ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        func date(_ object: [String: Any], _ key: String) -> Date? {
            (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        marks = raw.compactMap { mark in
            guard let prompt = int(mark, "prompt_row") else { return nil }
            return PromptMark(promptRow: prompt, outputRow: int(mark, "output_row"), endRow: int(mark, "end_row"),
                              exitCode: int(mark, "exit_code"), startedAt: date(mark, "started_at_ms"),
                              finishedAt: date(mark, "finished_at_ms"), command: mark["command"] as? String)
        }
        totalRows = total
        viewportRows = viewport
    }

    /// The last command that has finished.
    var lastFinished: PromptMark? { marks.last(where: \.finished) }

    var promptRows: [Int] { marks.map(\.promptRow) }

    /// "✓ 1.2s", "✗ 1 · 340ms": a command's end, for a chip.
    static func summary(_ mark: PromptMark) -> String {
        let status = mark.exitCode == 0 ? "✓" : "✗ \(mark.exitCode ?? -1)"
        guard let duration = mark.duration else { return status }
        return status + (mark.exitCode == 0 ? " " : " · ") + format(duration)
    }

    static func format(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return minutes < 60 ? "\(minutes)m \(Int(seconds) % 60)s" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// The output rows of a command, from the pane's recent text read with
    /// `lines: totalRows` (row 0 first).
    static func output(of mark: PromptMark, in lines: [String]) -> String? {
        guard let from = mark.outputRow, let end = mark.endRow, from < end,
              from >= 0, end <= lines.count else { return nil }
        var rows = Array(lines[from..<end])
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        return rows.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }
}
