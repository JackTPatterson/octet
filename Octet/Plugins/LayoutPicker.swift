import AppKit
import SwiftUI

/// The title bar's layout picker, like a trading app's: a monitor button
/// that opens every layout enabled plugins offer, grouped by how many
/// windows they make. Picking one arranges Octet windows on this screen in
/// that shape: this window in the first place, a new window in each other. Picking one opens a new tab split that way, each pane a shell
/// in the folder in front.
struct LayoutPickerButton: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var host = OctetPluginHost.shared
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let layouts = host.layouts
        Group {
            Button { open.toggle() } label: {
                MonitorGlyph()
                    .foregroundStyle(open || hovered ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 28, height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(open || hovered ? Theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("Window layouts")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                LayoutPickerGrid(layouts: layouts, screen: window.nsWindow?.screen) { frames in
                    open = false
                    PaneLayoutActions.arrange(frames, from: window)
                }
            }
        }
        #if DEBUG
        // Verification hook: "layouts" opens the picker.
        .onAppear {
            guard ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "layouts" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { open = true }
        }
        #endif
        .help("Arrange windows across your displays")
    }
}

/// A window split into panes, drawn so it follows the text color.
struct WindowLayoutGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let width = canvas.width, height = canvas.height
            let frame = CGRect(x: width * 0.08, y: height * 0.14, width: width * 0.84, height: height * 0.72)
            context.stroke(Path(roundedRect: frame, cornerRadius: 2.5), with: .foreground, lineWidth: 1.4)
            var panes = Path()
            panes.move(to: CGPoint(x: frame.midX, y: frame.minY))
            panes.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            panes.move(to: CGPoint(x: frame.midX, y: frame.midY))
            panes.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            context.stroke(panes, with: .foreground, lineWidth: 1.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
    /// The display the window is on.
    let screen: NSScreen?
    /// The chosen windows' frames, in global screen coordinates.
    let pick: ([CGRect]) -> Void

    private var displays: [CGRect] { NSScreen.screens.map(\.visibleFrame) }
    private var current: Int { screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0 }
    private var here: CGRect { screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero }

    var body: some View {
        let arrangements = MonitorArrangement.across(displays, current: current)
        let portrait = here.height > here.width
        let groups = Dictionary(grouping: layouts) { $0.layout.layout.paneCount }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(displays.count > 1 ? "Your \(displays.count) displays" : "Your display")
                    .font(Theme.captionFont.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(arrangements) { arrangement in
                        DisplaysThumbnail(displays: displays, windows: arrangement.frames, title: arrangement.title) {
                            pick(arrangement.frames)
                        }
                    }
                }
            }
            if !groups.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text(portrait ? "This display (turned for portrait)" : "This display")
                    .font(Theme.captionFont.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                ForEach(groups.keys.sorted(), id: \.self) { count in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(count == 1 ? "1 window" : "\(count) windows").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                            ForEach((groups[count] ?? []).map { $0.layout }) { layout in
                                let rects = MonitorArrangement.fitted(layout.layout.rects(), toPortrait: portrait)
                                LayoutThumbnail(layout: layout, rects: rects) {
                                    pick(rects.map { $0.windowFrame(in: here) })
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(Theme.chrome)
    }
}

/// Every display drawn where it sits, with an arrangement's windows inside:
/// the first, this window, in the accent.
private struct DisplaysThumbnail: View {
    let displays: [CGRect]
    let windows: [CGRect]
    let title: String
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 4) {
                Canvas { context, size in
                    let bounds = displays.reduce(CGRect.null) { $0.union($1) }
                    guard bounds.width > 0, bounds.height > 0 else { return }
                    let scale = min(size.width / bounds.width, size.height / bounds.height)
                    let offset = CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
                    // Screen coordinates rise upward; the picture's go down.
                    func place(_ rect: CGRect) -> CGRect {
                        CGRect(x: offset.x + (rect.minX - bounds.minX) * scale,
                               y: offset.y + (bounds.maxY - rect.maxY) * scale,
                               width: rect.width * scale, height: rect.height * scale)
                    }
                    for display in displays {
                        context.stroke(Path(roundedRect: place(display), cornerRadius: 2.5),
                                       with: .color(Theme.textTertiary.opacity(0.7)), lineWidth: 1)
                    }
                    for (index, window) in windows.enumerated() {
                        let frame = place(window).insetBy(dx: 1.5, dy: 1.5)
                        let shape = Path(roundedRect: frame, cornerRadius: 1.5)
                        let tint = index == 0 ? Theme.accent : Theme.textSecondary
                        context.fill(shape, with: .color(tint.opacity(hovered ? 0.45 : 0.28)))
                        context.stroke(shape, with: .color(tint.opacity(0.8)), lineWidth: 1)
                    }
                }
                .frame(height: 44)
                Text(title).font(Theme.captionFont).foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Theme.card.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// One layout as a small picture of its panes.
struct LayoutThumbnail: View {
    let layout: PaneLayoutContribution
    var rects: [PaneLayoutNode.Rect]? = nil
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            LayoutPicture(rects: rects ?? layout.layout.rects(), highlighted: hovered)
            .frame(width: 46, height: 32)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(hovered ? Theme.hover : .clear))
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
    /// Arranges Octet windows on the screen in `layout`'s shape: the window
    /// it was picked from takes the first place, and each other place gets a
    /// new window with a workspace of its own in the same folder.
    static func arrangeWindows(_ layout: PaneLayoutContribution, from window: WindowContext) {
        guard let visible = (window.nsWindow?.screen ?? NSScreen.main)?.visibleFrame else { return }
        let portrait = visible.height > visible.width
        arrange(MonitorArrangement.fitted(layout.layout.rects(), toPortrait: portrait).map { $0.windowFrame(in: visible) },
                from: window)
    }

    /// Puts this window at the first frame and a new window at each other.
    static func arrange(_ frames: [CGRect], from window: WindowContext) {
        guard let nsWindow = window.nsWindow, let first = frames.first else { return }
        // A full-screen window can't share its space.
        if nsWindow.styleMask.contains(.fullScreen) { nsWindow.toggleFullScreen(nil) }
        nsWindow.setFrame(first, display: true, animate: true)
        let store = window.store
        let snapshot = store.snapshot
        let cwd = window.focusedPaneId.flatMap { snapshot.workingDirectory(ofPane: $0) }
            ?? window.focusedWorkspace.flatMap { snapshot.directory(ofWorkspace: $0.workspaceId) }
            ?? NSHomeDirectory()
        for frame in frames.dropFirst() {
            store.call("workspace.create", ["focus": false, "cwd": cwd], failure: "Couldn't open a window") { created in
                guard let workspace = created.workspaceId else { return }
                WindowOpener.open?(OctetWindowSpec(workspaceId: workspace, frame: frame))
            }
        }
    }

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
