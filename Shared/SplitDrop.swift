import CoreGraphics
import Foundation

/// Where a tab dropped on the terminal lands: beside which pane, on which
/// side. The engine splits only right and down, so left and top are those
/// followed by swapping the two panes.
enum SplitEdge: String, CaseIterable, Codable {
    case left, right, top, bottom

    /// The engine's split direction.
    var split: String { self == .left || self == .right ? "right" : "down" }
    /// Whether the moved pane then swaps with its neighbour to land first.
    var swaps: Bool { self == .left || self == .top }
    /// The direction itself, for an engine that splits on every side.
    var rawDirection: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .top: "up"
        case .bottom: "down"
        }
    }
    var opposite: SplitEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
    /// "Left", "Right", "Up", "Down", for labels.
    var sideName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Up"
        case .bottom: "Down"
        }
    }
    var title: String {
        switch self {
        case .left: "Split Left"
        case .right: "Split Right"
        case .top: "Split Up"
        case .bottom: "Split Down"
        }
    }
}

/// A tab's panes as `pane.layout` reports them, in terminal cells.
struct PaneLayout: Equatable {
    struct Pane: Equatable {
        let id: String
        let rect: CGRect
    }

    let area: CGRect
    let panes: [Pane]
    /// The dividers between them, when the engine reports any.
    var splits: [EngineLayout.Split] = []

    /// From a `pane.layout` result.
    static func parse(_ result: [String: Any]) -> PaneLayout? {
        guard let layout = result["layout"] as? [String: Any],
              let area = rect(layout["area"]), area.width > 0, area.height > 0 else { return nil }
        let panes = (layout["panes"] as? [[String: Any]] ?? []).compactMap { pane -> Pane? in
            guard let id = pane["pane_id"] as? String, let rect = rect(pane["rect"]) else { return nil }
            return Pane(id: id, rect: rect)
        }
        return panes.isEmpty ? nil : PaneLayout(area: area, panes: panes)
    }

