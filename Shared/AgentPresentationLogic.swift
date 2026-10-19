import Foundation

/// Layout decisions shared by the native panel and its regression tests.
enum AgentPresentationLogic {
    /// Only a real, uninspected process root can require an initial skeleton.
    /// Idle conversations have no root; an empty completed scan is valid data.
    static func showsInitialRuntimeLoading(rowCount: Int, scanning: Bool,
                                           hasUnscannedPane: Bool, hasUnscannedNativeRoot: Bool) -> Bool {
        rowCount == 0 && scanning && (hasUnscannedPane || hasUnscannedNativeRoot)
    }
    // The selected agent view must never change terminal geometry. Only an
    // explicit panel resize or a window resize changes this width.
    static func panelWidth(normal: CGFloat, available: CGFloat) -> CGFloat {
        min(normal, max(260, available - 300))
    }
    static func visibleIDs(_ ordered: [(id: String, depth: Int)], collapsed: Set<String>) -> Set<String> {
        var hiddenDepth: Int?
        var visible = Set<String>()
        for row in ordered {
            if let hidden = hiddenDepth, row.depth > hidden { continue }
            visible.insert(row.id)
            hiddenDepth = collapsed.contains(row.id) ? row.depth : nil
        }
        return visible
    }
}
