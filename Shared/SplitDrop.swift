import CoreGraphics
import Foundation

/// Where a tab dropped on the terminal lands: beside which pane, on which
/// side. The engine splits only right and down, so left and top are those
/// followed by swapping the two panes.
enum SplitEdge: String, CaseIterable {
    case left, right, top, bottom

    /// The engine's split direction.
    var split: String { self == .left || self == .right ? "right" : "down" }
    /// Whether the moved pane then swaps with its neighbour to land first.
    var swaps: Bool { self == .left || self == .top }
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
    let paneId: String
    /// Nil: not a split, the tab joins the window as a tab.
    let edge: SplitEdge?
    let highlight: CGRect

    var title: String { edge?.title ?? "Move Here as Tab" }
}

enum SplitDrop {
    /// Which pane `point` is over in a view of `size` showing `layout`, and
    /// which of its edges is nearest. The layout's cells are scaled to the
    /// view, which is close enough to pick a pane and a side.
    ///
    /// Only the band along a pane's edges splits; its middle is a tab
    /// when `acceptsTab` (the tab comes from another window), else nothing,
    /// so a split is only ever made on purpose.
    static func target(at point: CGPoint, in size: CGSize, layout: PaneLayout, acceptsTab: Bool = false) -> SplitTarget? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scaleX = size.width / layout.area.width
        let scaleY = size.height / layout.area.height
        let panes = layout.panes.map { pane in
            (pane, CGRect(x: (pane.rect.minX - layout.area.minX) * scaleX, y: (pane.rect.minY - layout.area.minY) * scaleY,
                          width: pane.rect.width * scaleX, height: pane.rect.height * scaleY))
        }
        // The pane under the point, else the nearest one: between panes sits
        // a divider that belongs to neither.
        guard let (pane, frame) = panes.first(where: { $0.1.contains(point) })
            ?? panes.min(by: { distance(point, $0.1) < distance(point, $1.1) }) else { return nil }

        let u = (point.x - frame.minX) / max(frame.width, 1)
        let v = (point.y - frame.minY) / max(frame.height, 1)
        let edges: [(SplitEdge, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        let (edge, depth) = edges.min { $0.1 < $1.1 }!
        guard depth < edgeBand else {
            return acceptsTab ? SplitTarget(paneId: pane.id, edge: nil, highlight: CGRect(origin: .zero, size: size)) : nil
        }

        let highlight: CGRect
        switch edge {
        case .left: highlight = CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: highlight = CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: highlight = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: highlight = CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
        return SplitTarget(paneId: pane.id, edge: edge, highlight: highlight)
    }

    /// How far into a pane, as a fraction of its size, a drop still splits.
    static let edgeBand: CGFloat = 0.25

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Where a workspace card dragged over a window's content would go: beside
/// this window, splitting it in two, or into it in place of what it shows.
enum WorkspaceDropTarget: Equatable {
    case here
    case beside(SplitEdge)

    var title: String {
        switch self {
        case .here: "Show Here"
        case .beside(.left): "Open in a Window on the Left"
        case .beside(.right): "Open in a Window on the Right"
        case .beside(.top): "Open in a Window Above"
        case .beside(.bottom): "Open in a Window Below"
        }
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

    /// A window frame (screen coordinates, origin bottom left) split for the
    /// drop: the new window's half, and what the old window keeps.
    static func split(_ frame: CGRect, at edge: SplitEdge) -> (new: CGRect, kept: CGRect) {
        let halfW = (frame.width / 2).rounded(), halfH = (frame.height / 2).rounded()
        let left = CGRect(x: frame.minX, y: frame.minY, width: halfW, height: frame.height)
        let right = CGRect(x: frame.minX + halfW, y: frame.minY, width: frame.width - halfW, height: frame.height)
        let top = CGRect(x: frame.minX, y: frame.minY + halfH, width: frame.width, height: frame.height - halfH)
        let bottom = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: halfH)
        switch edge {
        case .left: return (left, right)
        case .right: return (right, left)
        case .top: return (top, bottom)
        case .bottom: return (bottom, top)
        }
    }
}
