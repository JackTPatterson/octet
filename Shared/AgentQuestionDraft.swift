import Foundation

/// The answers being put together for a question the agent asked, one item
/// at a time, as T3 Code's pending-input panel: options are picked (or a
/// number key picks one), a typed answer stands in for or adds to them, and
/// a single-choice pick moves on to the next item by itself.
struct AgentQuestionDraft: Equatable {
    let question: OpenCodeQuestion
    /// The item on show.
    private(set) var index = 0
    private(set) var picked: [Int: [String]] = [:]
    private(set) var typed: [Int: String] = [:]

    init(_ question: OpenCodeQuestion) {
        self.question = question
    }

    var item: OpenCodeQuestion.Item { question.items[index] }
    var isLast: Bool { index == question.items.count - 1 }
    /// "2/5", or nil for a single item.
    var progress: String? { question.items.count > 1 ? "\(index + 1)/\(question.items.count)" : nil }

    func isPicked(_ label: String, at item: Int? = nil) -> Bool {
        picked[item ?? index]?.contains(label) == true
    }

    func typedAnswer(at item: Int? = nil) -> String {
        let position = item ?? index
        return typed[position] ?? question.items[position].initial
    }

    /// Picks an option on the item on show. Returns true when that settles
    /// the item, a single-choice pick, so the caller can move on.
    @discardableResult
    mutating func pick(_ label: String) -> Bool {
        var set = picked[index] ?? []
        if item.multiple {
            if let found = set.firstIndex(of: label) { set.remove(at: found) } else { set.append(label) }
            picked[index] = set
            return false
        }
        let already = set == [label]
        picked[index] = already ? [] : [label]
        return !already
    }

    /// Picks option `number` (1-based) on the item on show, for the number
    /// keys. Returns whether the item is settled, as `pick` does; nil when
    /// there's no such option.
    mutating func pick(number: Int) -> Bool? {
        guard number >= 1, number <= item.options.count else { return nil }
        return pick(item.options[number - 1].label)
    }

    mutating func type(_ text: String) { typed[index] = text }

    /// The answer to one item: the options picked, then what was typed.
    func answer(at position: Int) -> [String] {
        let text = typedAnswer(at: position).trimmingCharacters(in: .whitespacesAndNewlines)
        let order = question.items[position].options.map(\.label)
        let chosen = order.filter { isPicked($0, at: position) }
        return text.isEmpty ? chosen : chosen + [text]
    }

    var answers: [[String]] { question.items.indices.map(answer(at:)) }
    var canAdvance: Bool { !answer(at: index).isEmpty }
    var isComplete: Bool { answers.allSatisfy { !$0.isEmpty } }

    /// Onto the next item; false on the last.
    @discardableResult
    mutating func advance() -> Bool {
        guard !isLast else { return false }
        index += 1
        return true
    }

    mutating func back() {
        if index > 0 { index -= 1 }
    }
}
