import AppKit
import SwiftUI

/// The title bar's layout picker, like a trading app's: a monitor button
/// that opens every layout enabled plugins offer, grouped by how many panes
/// they make. Picking one opens a new tab split that way, each pane a shell
/// in the folder in front.
struct LayoutPickerButton: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var host = OctetPluginHost.shared
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let layouts = host.layouts
        if !layouts.isEmpty {
            Button { open.toggle() } label: {
                MonitorGlyph()
                    .foregroundStyle(open || hovered ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 28, height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(open || hovered ? Theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Pane layouts")
            .accessibilityLabel("Pane layouts")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                LayoutPickerGrid(layouts: layouts) { layout in
                    open = false
                    PaneLayoutActions.open(layout, in: window)
                }
            }
        }
    }
}

/// A monitor on its stand, drawn so it follows the text color.
struct MonitorGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let width = canvas.width, height = canvas.height
            let screen = CGRect(x: width * 0.08, y: height * 0.12, width: width * 0.84, height: height * 0.56)
            context.stroke(Path(roundedRect: screen, cornerRadius: 1.5), with: .foreground, lineWidth: 1.4)
            var stand = Path()
            stand.move(to: CGPoint(x: width / 2, y: screen.maxY))
            stand.addLine(to: CGPoint(x: width / 2, y: height * 0.86))
            stand.move(to: CGPoint(x: width * 0.3, y: height * 0.86))
            stand.addLine(to: CGPoint(x: width * 0.7, y: height * 0.86))
            context.stroke(stand, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Every layout, a row per pane count, each drawn as its panes.
struct LayoutPickerGrid: View {
    let layouts: [OctetPluginHost.Layout]
    let pick: (PaneLayoutContribution) -> Void

    var body: some View {
        let groups = Dictionary(grouping: layouts) { $0.layout.layout.paneCount }
        VStack(alignment: .leading, spacing: 10) {
            Text("Split a new tab into").font(Theme.captionFont.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            ForEach(groups.keys.sorted(), id: \.self) { count in
                VStack(alignment: .leading, spacing: 5) {
                    Text(count == 1 ? "1 pane" : "\(count) panes").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                        ForEach((groups[count] ?? []).map { $0.layout }) { layout in
                            LayoutThumbnail(layout: layout) { pick(layout) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(Theme.chrome)
    }
}

/// One layout as a small picture of its panes.
struct LayoutThumbnail: View {
    let layout: PaneLayoutContribution
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            LayoutPicture(rects: layout.layout.rects(), highlighted: hovered)
            .frame(width: 46, height: 32)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(layout.title)
        .accessibilityLabel(layout.title)
    }
}

/// A layout's panes, drawn to fit.
private struct LayoutPicture: View {
    let rects: [PaneLayoutNode.Rect]
    let highlighted: Bool

    var body: some View {
        let fill = highlighted ? Theme.accent.opacity(0.35) : Theme.cardSelected
        let stroke = highlighted ? Theme.accent : Theme.textTertiary.opacity(0.6)
        Canvas { context, size in
            for rect in rects {
                let frame = CGRect(x: CGFloat(rect.x) * size.width + 1, y: CGFloat(rect.y) * size.height + 1,
                                   width: max(CGFloat(rect.width) * size.width - 2, 2),
                                   height: max(CGFloat(rect.height) * size.height - 2, 2))
                let shape = Path(roundedRect: frame, cornerRadius: 1.5)
                context.fill(shape, with: .color(fill))
                context.stroke(shape, with: .color(stroke), lineWidth: 1)
            }
        }
    }
}

@MainActor
enum PaneLayoutActions {
    /// Opens `layout` as a new tab in the window's workspace. If the session
    /// server won't take the split ratios it opens with even splits instead.
    static func open(_ layout: PaneLayoutContribution, in window: WindowContext) {
        let store = window.store
        let snapshot = store.snapshot
        let workspaceId = window.focusedWorkspace?.workspaceId
        let cwd = window.focusedPaneId.flatMap { snapshot.workingDirectory(ofPane: $0) }
            ?? workspaceId.flatMap { snapshot.directory(ofWorkspace: $0) }
            ?? NSHomeDirectory()
        var request = layout.layout.request(title: layout.title, cwd: cwd, workspaceId: workspaceId)
        request["focus"] = false
        let params = request
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: Any]?
            var failure: Error?
            do {
                result = try client.call("layout.apply", params)
            } catch {
                failure = error
                var even = params
                even["root"] = withoutRatios(params["root"])
                if let retried = try? client.call("layout.apply", even) {
                    result = retried
                    failure = nil
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let result else {
                        return ToastCenter.shared.fail(nil, "Couldn't open the layout", detail: failure.map { String(describing: $0) })
                    }
                    let created = EngineCreated(result: result)
                    store.refresh {
                        if let workspace = created.workspaceId ?? workspaceId { window.steer(toWorkspace: workspace, tab: created.tabId) }
                    }
                }
            }
        }
    }

    /// The same tree with the split ratios taken out.
    nonisolated static func withoutRatios(_ node: Any?) -> Any? {
        guard var node = node as? [String: Any] else { return node }
        node["ratio"] = nil
        if let first = node["first"] { node["first"] = withoutRatios(first) }
        if let second = node["second"] { node["second"] = withoutRatios(second) }
        return node
    }
}
