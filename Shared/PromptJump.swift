import Foundation

/// ⌘↑ / ⌘↓ between the prompts in a shell pane's scrollback. The session
/// server keeps no prompt marks, so prompts are found by their shape: lines
/// that begin like the prompt now showing at the bottom.
enum PromptJump {
    static let promptCharacters: Set<Character> = ["%", "$", "#", "❯", ">", "➜", "λ"]

    /// Rows (from the top of the scrollback) that are prompts.
    static func promptRows(_ lines: [String]) -> [Int] {
        guard let current = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let token = current.split(separator: " ").first.map(String.init),
              current.contains(where: promptCharacters.contains) else { return [] }
        return lines.indices.filter { index in
            let line = lines[index]
            return (line == token || line.hasPrefix(token + " ")) && line.contains(where: promptCharacters.contains)
        }
    }

    enum Direction { case up, down }

    /// The scroll offset that puts the next prompt above or below the top of
    /// the view at the top, or nil when there isn't one. Past the last prompt
    /// going down is the bottom.
    static func offset(_ direction: Direction, rows: [Int], currentOffset: Int, total: Int, viewport: Int) -> Int? {
        let maxOffset = max(0, total - viewport)
        let top = total - viewport - currentOffset
        let offset = { (row: Int) in min(maxOffset, max(0, total - viewport - row)) }
        switch direction {
        case .up:
            guard let row = rows.last(where: { $0 < top }) else { return nil }
            return offset(row)
        case .down:
            guard currentOffset > 0 else { return nil }
            return rows.first(where: { $0 > top }).map(offset) ?? 0
        }
    }
}
