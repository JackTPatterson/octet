import SwiftUI

/// A split's panes as separate rounded cards: the gutter between the pane
/// terminals painted in, with every pane's corners rounded off and a hairline
/// around it, the same on every pane: selecting one lights nothing up. Only a
/// split has any; a lone pane is left as it is.
struct PaneCards: View {
    let layout: PaneLayout
    let cells: CellGeometry
    let focusedPane: String?

    static let radius: CGFloat = 8
    /// The gutter left between two cards. The engine's layout leaves a cell
    /// between panes: each card reaches out from its pane into that cell, so
    /// nothing of the pane is covered.
    static let gutter: CGFloat = 4

    /// A pane's card, and which of its sides face another pane.
    private struct Card {
        let id: String
        let rect: CGRect
        let left: Bool, right: Bool, top: Bool, bottom: Bool

        /// Rounded only where a side faces a neighbour: the rest sit flush
        /// against the terminal's edges, square.
        var shape: UnevenRoundedRectangle {
            let r = PaneCards.radius
            return UnevenRoundedRectangle(topLeadingRadius: left || top ? r : 0, bottomLeadingRadius: left || bottom ? r : 0,
                                          bottomTrailingRadius: right || bottom ? r : 0, topTrailingRadius: right || top ? r : 0)
        }
    }

