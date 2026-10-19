import SwiftUI

/// Additions to the starter launcher; its original nine choices stay intact.
struct PlaneAddMore: View {
    @ObservedObject var ui: UIState
    private var saved: String { ui.additionalPlaneShortcuts }
    private var remaining: [PlaneKind] {
        PlaneKind.addableCases.filter { !PlaneKind.starterKinds.contains($0) && !saved.split(separator: ",").contains(Substring($0.rawValue)) }
    }
    var body: some View {
        OctetButton(title: "Add More", icon: "plus", kind: .ghost, compact: true) {
            let items = remaining.map { kind in
                OctetMenuItem.action(kind.title, icon: kind.icon) {
                    ui.additionalPlaneShortcuts = (saved.split(separator: ",").map(String.init) + [kind.rawValue]).joined(separator: ",")
                }
            }
            OctetContextMenu.present(items.isEmpty ? [.header("All panes added")] : items)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3])))
        .help("Save another pane shortcut to the launcher")
    }
}

extension UIState {
    var visiblePlaneIds: [String] {
        var seen = Set<String>()
        let valid = splitPlaneIds.filter { id in planes.contains { $0.id == id } && seen.insert(id).inserted }
        return valid.count > 1 ? valid : activePlane.map { [$0.id] } ?? []
    }

    func splitPlane(_ kind: PlaneKind) {
        let previous = visiblePlaneIds
        addPlane(kind)
        guard let id = activePlane?.id, !previous.contains(id) else { return }
        splitPlaneIds = previous + [id]
    }

    func splitExistingPlane(_ id: String) {
        guard planes.contains(where: { $0.id == id }) else { return }
        let previous = visiblePlaneIds
        activePlaneId = id
        if !previous.contains(id) { splitPlaneIds = previous + [id] }
    }

    func removePlaneFromSplit(_ id: String) {
        let remaining = visiblePlaneIds.filter { $0 != id }
        splitPlaneIds = remaining.count > 1 ? remaining : []
        if activePlaneId == id { activePlaneId = remaining.first }
    }
}

/// All split marks use the app's bundled Iconsax row-horizontal/row-vertical art.
struct PlaneSplitMenu: View {
    @ObservedObject var ui: UIState
    var body: some View {
        OctetIconButton(icon: ui.splitSideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2",
                        help: "Split panel", active: ui.visiblePlaneIds.count > 1) {
            OctetContextMenu.present(menuItems)
        }
    }

    private var menuItems: [OctetMenuItem] {
        var items: [OctetMenuItem] = []
        let available = ui.planes.filter { !ui.visiblePlaneIds.contains($0.id) }
        if !available.isEmpty {
            items.append(.header("Split with an open pane"))
            items += available.map { plane in
                .action(ui.planeBadges[plane.id]?.title ?? plane.kind.title, icon: plane.kind.icon) { ui.splitExistingPlane(plane.id) }
            }
            items.append(.divider)
        }
        let kinds = PlaneKind.addableCases.filter { kind in
            kind == .terminal || kind == .device || !ui.visiblePlaneIds.contains(Plane.make(kind).id)
        }
        items.append(.submenu("Open another pane", icon: "plus", kinds.map { kind in
            .action(kind.title, icon: kind.icon) { ui.splitPlane(kind) }
        }))
        items += [
            .divider,
            .action("Stack vertically", icon: "rectangle.split.1x2", enabled: ui.splitSideBySide) { ui.splitSideBySide = false },
            .action("Side by side", icon: "rectangle.split.2x1", enabled: !ui.splitSideBySide) { ui.splitSideBySide = true }
        ]
        if ui.visiblePlaneIds.count > 1 {
            items += [.divider, .action("Return to single pane", icon: "rectangle.on.rectangle") { ui.splitPlaneIds = [] }]
        }
        return items
    }
}

/// A stable view tree keeps shells and browser views alive across layout changes.
/// Single-pane mode has the same full-size content and no additional header.
struct PlaneDeck<Content: View>: View {
    @ObservedObject var ui: UIState
    @ViewBuilder var content: (Plane) -> Content
    @State private var dragLengths: [CGFloat]?

