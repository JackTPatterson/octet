import Foundation

extension EngineSnapshot {
    /// The tab of the agent that launched a subagent viewer tab, when the
    /// viewer was told and that pane is still open.
    func parentTabId(ofTab tabId: String) -> String? {
        guard let pane = agents(inTab: tabId).lazy.compactMap(\.parentPaneId).first,
              let parent = panes.first(where: { $0.paneId == pane })?.tabId,
              parent != tabId else { return nil }
        return parent
    }

    /// `tab.move` calls that put every subagent's tab right after its
    /// parent's, in the workspace's current order.
    func subagentTabMoves(inWorkspace workspaceId: String) -> [SubagentTabOrder.Move] {
        SubagentTabOrder.moves(tabs(inWorkspace: workspaceId).map(\.tabId), parent: parentTabId(ofTab:))
    }
}

/// Keeps subagents' tabs together with the tab that launched them: each
/// follows its parent, after the parent's earlier subagents, however either
/// was moved. Everything else keeps its order.
enum SubagentTabOrder {
    struct Move: Equatable {
        let tabId: String
        /// The session server's `insert_index`: the gap before the tab now there.
        let gap: Int
    }

    static func grouped(_ tabIds: [String], parent: (String) -> String?) -> [String] {
        let present = Set(tabIds)
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in tabIds {
            if let parent = parent(id), parent != id, present.contains(parent) {
                children[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
        var ordered: [String] = []
        var placed = Set<String>()
        func place(_ id: String) {
            guard placed.insert(id).inserted else { return }
            ordered.append(id)
            children[id]?.forEach(place)
        }
        roots.forEach(place)
        // Tabs that name each other as parent stay where they were.
        tabIds.forEach(place)
        return ordered
    }

    /// The moves, one after another, that turn `current` into its grouped
    /// order. Each takes a tab from further right to the gap before
    /// position `gap`, where it then sits.
    static func moves(_ current: [String], parent: (String) -> String?) -> [Move] {
        let target = grouped(current, parent: parent)
        var order = current
        var moves: [Move] = []
        for index in target.indices where order[index] != target[index] {
            guard let from = order.firstIndex(of: target[index]) else { continue }
            order.remove(at: from)
            order.insert(target[index], at: index)
            moves.append(Move(tabId: target[index], gap: index))
        }
        return moves
    }
}