    var body: some View {
        if layout.panes.count > 1 {
            GeometryReader { proxy in
                let cards = self.cards(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    // The whole view in the gutter colour, the cards cut out.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        for card in cards { path.addPath(card.shape.path(in: card.rect)) }
                    }
                    .fill(Theme.chrome, style: FillStyle(eoFill: true))
                    ForEach(cards, id: \.id) { card in
                        card.shape
                            .strokeBorder(Theme.border.opacity(0.7), lineWidth: 1)
                            .frame(width: card.rect.width, height: card.rect.height)
                            .offset(x: card.rect.minX, y: card.rect.minY)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Each pane's card: out to the terminal's edge on the sides that face
    /// none, and into the gap toward a neighbour on the sides that do, up to
    /// half the gutter short of the gap's middle.
    private func cards(in size: CGSize) -> [Card] {
        let frames = layout.frames(in: size, cells: cells)
        let byId = Dictionary(uniqueKeysWithValues: frames.map { ($0.0.id, $0.1) })
        let view = CGRect(origin: .zero, size: size)
        // Panes sit a divider apart, at most a cell or two.
        let reach: CGFloat = 2
        return frames.map { pane, frame in
            let r = pane.rect
            let others = layout.panes.filter { $0.id != pane.id }
            func overlapsRows(_ o: PaneLayout.Pane) -> Bool { o.rect.minY < r.maxY && r.minY < o.rect.maxY }
            func overlapsColumns(_ o: PaneLayout.Pane) -> Bool { o.rect.minX < r.maxX && r.minX < o.rect.maxX }
            // The neighbours on each side, by their frames.
            let leftOf = others.filter { overlapsRows($0) && (0...reach).contains(r.minX - $0.rect.maxX) }.compactMap { byId[$0.id] }
            let rightOf = others.filter { overlapsRows($0) && (0...reach).contains($0.rect.minX - r.maxX) }.compactMap { byId[$0.id] }
            let above = others.filter { overlapsColumns($0) && (0...reach).contains(r.minY - $0.rect.maxY) }.compactMap { byId[$0.id] }
            let below = others.filter { overlapsColumns($0) && (0...reach).contains($0.rect.minY - r.maxY) }.compactMap { byId[$0.id] }
            let half = Self.gutter / 2
            let minX = leftOf.map(\.maxX).max().map { ($0 + frame.minX) / 2 + half } ?? view.minX
            let maxX = rightOf.map(\.minX).min().map { ($0 + frame.maxX) / 2 - half } ?? view.maxX
            let minY = above.map(\.maxY).max().map { ($0 + frame.minY) / 2 + half } ?? view.minY
            let maxY = below.map(\.minY).min().map { ($0 + frame.maxY) / 2 - half } ?? view.maxY
            return Card(id: pane.id, rect: CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY)),
                        left: !leftOf.isEmpty, right: !rightOf.isEmpty, top: !above.isEmpty, bottom: !below.isEmpty)
        }
    }
}

/// A grab strip over each divider of a split. Dragging it lays a preview of
/// the two sides over the real terminal, their edge following the pointer to
/// the pixel; the engine is only asked once, as the pointer is let go, to move
/// the divider by the cells the edge travelled. Double-click shares the
/// panes evenly.
struct PaneDividers: View {
    let layout: PaneLayout
    let cells: CellGeometry
    /// Moves the divider beside a pane of the first side: right or down by a
    /// positive number of cells, left or up by a negative one.
    let move: (_ pane: String, _ sideBySide: Bool, _ cells: Int) -> Void
    let equalize: (_ pane: String) -> Void

    /// How wide the strip is, across the divider.
    static let grab: CGFloat = 10
    /// The fewest cells a side keeps, however far the edge is pulled.
    static let minimumCells: CGFloat = 6
    /// How far the preview's cards stand apart, matching the split's cards.
    static let gap: CGFloat = PaneCards.gutter

    /// The divider being dragged, and how far from where it began.
    @State private var pull: (index: Int, points: CGFloat)?

    var body: some View {
        if layout.panes.count > 1 {
            GeometryReader { proxy in
                let cells = self.cells.isKnown ? self.cells : .stretched(layout, over: proxy.size)
                let view = CGRect(origin: .zero, size: proxy.size)
                let frames = Dictionary(uniqueKeysWithValues: layout.frames(in: proxy.size, cells: cells).map { ($0.0.id, $0.1) })
                let dividers = layout.splits.map { Self.divider(for: $0, frames: frames, cells: cells, in: view) }
                ZStack(alignment: .topLeading) {
                    if let pull, dividers.indices.contains(pull.index), let divider = dividers[pull.index] {
                        Preview(divider: divider, points: pull.points, cells: cells)
                    }
                    ForEach(Array(layout.splits.enumerated()), id: \.offset) { index, split in
                        if let divider = dividers[index], let first = split.firstPaneIds.first {
                            Strip(divider: divider, sideBySide: split.sideBySide,
                                  cell: split.sideBySide ? cells.cellSize.width : cells.cellSize.height,
                                  pulled: { points in pull = points.map { (index, $0) } },
                                  commit: { count in move(first, split.sideBySide, count) },
                                  equalize: { equalize(first) })
                                .frame(width: divider.strip.width, height: divider.strip.height)
                                .offset(x: divider.strip.minX, y: divider.strip.minY)
                        }
                    }
                }
            }
        }
    }

    /// Where a divider sits, how far it may travel either way, and the two
    /// regions it divides, in points.
    struct Divider {
        let strip: CGRect
        let travel: ClosedRange<CGFloat>
        let sideBySide: Bool
        /// The first side's region and the second's, spread to the view's
        /// edge where they reach it, as the cards are.
        let first: CGRect
        let second: CGRect
    }

    static func divider(for split: EngineLayout.Split, frames: [String: CGRect], cells: CellGeometry, in view: CGRect) -> Divider? {
        let firstFrames = split.firstPaneIds.compactMap { frames[$0] }
        let secondFrames = split.secondPaneIds.compactMap { frames[$0] }
        guard let a = firstFrames.reduce(nil, { $0?.union($1) ?? $1 }),
              let b = secondFrames.reduce(nil, { $0?.union($1) ?? $1 }) else { return nil }
        let span = a.union(b)
        // Whole of the view along the divider, where the panes reach its edges.
        let slack = max(cells.cellSize.width, cells.cellSize.height) * 2
        func spread(_ rect: CGRect) -> CGRect {
            var r = rect
            if r.minX - view.minX <= slack { r = CGRect(x: view.minX, y: r.minY, width: r.maxX - view.minX, height: r.height) }
            if view.maxX - r.maxX <= slack { r = CGRect(x: r.minX, y: r.minY, width: view.maxX - r.minX, height: r.height) }
            if r.minY - view.minY <= slack { r = CGRect(x: r.minX, y: view.minY, width: r.width, height: r.maxY - view.minY) }
            if view.maxY - r.maxY <= slack { r = CGRect(x: r.minX, y: r.minY, width: r.width, height: view.maxY - r.minY) }
            return r
        }
        if split.sideBySide {
            let keep = minimumCells * cells.cellSize.width
            let x = (a.maxX + b.minX) / 2
            return Divider(strip: CGRect(x: x - grab / 2, y: span.minY, width: grab, height: span.height),
                           travel: min(0, keep - a.width)...max(0, b.width - keep), sideBySide: true,
                           first: spread(a), second: spread(b))
        }
        let keep = minimumCells * cells.cellSize.height
        let y = (a.maxY + b.minY) / 2
        return Divider(strip: CGRect(x: span.minX, y: y - grab / 2, width: span.width, height: grab),
                       travel: min(0, keep - a.height)...max(0, b.height - keep), sideBySide: false,
                       first: spread(a), second: spread(b))
    }

    /// The two sides as they would be, laid over the terminal: opaque, so the
    /// real panes underneath are out of sight until the divider has moved.
    private struct Preview: View {
        let divider: Divider
        let points: CGFloat
        let cells: CellGeometry

        /// Both sides with the edge `points` from where it began.
        private var rects: (first: CGRect, second: CGRect) {
            // As the cards meet: half the gutter either side of the gap's middle.
            let half = PaneCards.gutter / 2
            if divider.sideBySide {
                let edge = (divider.first.maxX + divider.second.minX) / 2 + points
                return (CGRect(x: divider.first.minX, y: divider.first.minY, width: max(0, edge - half - divider.first.minX), height: divider.first.height),
                        CGRect(x: edge + half, y: divider.second.minY, width: max(0, divider.second.maxX - edge - half), height: divider.second.height))
            }
            let edge = (divider.first.maxY + divider.second.minY) / 2 + points
            return (CGRect(x: divider.first.minX, y: divider.first.minY, width: divider.first.width, height: max(0, edge - half - divider.first.minY)),
                    CGRect(x: divider.second.minX, y: edge + half, width: divider.second.width, height: max(0, divider.second.maxY - edge - half)))
        }

        var body: some View {
            let r = PaneCards.radius
            let (first, second) = rects
            ZStack(alignment: .topLeading) {
                Theme.chrome
                    .frame(width: divider.first.union(divider.second).width, height: divider.first.union(divider.second).height)
                    .offset(x: divider.first.union(divider.second).minX, y: divider.first.union(divider.second).minY)
                card(first, rounded: divider.sideBySide ? (tl: false, bl: false, tr: true, br: true) : (tl: false, bl: true, tr: false, br: true), radius: r)
                card(second, rounded: divider.sideBySide ? (tl: true, bl: true, tr: false, br: false) : (tl: true, bl: false, tr: true, br: false), radius: r)
            }
            .allowsHitTesting(false)
        }

        private func card(_ rect: CGRect, rounded: (tl: Bool, bl: Bool, tr: Bool, br: Bool), radius r: CGFloat) -> some View {
            let shape = UnevenRoundedRectangle(topLeadingRadius: rounded.tl ? r : 0, bottomLeadingRadius: rounded.bl ? r : 0,
                                               bottomTrailingRadius: rounded.br ? r : 0, topTrailingRadius: rounded.tr ? r : 0)
            let columns = cells.cellSize.width > 0 ? Int(rect.width / cells.cellSize.width) : 0
            let rows = cells.cellSize.height > 0 ? Int(rect.height / cells.cellSize.height) : 0
            return shape.fill(Theme.terminalBackground)
                .overlay(shape.strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
                .overlay {
                    Text("\(columns) × \(rows)")
                        .font(Theme.interfaceFont(11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private struct Strip: View {
        let divider: Divider
        let sideBySide: Bool
        let cell: CGFloat
        /// Tells the preview how far the edge is from where it began, in points;
        /// nil when the drag is over.
        let pulled: (CGFloat?) -> Void
        let commit: (Int) -> Void
        let equalize: () -> Void
        @State private var hovered = false

        var body: some View {
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside != hovered else { return }
                    hovered = inside
                    if inside { (sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                }
                .onDisappear { if hovered { NSCursor.pop(); hovered = false } }
                // Global space: the strip's own space would shift under the
                // pointer as the preview moves.
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            let travelled = sideBySide ? value.translation.width : value.translation.height
                            pulled(min(max(travelled, divider.travel.lowerBound), divider.travel.upperBound))
                        }
                        .onEnded { value in
                            let travelled = sideBySide ? value.translation.width : value.translation.height
                            let points = min(max(travelled, divider.travel.lowerBound), divider.travel.upperBound)
                            let cells = cell > 0 ? Int((points / cell).rounded()) : 0
                            pulled(nil)
                            if cells != 0 { commit(cells) }
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { equalize() })
        }
    }
}

/// Where the find bar sits: the top right of the pane it searches, clear of
/// the pane's edge, or the terminal's top right while the layout is unknown.
/// A pane narrower than the bar pushes it right, never off the terminal's
/// left edge, where its field was cut away.
struct OutputFindHost: View {
    @ObservedObject var find: OutputFindState
    let layout: PaneLayout?
    let cells: CellGeometry
    @State private var barWidth: CGFloat = 0

    var body: some View {
        if find.isOpen {
            GeometryReader { proxy in
                let frame = layout?.frames(in: proxy.size, cells: cells).first { $0.0.id == find.paneId }?.1
                    ?? CGRect(origin: .zero, size: proxy.size)
                let inset = Theme.Space.lg
                let x = min(max(frame.maxX - inset - barWidth, inset), max(inset, proxy.size.width - inset - barWidth))
                OutputFindBar(find: find)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                    .offset(x: x, y: frame.minY + Theme.Space.md)
            }
            .transition(.opacity)
        }
    }
}
