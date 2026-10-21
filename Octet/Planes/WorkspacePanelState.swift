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

    /// Each defaults store's records as last saved or read, so switching
    /// workspaces doesn't read and decode one every time. Every write goes
    /// through `saveWorkspacePanel`, which keeps them current for all windows.
    private final class PanelRecords { var states: [String: WorkspacePanelState] = [:] }
    private static let panelRecords = NSMapTable<UserDefaults, PanelRecords>.weakToStrongObjects()

    private var records: PanelRecords {
        if let records = Self.panelRecords.object(forKey: panelDefaults) { return records }
        let records = PanelRecords()
        Self.panelRecords.setObject(records, forKey: panelDefaults)
        return records
    }

    private var panelSnapshot: WorkspacePanelState {
        WorkspacePanelState(planes: planes, activePlaneID: activePlaneId,
                            splitIDs: splitPlaneIds, sideBySide: splitSideBySide,
                            weights: planeSplitWeights, visible: sidePanelVisible,
                            maximized: sidePanelMaximized, width: sidePanelWidth,
                            shortcuts: additionalPlaneShortcuts, folded: panelFolded, opened: panelOpened)
    }

    func saveWorkspacePanel() {
        guard !restoringWorkspacePanel, let id = panelWorkspaceID else { return }
        let state = panelSnapshot
        guard let data = try? JSONEncoder().encode(state) else { return }
        records.states[id] = state
        panelDefaults.set(data, forKey: panelKey(id))
    }

    func activateWorkspacePanel(_ workspace: String?, preserveWindowState: Bool = false) {
        guard let workspace, workspace != panelWorkspaceID else { return }
        let windowVisibility = sidePanelVisible
        let windowMaximized = sidePanelMaximized
        let windowWidth = sidePanelWidth
        // Mutations persist immediately; do not overwrite a newer record
        // merely because an older window is switching away.
        if let previous = panelWorkspaceID { workspaceClosedPlanes[previous] = closedPlanes }
        closedPlanes = workspaceClosedPlanes[workspace] ?? []
        let saved = records.states[workspace] ?? panelDefaults.data(forKey: panelKey(workspace))
            .flatMap { try? JSONDecoder().decode(WorkspacePanelState.self, from: $0) }
        let migrationKey = "octet.workspacePanel.migrated"
        var state = saved ?? WorkspacePanelState()
        if !panelDefaults.bool(forKey: migrationKey) {
            if saved == nil {
                state = panelSnapshot
                state.folded = Set(panelDefaults.stringArray(forKey: "octet.sidePanel.folded") ?? [])
                state.opened = Set(panelDefaults.stringArray(forKey: "octet.sidePanel.opened") ?? [])
            }
            panelDefaults.set(true, forKey: migrationKey)
        }
        // Move the formerly embedded todo list into a discoverable tab once.
        // A user who subsequently closes it keeps that choice.
        let todoMigrationKey = "octet.workspacePanel.todosTab.\(workspace)"
        if !panelDefaults.bool(forKey: todoMigrationKey) {
            if !state.planes.contains(where: { $0.kind == .todos }) {
                let index = state.planes.firstIndex(where: { $0.kind == .overview }).map { $0 + 1 } ?? state.planes.count
                state.planes.insert(.make(.todos), at: index)
            }
            panelDefaults.set(true, forKey: todoMigrationKey)
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            restoringWorkspacePanel = true
            panelWorkspaceID = workspace
            planes = Plane.consolidated(state.planes, active: state.activePlaneID)
            activePlaneId = state.activePlaneID.map(Plane.migratedID)
            splitPlaneIds = state.splitIDs.map(Plane.migratedID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            splitSideBySide = state.sideBySide
            planeSplitWeights = state.weights
            sidePanelVisible = preserveWindowState ? windowVisibility : state.visible
            sidePanelMaximized = preserveWindowState ? windowMaximized : state.maximized
            sidePanelWidth = preserveWindowState ? windowWidth : max(Self.sidePanelMinWidth, state.width)
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
        let page = BrowserPage(private: false, draftKey: key.isEmpty ? nil : key)
        panelBrowserPages[key] = page
        return page
    }
}
