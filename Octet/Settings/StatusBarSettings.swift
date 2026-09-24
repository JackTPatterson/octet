import SwiftUI
import UniformTypeIdentifiers

/// Settings › Status Bar: the bar as it will look, with its chips dragged
/// into order or removed, and every other chip there is to add.
struct StatusBarSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var host = OctetPluginHost.shared
    @State private var dragging: String?

    var body: some View {
        let descriptors = host.statusDescriptors
        let byId = Dictionary(descriptors.map { ($0.id, $0) }) { first, _ in first }
        let order = host.statusBarOrder

        SettingsGroup(title: "Status bar") {
            SettingsRow(title: "Show status bar", detail: "Chips under the terminal about the focused pane: where it is, what it runs, and what's changed") {
                Toggle("Show status bar", isOn: $settings.values.repoContextBar).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsGroup(title: "Chips") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Drag chips to reorder them. A chip only shows when it has something to say.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                SplashFlow(spacing: 6) {
                    ForEach(order, id: \.self) { id in
                        if let descriptor = byId[id] {
                            StatusChipPreview(descriptor: descriptor, action: .remove) { remove(id, from: order) }
                                .opacity(dragging == id ? 0.35 : 1)
                                .onDrag {
                                    dragging = id
                                    return NSItemProvider(object: id as NSString)
                                }
                                .onDrop(of: [.text], delegate: ChipDropDelegate(target: id, dragging: $dragging, order: order) { host.setStatusBarOrder($0) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .overlay {
                    if order.isEmpty {
                        Text("No chips. Add some below.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .animation(.smooth(duration: 0.18), value: order)
            }
            .padding(14)
        }

        let available = descriptors.filter { !order.contains($0.id) }
        let sources = Dictionary(grouping: available) { $0.pluginId ?? "" }
        SettingsGroup(title: "Add chips") {
            VStack(alignment: .leading, spacing: 14) {
                if available.isEmpty {
                    Text("Every chip is in the bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(sourceOrder(sources.keys), id: \.self) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sourceName(source))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        SplashFlow(spacing: 6) {
                            ForEach(sources[source] ?? []) { descriptor in
                                StatusChipPreview(descriptor: descriptor, action: .add) {
                                    host.setStatusBarOrder(order + [descriptor.id])
                                }
                            }
                        }
                    }
                }
                Text("Plugins can add chips of their own. Status Chips, in Settings › Plugins, has Kubernetes, cloud, Docker, ports and more.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        SettingsGroup(title: "Reset") {
            SettingsRow(title: "Default chips", detail: "Put back the chips the bar starts with, in their first order") {
                Button("Reset") { host.resetStatusBar() }
                    .disabled(!settings.values.statusBarCustomized)
            }
        }
    }

    private func remove(_ id: String, from order: [String]) {
        host.setStatusBarOrder(order.filter { $0 != id })
    }

    /// Octet's own chips first, then each plugin's by name.
    private func sourceOrder(_ keys: Dictionary<String, [StatusItemDescriptor]>.Keys) -> [String] {
        keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return sourceName(lhs).localizedCaseInsensitiveCompare(sourceName(rhs)) == .orderedAscending
        }
    }

    private func sourceName(_ pluginId: String) -> String {
        pluginId.isEmpty ? "Octet" : host.plugins.first { $0.id == pluginId }?.manifest.name ?? pluginId
    }
}

/// A chip as Settings shows it: its sample text, with × to remove it from
/// the bar or + to add it.
private struct StatusChipPreview: View {
    enum Action { case add, remove }

    let descriptor: StatusItemDescriptor
    let action: Action
    let perform: () -> Void
    @ObservedObject private var host = OctetPluginHost.shared
    @State private var hovered = false

    var body: some View {
        Button(action: perform) {
            StatusChip(color: descriptor.color, tone: tone, help: "\(descriptor.name): \(descriptor.summary)") {
                icon
                Text(descriptor.sample).lineLimit(1)
                Image(systemName: action == .add ? "plus" : "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(action == .add || hovered ? 1 : 0.35)
            }
            .opacity(action == .add && !hovered ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(action == .add ? "Add" : "Remove") \(descriptor.name)")
    }

    private var tone: StatusItemOutput.Tone {
        descriptor.id == "builtin.gitState" ? .warning : .normal
    }

    @ViewBuilder
    private var icon: some View {
        switch descriptor.id {
        case "builtin.runtime":
            if let badge = host.runtimeBadge(id: "node") { RuntimeIcon(badge: badge, size: 11) }
        case "builtin.agent":
            if let brand = AgentBrand.forAgent("claude") { AgentLogo(brand: brand, size: 11) }
        case "builtin.branch":
            OctetIcon("arrow.triangle.branch", size: 10)
        case "builtin.worktree":
            OctetIcon("square.stack.3d.up", size: 10)
        case "builtin.changes":
            OctetIcon("doc", size: 10)
        case "builtin.pullRequest":
            OctetIcon("arrow.triangle.pull", size: 10)
        default:
            StatusItemIcon(descriptor: descriptor)
        }
    }
}

/// Moves the dragged chip to where it's dropped, live, as it passes over
/// the others.
private struct ChipDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let order: [String]
    let save: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target) else { return }
        var next = order
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save(next)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
