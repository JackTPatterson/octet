import Foundation

/// Where something an engine call created ended up. Each create answers in
/// its own shape (`tab.create` with `tab`, `workspace.create` with
/// `workspace` and `tab`, `layout.apply` with `layout`, `pane.move` with
/// `move_result.pane`, `pane.split` with `pane`); this finds the ids in any
/// of them, so a window can be steered to what was just made.
struct EngineCreated: Equatable {
    var workspaceId: String?
    var tabId: String?
    var paneId: String?

    init(workspaceId: String? = nil, tabId: String? = nil, paneId: String? = nil) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.paneId = paneId
    }

    init(result: [String: Any]) {
        let move = result["move_result"] as? [String: Any]
        let places = [result["layout"], result["tab"], move?["pane"], result["pane"], result["root_pane"], result["workspace"]]
            .compactMap { $0 as? [String: Any] }
        workspaceId = places.lazy.compactMap { $0["workspace_id"] as? String }.first
        tabId = places.lazy.compactMap { $0["tab_id"] as? String }.first
            ?? (result["workspace"] as? [String: Any])?["active_tab_id"] as? String
        paneId = [move?["pane"], result["pane"], result["root_pane"]].lazy
            .compactMap { ($0 as? [String: Any])?["pane_id"] as? String }.first
            ?? (result["layout"] as? [String: Any])?["focused_pane_id"] as? String
    }
}
