import SwiftUI

/// Plugins' items in a tab's or workspace's right-click menu, like Start
/// Dev Server, for the folder the menu is about.
struct PluginMenuItems: View {
    @EnvironmentObject private var window: WindowContext
    let place: OctetPluginManifest.MenuItemContribution.Place
    let directory: String?
    let workspaceId: String?

    var body: some View {
        let host = OctetPluginHost.shared
        let items = directory.map { host.menuItems(for: place, directory: $0) } ?? []
        if let directory, !items.isEmpty {
            Divider()
            ForEach(items, id: \.item.id) { entry in
                Button(entry.item.title) {
                    host.perform(entry, directory: directory, workspaceId: workspaceId, in: window)
                }
            }
        }
    }
}