    var body: some View {
        GeometryReader { geometry in
            let ids = ui.visiblePlaneIds
            let split = ids.count > 1
            let horizontal = ui.splitSideBySide
            let minimum: CGFloat = horizontal ? 240 : 140
            let size = CGSize(width: split && horizontal ? max(geometry.size.width, CGFloat(ids.count) * minimum) : geometry.size.width,
                              height: split && !horizontal ? max(geometry.size.height, CGFloat(ids.count) * minimum) : geometry.size.height)
            let lengths = PlaneSplitSizing.lengths(ids: ids, weights: ui.planeSplitWeights, extent: horizontal ? size.width : size.height, minimum: minimum)
            ZStack {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(ui.planes) { plane in
                            let index = ids.firstIndex(of: plane.id)
                            let offset = index.map { lengths.prefix($0).reduce(0, +) } ?? 0
                            let length = index.map { lengths[$0] } ?? (horizontal ? size.width : size.height)
                            VStack(spacing: 0) {
                                header(plane).frame(height: split ? 28 : 0).clipped().accessibilityHidden(!split)
                                content(plane)
                            }
                            .frame(width: split && horizontal ? length : size.width, height: split && !horizontal ? length : size.height)
                            .clipped()
                            .offset(x: split && horizontal ? offset : 0, y: split && !horizontal ? offset : 0)
                            .opacity(index != nil ? 1 : 0).allowsHitTesting(index != nil).accessibilityHidden(index == nil)
                        }
                        if split {
                            ForEach(0..<(ids.count - 1), id: \.self) { index in
                                let boundary = lengths.prefix(index + 1).reduce(0, +)
                                Rectangle().fill(Theme.divider)
                                    .frame(width: horizontal ? 5 : size.width, height: horizontal ? size.height : 5)
                                    .contentShape(Rectangle())
                                    .offset(x: horizontal ? boundary - 2.5 : 0, y: horizontal ? 0 : boundary - 2.5)
                                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                        if dragLengths == nil { dragLengths = lengths }
                                        guard let original = dragLengths, original.count == ids.count else { return }
                                        resize(ids, lengths: original, index: index, delta: horizontal ? value.translation.width : value.translation.height, minimum: minimum)
                                    }.onEnded { _ in dragLengths = nil })
                                    .accessibilityLabel("Resize split")
                                    .accessibilityAdjustableAction { direction in
                                        resize(ids, lengths: lengths, index: index, delta: direction == .increment ? 20 : -20, minimum: minimum)
                                    }
                            }
                        }
                    }.frame(width: size.width, height: size.height)
                }
                if ui.planes.isEmpty { PlaneLauncher(ui: ui) }
            }
        }
        .onChange(of: ui.visiblePlaneIds) { _, _ in dragLengths = nil }
        .onChange(of: ui.splitSideBySide) { _, _ in dragLengths = nil }
    }

    private func header(_ plane: Plane) -> some View {
        HStack(spacing: 6) {
            OctetButton(title: ui.planeBadges[plane.id]?.title ?? plane.kind.title,
                        icon: plane.kind.icon, kind: .ghost, compact: true) { ui.activePlaneId = plane.id }
            Spacer(minLength: 0)
            OctetIconButton(icon: "xmark", help: "Return this pane to the tab strip") { ui.removePlaneFromSplit(plane.id) }
        }
        .foregroundStyle(ui.activePlane?.id == plane.id ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 8).frame(height: 28).background(Theme.chrome)
    }

    private func resize(_ ids: [String], lengths: [CGFloat], index: Int, delta: CGFloat, minimum: CGFloat) {
        let pair = lengths[index] + lengths[index + 1]
        let first = max(minimum, min(pair - minimum, lengths[index] + delta))
        var changed = lengths
        changed[index] = first
        changed[index + 1] = pair - first
        ui.planeSplitWeights = Dictionary(uniqueKeysWithValues: zip(ids, changed.map { max(0, $0 - minimum) }))
    }
}

enum PlaneSplitSizing {
    static func lengths(ids: [String], weights: [String: CGFloat], extent: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard ids.count > 1 else { return ids.map { _ in extent } }
        let values = ids.map { max(0, weights[$0] ?? 1) }
        let total = values.reduce(0, +)
        let extra = max(0, extent - CGFloat(ids.count) * minimum)
        return values.map { minimum + extra * (total > 0 ? $0 / total : 1 / CGFloat(ids.count)) }
    }
}
