import Foundation

/// The tab bar's plugin panels for the folder in front: each enabled
/// plugin's panel command, read every so often and more often while its
/// panel is open. A panel whose command prints nothing has no button.
@MainActor
final class PluginPanelModel: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let panel: OctetPluginHost.Panel
        var content: PluginPanel
    }

    @Published private(set) var entries: [Entry] = []
    /// The panel that's open, by entry id.
    @Published var shown: String? {
        didSet { if shown != nil, shown != oldValue { refresh(force: true) } }
    }
    /// An action is running in this panel.
    @Published private(set) var busy: Set<String> = []

    private weak var window: WindowContext?
    private var timer: Timer?
    private var lastRead: [String: Date] = [:]
    private var reading: Set<String> = []
    private var directory: String?
    static let tick: TimeInterval = 2

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        refresh(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The folder the panels describe: the agent's in front, else the
    /// focused pane's, else the workspace's.
    private var frontDirectory: String? {
        guard let window else { return nil }
        let workspaceId = window.focusedWorkspace?.workspaceId
        if let session = AgentCenter.shared.active(in: workspaceId) { return session.cwd }
        if let paneId = window.focusedPaneId,
           let cwd = window.store.snapshot.panes.first(where: { $0.paneId == paneId })?.effectiveCwd { return cwd }
        return workspaceId.flatMap { window.store.snapshot.directory(ofWorkspace: $0) }
    }

    func refresh(force: Bool = false) {
        guard let directory = frontDirectory else {
            if !entries.isEmpty { entries = [] }
            return
        }
        // Another folder: what was read describes somewhere else.
        if directory != self.directory {
            self.directory = directory
            lastRead = [:]
            if !entries.isEmpty { entries = [] }
        }
        let now = Date()
        let panels = OctetPluginHost.shared.panels(directory: directory)
        let ids = Set(panels.map(Self.id))
        if entries.contains(where: { !ids.contains($0.id) }) { entries.removeAll { !ids.contains($0.id) } }
        for panel in panels {
            let id = Self.id(panel)
            let every = shown == id ? 3 : max(panel.panel.refreshSeconds ?? 10, 3)
            guard force || now.timeIntervalSince(lastRead[id] ?? .distantPast) >= every, !reading.contains(id) else { continue }
            lastRead[id] = now
            reading.insert(id)
            OctetPluginHost.shared.read(panel, directory: directory) { [weak self] content in
                guard let self else { return }
                self.reading.remove(id)
                // Read for a folder that's no longer in front.
                guard self.directory == directory else { return }
                self.apply(content, for: panel, id: id)
            }
        }
    }

    private func apply(_ content: PluginPanel?, for panel: OctetPluginHost.Panel, id: String) {
        let index = entries.firstIndex { $0.id == id }
        switch (content, index) {
        case (let content?, let index?):
            if entries[index].content != content { entries[index].content = content }
        case (let content?, nil):
            entries.append(Entry(id: id, panel: panel, content: content))
            // Keep the order plugins were loaded in, not the order they answered.
            let order = OctetPluginHost.shared.panels(directory: directory ?? "").map(Self.id)
            entries.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        case (nil, let index?):
            // Stays while open, so it can still be closed.
            if shown != id { entries.remove(at: index) }
        case (nil, nil):
            break
        }
    }

    func perform(_ action: PluginPanel.Action, item: String?, in entry: Entry) {
        guard let window, let directory else { return }
        busy.insert(entry.id)
        OctetPluginHost.shared.act(action, item: item, entry: entry.panel, directory: directory,
                                   workspaceId: window.focusedWorkspace?.workspaceId, in: window) { [weak self] in
            self?.busy.remove(entry.id)
            self?.refresh(force: true)
        }
    }

    private static func id(_ panel: OctetPluginHost.Panel) -> String { "\(panel.plugin.id).\(panel.panel.id)" }
}
