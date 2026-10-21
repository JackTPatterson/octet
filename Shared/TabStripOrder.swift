import Foundation

/// The order of a window's tab strip. Terminal tabs and Octet's own tabs
/// (conversations, the editor, container logs) share one strip, but only the
/// terminal tabs have an order in the engine. So the strip keeps the places
/// it has given each tab, and the terminal tabs fill their places in the
/// engine's order: a tab the engine moves (a drag, Move Tab Left/Right, the
/// CLI) moves on screen too, and Octet's tabs stay where they were put.
enum TabStripOrder {
    static let terminalPrefix = "terminal:"

    static func isTerminal(_ id: String) -> Bool { id.hasPrefix(terminalPrefix) }

    /// The strip for `current`, the tabs there now with the terminal tabs in
    /// the engine's order, given the order it showed last. New tabs go last.
    static func reconcile(previous: [String], current: [String]) -> [String] {
        let present = Set(current)
        var order = previous.filter(present.contains)
        let known = Set(order)
        order += current.filter { !known.contains($0) }
        // Every place a terminal tab holds, refilled in the engine's order.
        var engine = current.filter(isTerminal).makeIterator()
        return order.map { isTerminal($0) ? engine.next() ?? $0 : $0 }
    }

    /// `order` with `id` moved into the gap before position `gap` of the
    /// strip as it is now (`order.count` is the end).
    static func moving(_ id: String, toGap gap: Int, in order: [String]) -> [String] {
        guard let from = order.firstIndex(of: id) else { return order }
        var result = order
        result.remove(at: from)
        let gap = max(0, min(order.count, gap))
        result.insert(id, at: gap > from ? gap - 1 : gap)
        return result
    }

    /// The engine's `insert_index` that puts terminal tab `tabId` where
    /// `order` (the strip after the move) shows it: just before the next
    /// terminal tab the strip shows, or at the end. `engine` is the
    /// workspace's tabs in the engine's order, including any the strip hides.
    static func engineGap(for tabId: String, in order: [String], engine: [String]) -> Int {
        let key = terminalPrefix + tabId
        guard let at = order.firstIndex(of: key) else { return engine.count }
        let next = order[(at + 1)...].first { isTerminal($0) && $0 != key }
        guard let next, let index = engine.firstIndex(of: String(next.dropFirst(terminalPrefix.count))) else {
            return engine.count
        }
        return index
    }
}
