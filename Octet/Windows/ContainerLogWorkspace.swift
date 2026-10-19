import Foundation
import Combine

struct WorkspaceContainerLog: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    let workspaceID: String?
    let context: String
    let containerID: String
    var name: String
    var title: String { name + " · Logs" }
    var visualID: String { "container-log:" + id }
}

@MainActor
final class ContainerLogWorkspace: ObservableObject {
    @Published private(set) var tabs: [WorkspaceContainerLog] = [] {
        didSet { if let data = try? JSONEncoder().encode(tabs) { defaults.set(data, forKey: key) } }
    }
    @Published var activeID: String?
    private let key: String
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([WorkspaceContainerLog].self, from: data) {
            tabs = saved
        }
    }

    func tabs(in workspace: String?) -> [WorkspaceContainerLog] { tabs.filter { $0.workspaceID == workspace } }
    func active(in workspace: String?) -> WorkspaceContainerLog? { tabs(in: workspace).first { $0.id == activeID } }

    @discardableResult
    func open(workspace: String?, context: String, containerID: String, name: String) -> WorkspaceContainerLog {
        if let index = tabs.firstIndex(where: { $0.workspaceID == workspace && $0.context == context && $0.containerID == containerID }) {
            tabs[index].name = name
            activeID = tabs[index].id
            return tabs[index]
        }
        let tab = WorkspaceContainerLog(workspaceID: workspace, context: context, containerID: containerID, name: name)
        tabs.append(tab)
        activeID = tab.id
        return tab
    }

    func close(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let siblings = tabs(in: tab.workspaceID)
        let index = siblings.firstIndex(where: { $0.id == id }) ?? 0
        tabs.removeAll { $0.id == id }
        if activeID == id {
            let remaining = tabs(in: tab.workspaceID)
            activeID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
    }
}

extension WindowContext {
    var workspaceContainerLogs: [WorkspaceContainerLog] { containerLogs.tabs(in: focusedWorkspace?.workspaceId) }
    var activeContainerLog: WorkspaceContainerLog? { containerLogs.active(in: focusedWorkspace?.workspaceId) }

    func openContainerLogs(context: String, container: DockerContainer) {
        let tab = containerLogs.open(workspace: focusedWorkspace?.workspaceId, context: context, containerID: container.id, name: container.Names)
        focusContainerLogs(tab.id)
    }

    func focusContainerLogs(_ id: String) {
        guard workspaceContainerLogs.contains(where: { $0.id == id }) else { return }
        editor.dismiss()
        AgentCenter.shared.setActive(nil, in: focusedWorkspace?.workspaceId)
        AgentCenter.shared.setBoard(nil, in: focusedWorkspace?.workspaceId)
        twin.hide()
        ui.review = nil
        ui.pullRequests = nil
        ui.sidePanelMaximized = false
        containerLogs.activeID = id
        nsWindow?.makeFirstResponder(nil)
    }

    func closeContainerLogs(_ id: String) {
        let wasActive = activeContainerLog?.id == id
        containerLogs.close(id)
        if wasActive, activeContainerLog == nil { OctetTerminalRuntime.focusTerminal() }
    }

    /// Move tabs created by the previous sidebar implementation into this
    /// workspace while retaining their exact Docker context and container.
    func migrateContainerLogPlanes() {
        let legacy = ui.planes.filter { $0.kind == .containerLogs }
        guard !legacy.isEmpty, focusedWorkspace != nil else { return }
        let active = ui.activePlaneId
        var focus: String?
        let oldActive = containerLogs.activeID
        for plane in legacy {
            guard let id = plane.containerID else { continue }
            let tab = containerLogs.open(workspace: focusedWorkspace?.workspaceId, context: plane.dockerContext ?? "",
                                         containerID: id, name: plane.containerName ?? String(id.prefix(12)))
            if plane.id == active { focus = tab.id }
        }
        containerLogs.activeID = oldActive
        ui.planes.removeAll { $0.kind == .containerLogs }
        ui.splitPlaneIds = ui.splitPlaneIds.filter { id in ui.planes.contains { $0.id == id } }
        if ui.splitPlaneIds.count < 2 { ui.splitPlaneIds = [] }
        if ui.planes.isEmpty { ui.planes = [.make(.containers)] }
        if !ui.planes.contains(where: { $0.id == ui.activePlaneId }) {
            ui.activePlaneId = ui.planes.first(where: { $0.kind == .containers })?.id ?? ui.planes.first?.id
        }
        if let focus { focusContainerLogs(focus) }
    }

    /// Use the same combined ordering as the strip when log tabs are present.
    var logAwareVisualTabs: [String] {
        let workspace = focusedWorkspace?.workspaceId
        let conversations = AgentCenter.shared.sessions(in: workspace)
        let terminalTabs = displayedTabs.filter {
            !hidesAsConversationBackingTab($0.tabId, sessions: conversations)
        }
        var ids: [String] = terminalTabs.map { "terminal:" + $0.tabId }
        ids.append(contentsOf: conversations.map { "conversation:" + $0.id })
        if !editor.documents.isEmpty { ids.append("editor:" + id.uuidString) }
        ids.append(contentsOf: workspaceContainerLogs.map(\.visualID))
        return orderedVisualTabs(ids)
    }

    var activeVisualTab: String? {
        if let log = activeContainerLog { return log.visualID }
        if editor.isPresented { return "editor:" + id.uuidString }
        if let agent = AgentCenter.shared.active(in: focusedWorkspace?.workspaceId) { return "conversation:" + agent.id }
        return displayedFocusedTabId.map { "terminal:" + $0 }
    }

    func focusVisualTab(_ id: String) {
        if let log = workspaceContainerLogs.first(where: { $0.visualID == id }) { focusContainerLogs(log.id) }
        else if id.hasPrefix("terminal:") { focusTab(String(id.dropFirst("terminal:".count))) }
        else if id.hasPrefix("conversation:") {
            containerLogs.activeID = nil
            editor.dismiss()
            AgentCenter.shared.setActive(String(id.dropFirst("conversation:".count)), in: focusedWorkspace?.workspaceId)
        } else if id.hasPrefix("editor:") { showEditor() }
    }
}
