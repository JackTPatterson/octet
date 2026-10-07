import AppKit
import SwiftUI

/// Each plugin's panel as a section of the right panel's Overview.
struct PluginPanelSections: View {
    @ObservedObject var model: PluginPanelModel

    var body: some View {
        ForEach(model.entries) { entry in
            let panel = entry.panel.panel
            SidePanelSectionView(.plugin(entry.id), title: panel.title,
                                 count: entry.content.badge == nil ? entry.content.rows.count : nil,
                                 label: entry.content.badge,
                                 labelColor: PluginPanelTone.color(entry.content.tone)) {
                PluginPanelBody(model: model, id: entry.id)
            }
        }
    }
}

enum PluginPanelTone {
    static func color(_ tone: PluginPanel.Tone?) -> Color? {
        switch tone {
        case .warning: Color(hex: AgentStateColor.blocked)
        case .danger: Theme.danger
        case .success: Color(hex: AgentStateColor.done)
        case .muted: Theme.textTertiary
        case .normal, nil: nil
        }
    }
}

/// The plugin's own icon, else its symbol.
private struct PluginPanelIcon: View {
    let entry: PluginPanelModel.Entry
    var size: CGFloat

    var body: some View {
        let panel = entry.panel.panel
        if let icon = panel.icon {
            RuntimeIcon(badge: RuntimeBadge(id: entry.id, name: panel.title,
                                            iconPath: entry.panel.plugin.directory + "/" + icon, color: panel.color), size: size)
        } else if let symbol = panel.symbol {
            Image(systemName: symbol).font(.system(size: size - 1))
        }
    }
}

/// A panel's rows, each with its state and actions, and the panel's own
/// actions underneath. Read from the model, so it stays live.
private struct PluginPanelBody: View {
    @ObservedObject var model: PluginPanelModel
    let id: String

    var body: some View {
        if let entry = model.entries.first(where: { $0.id == id }) {
            content(entry)
        } else {
            Text("Nothing to show here now")
                .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
        }
    }

    private func content(_ entry: PluginPanelModel.Entry) -> some View {
        let busy = model.busy.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if entry.content.rows.isEmpty {
                Text(entry.content.message ?? "Nothing to show here now")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.content.rows) { row in
                        PluginPanelRow(row: row, disabled: busy) { action in
                            model.perform(action, item: row.id, in: entry)
                        }
                    }
                }
            }
            if !entry.content.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.content.actions) { action in
                        OctetButton(title: action.title, kind: .secondary, compact: true) {
                            model.perform(action, item: nil, in: entry)
                        }
                    }
                }
                .disabled(busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PluginPanelRow: View {
    let row: PluginPanel.Row
    let disabled: Bool
    let perform: (PluginPanel.Action) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(PluginPanelTone.color(row.tone) ?? Theme.textTertiary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let link = row.link {
                RowActionButton(title: "Open", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(link) }
            }
            ForEach(row.actions) { action in
                RowActionButton(title: action.title, symbol: action.symbol) { perform(action) }
                    .disabled(disabled)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 34)
        .background(hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .onHover { hovered = $0 }
        .help(row.detail ?? row.title)
    }
}

/// A row's action: its symbol when it has one, with its title on hover.
private struct RowActionButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) } else { Text(title).font(Theme.captionFont) }
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 22)
            .background(hovered ? Theme.cardSelected : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
