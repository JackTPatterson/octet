import CoreGraphics

/// Which of the status bar's items are out of sight in a bar too narrow for
/// them all: the bar fades at an edge with more beyond it, and the hidden
/// items are listed in its overflow menu so none is only reachable by
/// scrolling sideways.
enum StatusBarOverflow {
    struct Span: Equatable {
        let id: String
        let minX: CGFloat
        let maxX: CGFloat
    }

    struct Edges: Equatable {
        var leading = false
        var trailing = false
        /// In bar order.
        var hidden: [String] = []
    }

    /// `spans` are the items in the bar's visible coordinates (0 is its
    /// leading edge), as scrolled. An item counts as hidden when less than
    /// `shown` of it is in view.
    static func edges(of spans: [Span], width: CGFloat, shown: CGFloat = 0.6) -> Edges {
        guard width > 0, !spans.isEmpty else { return Edges() }
        let ordered = spans.sorted { $0.minX < $1.minX }
        let hidden = ordered.filter { span in
            let size = span.maxX - span.minX
            guard size > 0 else { return false }
            let visible = max(0, min(span.maxX, width) - max(span.minX, 0))
            return visible / size < shown
        }
        // A point of slack, so rounding doesn't fade a bar that fits.
        return Edges(leading: (ordered.first?.minX ?? 0) < -1,
                     trailing: (ordered.last?.maxX ?? 0) > width + 1,
                     hidden: hidden.map(\.id))
    }
}