    private static func rect(_ value: Any?) -> CGRect? {
        // Cells are whole numbers; read through NSNumber so an integer and a
        // double both count, however the dictionary was built.
        func number(_ key: String) -> Double? { ((value as? [String: Any])?[key] as? NSNumber)?.doubleValue }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A drop's meaning, and the part of the view to light up for it: the half
/// of the target pane the moved tab will take, or the whole view when it
/// arrives as a tab of its own.
struct SplitTarget: Equatable {
    /// The pane split beside; nil for the tab's whole area (a root split).
    let paneId: String?
    /// Nil: not a split, the tab joins the window as a tab.
    let edge: SplitEdge?
    let highlight: CGRect
    /// What the drop does there, for the zone's label.
    var action: SplitAction = .split

    var title: String {
        guard let edge else { return "Move Here as Tab" }
        let side = edge.sideName
        let whole = paneId == nil ? " of Everything" : ""
        switch action {
        case .split: return "Split \(side)\(whole)"
        case .newShell: return "New Shell \(side)\(whole)"
        case .move: return "Move \(side)\(whole)"
        }
    }
}

/// What a split zone does with what's dropped, said on the zone so a drop
/// never surprises (T3 Code's verb badge).
enum SplitAction: Equatable {
    /// Another tab moves in as a pane.
    case split
    /// The tab dropped on its own edge: a fresh shell opens there.
    case newShell
    /// A pane dragged by its handle moves there.
    case move
}

/// Where the terminal draws the engine's cells in its view: the real cell
/// size and the offsets of the grid, so a zone sits on the pane it names
/// rather than on the layout stretched across the view.
struct CellGeometry: Equatable {
    let cellSize: CGSize
    let contentLeft: CGFloat
    let contentTop: CGFloat

    var isKnown: Bool { cellSize.width > 0 && cellSize.height > 0 }

    /// No real cells to go by: the layout is stretched over the view, which
    /// is how natively drawn panes are placed.
    static let scaled = CellGeometry(cellSize: .zero, contentLeft: 0, contentTop: 0)

    /// One of `layout`'s cells stretched over `size`.
    static func stretched(_ layout: PaneLayout, over size: CGSize) -> CellGeometry {
        guard layout.area.width > 0, layout.area.height > 0 else { return scaled }
        return CellGeometry(cellSize: CGSize(width: size.width / layout.area.width, height: size.height / layout.area.height),
                            contentLeft: -layout.area.minX * size.width / layout.area.width,
                            contentTop: -layout.area.minY * size.height / layout.area.height)
    }
}

extension PaneLayout {
    /// The layout the engine's snapshot carries, always current.
    init?(_ layout: EngineLayout) {
        func rect(_ r: EngineLayout.Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        guard layout.area.width > 0, layout.area.height > 0, !layout.panes.isEmpty else { return nil }
        // Zoomed, one pane fills the tab and the rest are out of sight: what
        // shows is a lone pane, with no cards, dividers or zones for the others.
        if layout.zoomed, let focused = layout.panes.first(where: { $0.paneId == layout.focusedPaneId }) ?? layout.panes.first {
            self.init(area: rect(layout.area), panes: [Pane(id: focused.paneId, rect: rect(layout.area))])
            return
        }
        self.init(area: rect(layout.area), panes: layout.panes.map { Pane(id: $0.paneId, rect: rect($0.rect)) },
                  splits: layout.splits)
    }

    /// Each pane's frame in a view of `size`: from the real cells when known,
    /// else the area scaled to the view.
    func frames(in size: CGSize, cells: CellGeometry?) -> [(Pane, CGRect)] {
        if let cells, cells.isKnown {
            let w = cells.cellSize.width, h = cells.cellSize.height
            // A blank terminal draws its rows pushed down to the bottom, so
            // `contentTop` carries that shift and the cells' frame runs past
            // the view. The panes themselves still fill the view: take the
            // overflow back off, then keep what's in view.
            let visible = CGRect(origin: .zero, size: size)
            let raw = panes.map { pane in
                (pane, CGRect(x: cells.contentLeft + pane.rect.minX * w, y: cells.contentTop + pane.rect.minY * h,
                              width: pane.rect.width * w, height: pane.rect.height * h))
            }
            let overflow = max(0, (raw.map(\.1.maxY).max() ?? 0) - size.height)
            let lift = min(overflow, cells.contentTop)
            return raw.map { pane, frame in
                let lifted = frame.offsetBy(dx: 0, dy: -lift)
                let clipped = lifted.intersection(visible)
                return (pane, clipped.isNull || clipped.width < 1 || clipped.height < 1 ? lifted : clipped)
            }
        }
        let scaleX = size.width / area.width, scaleY = size.height / area.height
        return panes.map { pane in
            (pane, CGRect(x: (pane.rect.minX - area.minX) * scaleX, y: (pane.rect.minY - area.minY) * scaleY,
                          width: pane.rect.width * scaleX, height: pane.rect.height * scaleY))
        }
    }

    /// Whether moving `moving` to `edge` of `target` would leave it where it
    /// is: it's already the neighbour on that side, spanning the same rows
    /// (or columns), as Orca checks before showing a zone.
    func isAlready(_ moving: String, at edge: SplitEdge, of target: String) -> Bool {
        guard let a = panes.first(where: { $0.id == moving })?.rect,
              let b = panes.first(where: { $0.id == target })?.rect else { return false }
        // Panes sit a divider apart: at most one cell between them.
        func touching(_ x: CGFloat, _ y: CGFloat) -> Bool { y - x >= 0 && y - x <= 1 }
        switch edge {
        case .left: return a.minY == b.minY && a.height == b.height && touching(a.maxX, b.minX)
        case .right: return a.minY == b.minY && a.height == b.height && touching(b.maxX, a.minX)
        case .top: return a.minX == b.minX && a.width == b.width && touching(a.maxY, b.minY)
        case .bottom: return a.minX == b.minX && a.width == b.width && touching(b.maxY, a.minY)
        }
    }
}

enum SplitDrop {
    /// Which pane `point` is over in a view of `size` showing `layout`, and
    /// which of its edges is nearest.
    ///
    /// For a tab, only the band along a pane's edges splits; its middle is
    /// a tab when `acceptsTab` (the tab comes from another window), else
    /// nothing, so a split is only ever made on purpose. For a pane dragged
    /// by its handle (`moving`), the pane under the point is cut along its
    /// diagonals, Warp's way, with a dead middle; the pane itself, and a move
    /// that changes nothing, offer no zone. With `wholeTab`, a thin band
    /// along the whole area's edges splits beside everything.
    static func target(at point: CGPoint, in size: CGSize, layout: PaneLayout, acceptsTab: Bool = false,
                       cells: CellGeometry? = nil, moving: String? = nil, action: SplitAction = .split,
                       wholeTab: Bool = false) -> SplitTarget? {
        guard size.width > 0, size.height > 0 else { return nil }
        let panes = layout.frames(in: size, cells: cells)
        let action = moving == nil ? action : .move

        if wholeTab, layout.panes.count > 1, let whole = panes.map(\.1).reduce(nil, { $0?.union($1) ?? $1 }),
           let edge = nearestEdge(of: point, in: whole, within: wholeTabBand(whole)) {
            return SplitTarget(paneId: nil, edge: edge, highlight: half(whole, edge), action: action)
        }

        // The pane under the point, else the nearest one: between panes sits
        // a divider that belongs to neither.
        guard let (pane, frame) = panes.first(where: { $0.1.contains(point) })
            ?? panes.min(by: { distance(point, $0.1) < distance(point, $1.1) }) else { return nil }

        if let moving {
            guard pane.id != moving else { return nil }
            let u = (point.x - frame.midX) / max(frame.width, 1), v = (point.y - frame.midY) / max(frame.height, 1)
            guard max(abs(u), abs(v)) >= deadMiddle else { return nil }
            let edge: SplitEdge = abs(v) > abs(u) ? (v < 0 ? .top : .bottom) : (u < 0 ? .left : .right)
            guard !layout.isAlready(moving, at: edge, of: pane.id) else { return nil }
            return SplitTarget(paneId: pane.id, edge: edge, highlight: half(frame, edge), action: action)
        }

        guard let edge = nearestEdge(of: point, in: frame, within: edgeBand) else {
            return acceptsTab ? SplitTarget(paneId: pane.id, edge: nil, highlight: CGRect(origin: .zero, size: size)) : nil
        }
        return SplitTarget(paneId: pane.id, edge: edge, highlight: half(frame, edge), action: action)
    }

    /// How far into a pane, as a fraction of its size, a dropped tab still splits.
    static let edgeBand: CGFloat = 0.25
    /// Around a pane's middle, as a fraction of its size from the centre, a
    /// dragged pane does nothing: Warp's 18%.
    static let deadMiddle: CGFloat = 0.18

    /// The band along the whole area's edges: thin, so the panes by the edge
    /// keep their own zones.
    static func wholeTabBand(_ whole: CGRect) -> CGFloat {
        min(0.06, 24 / max(min(whole.width, whole.height), 1))
    }

    /// The edge of `rect` nearest `point`, if it's within `band` (a fraction).
    private static func nearestEdge(of point: CGPoint, in rect: CGRect, within band: CGFloat) -> SplitEdge? {
        let u = (point.x - rect.minX) / max(rect.width, 1)
        let v = (point.y - rect.minY) / max(rect.height, 1)
        let edges: [(SplitEdge, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        guard let (edge, depth) = edges.min(by: { $0.1 < $1.1 }), depth < band else { return nil }
        return edge
    }

    /// The half of `frame` a pane on `edge` takes.
    static func half(_ frame: CGRect, _ edge: SplitEdge) -> CGRect {
        switch edge {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Where a workspace card dragged over a window's content would go: into
/// the tab showing as a split, with a shell in that workspace's folder on
/// that side, or into the window in place of what it shows.
enum WorkspaceDropTarget: Equatable {
    case here
    case beside(SplitEdge)

    var title: String { title(workspace: "") }

    /// The zone's title. By an edge, the workspace's terminal moves in on
    /// that side, which the title says naming it; `ownTab` (the workspace is
    /// the one showing) has nothing to move, so a fresh shell opens there.
    func title(workspace label: String, ownTab: Bool = false) -> String {
        guard case .beside(let edge) = self else { return "Show Here" }
        let side = edge.sideName
        if ownTab { return "New Shell \(side)" }
        return label.isEmpty ? "Move Its Terminal \(side)" : "Move \u{201C}\(label)\u{201D} \(side)"
    }

    /// The outer band along each edge splits the window; the middle shows
    /// the workspace here. The nearest edge wins in a corner.
    static func at(_ point: CGPoint, in size: CGSize, band: CGFloat = 0.28) -> WorkspaceDropTarget? {
        guard size.width > 0, size.height > 0 else { return nil }
        let u = point.x / size.width, v = point.y / size.height
        let distances: [(SplitEdge, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }) else { return nil }
        return nearest.1 < band ? .beside(nearest.0) : .here
    }

    /// The part of a view of `size` it would take, for its highlight.
    func highlight(in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch self {
        case .here: return CGRect(origin: .zero, size: size)
        case .beside(.left): return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .beside(.right): return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .beside(.top): return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .beside(.bottom): return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }
}
