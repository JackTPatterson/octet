import SwiftUI

/// A workspace's panel configuration. Separate records also let windows
/// save their own workspace without overwriting another window's sidebar.
struct WorkspacePanelState: Codable {
    var planes: [Plane] = Plane.defaults
    var activePlaneID: String? = Plane.defaults.first?.id
    var splitIDs: [String] = []
    var sideBySide = false
    var weights: [String: CGFloat] = [:]
    var visible = false
    var maximized = false
    var width: CGFloat = SidePanel.width
    var shortcuts = ""
    var folded: Set<String> = []
    var opened: Set<String> = []
}

extension UIState {
    private func panelKey(_ workspace: String) -> String { "octet.workspacePanel.\(workspace)" }

    private var panelSnapshot: WorkspacePanelState {
        WorkspacePanelState(planes: planes, activePlaneID: activePlaneId,
                            splitIDs: splitPlaneIds, sideBySide: splitSideBySide,
                            weights: planeSplitWeights, visible: sidePanelVisible,
                            maximized: sidePanelMaximized, width: sidePanelWidth,
                            shortcuts: additionalPlaneShortcuts, folded: panelFolded, opened: panelOpened)
    }

    func saveWorkspacePanel() {
        guard !restoringWorkspacePanel, let id = panelWorkspaceID,
              let data = try? JSONEncoder().encode(panelSnapshot) else { return }
        panelDefaults.set(data, forKey: panelKey(id))
    }

    func activateWorkspacePanel(_ workspace: String?) {
        guard let workspace, workspace != panelWorkspaceID else { return }
        // Mutations persist immediately; do not overwrite a newer record
        // merely because an older window is switching away.
        if let previous = panelWorkspaceID { workspaceClosedPlanes[previous] = closedPlanes }
        closedPlanes = workspaceClosedPlanes[workspace] ?? []
        let saved = panelDefaults.data(forKey: panelKey(workspace))
            .flatMap { try? JSONDecoder().decode(WorkspacePanelState.self, from: $0) }
        let migrationKey = "octet.workspacePanel.migrated"
        var state = saved ?? WorkspacePanelState()
        if saved == nil, !panelDefaults.bool(forKey: migrationKey) {
            state = panelSnapshot
            state.folded = Set(panelDefaults.stringArray(forKey: "octet.sidePanel.folded") ?? [])
            state.opened = Set(panelDefaults.stringArray(forKey: "octet.sidePanel.opened") ?? [])
        }
        panelDefaults.set(true, forKey: migrationKey)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            restoringWorkspacePanel = true
            panelWorkspaceID = workspace
            planes = state.planes
            activePlaneId = state.activePlaneID
            splitPlaneIds = state.splitIDs
            splitSideBySide = state.sideBySide
            planeSplitWeights = state.weights
            sidePanelVisible = state.visible
            sidePanelMaximized = state.maximized
            sidePanelWidth = max(Self.sidePanelMinWidth, state.width)
            additionalPlaneShortcuts = state.shortcuts
            panelFolded = state.folded
            panelOpened = state.opened
            // Requests and badges belong to the old workspace's mounted views.
            planeBadges = [:]
            browserRequest = nil
            diffRequest = nil
            sidePanelJump = nil
            deviceSetup = nil
            sidePanelAutoOpened = false
            runtimeExpandedEntryIDs = []
            restoringWorkspacePanel = false
        }
        saveWorkspacePanel()
    }

    func panelSectionIsOpen(_ section: SidePanelSection) -> Bool {
        FoldState(folded: panelFolded, opened: panelOpened)
            .isOpen(section.key, opensByDefault: section.opensByDefault)
    }

    func setPanelSection(_ section: SidePanelSection, open: Bool) {
        var state = FoldState(folded: panelFolded, opened: panelOpened)
        state.set(section.key, open: open, opensByDefault: section.opensByDefault)
        panelFolded = state.folded
        panelOpened = state.opened
    }
}

extension UIState {
    @MainActor func workspaceBrowserPage() -> BrowserPage {
        let key = panelWorkspaceID ?? ""
        if let page = panelBrowserPages[key] { return page }
        let page = BrowserPage(private: false)
        panelBrowserPages[key] = page
        return page
    }
}
