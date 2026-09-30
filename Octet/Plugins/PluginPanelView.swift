import AppKit
import SwiftUI

/// Plugins' buttons at the right of the tab bar, beside Todos and Git: the
/// panel's title and badge, opening its rows and actions below.
struct PluginPanelButtons: View {
    @ObservedObject var model: PluginPanelModel

    var body: some View {
        ForEach(model.entries) { entry in
            PluginPanelButton(model: model, entry: entry)
        }
    }
}

private struct PluginPanelButton: View {
    @ObservedObject var model: PluginPanelModel
    let entry: PluginPanelModel.Entry
    @State private var hovered = false

    private var isShowing: Binding<Bool> {
        Binding(get: { model.shown == entry.id },
                set: { shown in model.shown = shown ? entry.id : (model.shown == entry.id ? nil : model.shown) })
    }

    var body: some View {
        let panel = entry.panel.panel
        Button { isShowing.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                PluginPanelIcon(entry: entry, size: 11)
                Text(panel.title).font(Theme.uiFontMedium)
                if let badge = entry.content.badge, !badge.isEmpty {
                    Text(badge)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(PluginPanelTone.color(entry.content.tone) ?? Theme.textTertiary)
                }
            }
            .foregroundStyle(isShowing.wrappedValue ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(isShowing.wrappedValue ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show \(panel.title)")
        .accessibilityLabel(isShowing.wrappedValue ? "Hide \(panel.title)" : "Show \(panel.title)")
        .popover(isPresented: isShowing, arrowEdge: .bottom) {
            PluginPanelContent(model: model, id: entry.id)
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

/// The open panel: its rows, each with its state and actions, and the
/// panel's own actions underneath. Read from the model, so it stays live.
private struct PluginPanelContent: View {
    @ObservedObject var model: PluginPanelModel
    let id: String

    var body: some View {
        if let entry = model.entries.first(where: { $0.id == id }) {
            content(entry)
        } else {
            Text("Nothing to show here now")
                .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                .padding(12).frame(width: 320).background(Theme.chrome)
        }
    }

    private func content(_ entry: PluginPanelModel.Entry) -> some View {
        let busy = model.busy.contains(entry.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PluginPanelIcon(entry: entry, size: 13)
                Text(entry.panel.panel.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                if let badge = entry.content.badge, !badge.isEmpty {
                    Text(badge)
                        .font(Theme.captionFont.monospacedDigit())
                        .foregroundStyle(PluginPanelTone.color(entry.content.tone) ?? Theme.textSecondary)
                }
            }
            if entry.content.rows.isEmpty {
                Text(entry.content.message ?? "Nothing to show here now")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.content.rows) { row in
                            PluginPanelRow(row: row, disabled: busy) { action in
                                model.perform(action, item: row.id, in: entry)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
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
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(Theme.chrome)
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
