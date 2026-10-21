import SwiftUI

// The Agents tab's tree edges, after AffectUI's agent tree: from a port on
// the parent's mark, a line runs down and turns into each child. A new edge
// draws itself out of the port, siblings a beat apart; a leaving one pulls
// back in. One layer over the whole tree, so an edge is one stroke.

/// Where a mark sits in its tree, and which mark its edge comes from.
struct TreeNodeAnchor {
    let bounds: Anchor<CGRect>
    let parent: String?
    /// Drawing order: siblings draw out in it.
    let order: Int
}

struct TreeNodeKey: PreferenceKey {
    static let defaultValue: [String: TreeNodeAnchor] = [:]
    static func reduce(value: inout [String: TreeNodeAnchor], nextValue: () -> [String: TreeNodeAnchor]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// This mark is a node of the tree drawn by an enclosing `treeEdges()`.
    func treeNode(_ id: String, parent: String?, order: Int) -> some View {
        anchorPreference(key: TreeNodeKey.self, value: .bounds) {
            [id: TreeNodeAnchor(bounds: $0, parent: parent, order: order)]
        }
    }

    /// Draws the edges between the `treeNode` marks inside.
    func treeEdges() -> some View {
        overlayPreferenceValue(TreeNodeKey.self) { nodes in
            GeometryReader { proxy in
                TreeEdgeLayer(nodes: nodes.mapValues { (proxy[$0.bounds], $0.parent, $0.order) })
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

enum TreeEdgeStyle {
    static let ink = Theme.textPrimary
    static let lineWidth: CGFloat = 1
    static let portRadius: CGFloat = 2.75
    static let corner: CGFloat = 5.5
    /// The mark is 14pt in its frame: the port sits this far under its
    /// centre, just below the mark.
    static let portDrop: CGFloat = 7 + 5.5
    static let ease = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.42)
    static let retract = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.28)
    static let stagger = 0.06
}

private struct TreeEdgeLayer: View {
    let nodes: [String: (rect: CGRect, parent: String?, order: Int)]

    var body: some View {
        let edges = nodes.compactMap { id, node -> Edge? in
            guard let parent = node.parent, let from = nodes[parent] else { return nil }
            return Edge(id: id, parentID: parent, order: node.order,
                        port: CGPoint(x: from.rect.midX, y: from.rect.midY + TreeEdgeStyle.portDrop),
                        end: CGPoint(x: node.rect.minX, y: node.rect.midY))
        }
        .sorted { $0.order < $1.order }
        // A parent's children draw out one after another.
        let siblingIndex: [String: Int] = Dictionary(grouping: edges, by: \.parentID)
            .values.reduce(into: [:]) { result, siblings in
                for (index, edge) in siblings.enumerated() { result[edge.id] = index }
            }
        let ports = Dictionary(grouping: edges, by: \.parentID).compactMapValues(\.first?.port)
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                TreeEdgeView(port: edge.port, end: edge.end,
                             delay: Double(siblingIndex[edge.id] ?? 0) * TreeEdgeStyle.stagger)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .modifier(active: TreeEdgeTrim(progress: 0), identity: TreeEdgeTrim(progress: 1))
                            .animation(TreeEdgeStyle.retract)))
            }
            // Over the lines, so each starts under its port.
            ForEach(ports.sorted { $0.key < $1.key }, id: \.key) { _, port in
                TreePort()
                    .position(port)
                    .transition(.opacity.animation(.easeOut(duration: 0.28)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Edge: Identifiable {
        let id: String
        let parentID: String
        let order: Int
        let port: CGPoint
        let end: CGPoint
    }
}

/// The hollow ring a parent's edges leave from.
private struct TreePort: View {
    var body: some View {
        Circle()
            .fill(Theme.sidebar)
            .overlay(Circle().strokeBorder(TreeEdgeStyle.ink, lineWidth: TreeEdgeStyle.lineWidth))
            .frame(width: TreeEdgeStyle.portRadius * 2 + TreeEdgeStyle.lineWidth,
                   height: TreeEdgeStyle.portRadius * 2 + TreeEdgeStyle.lineWidth)
    }
}

/// One edge, drawn out of its port when it first appears.
private struct TreeEdgeView: View {
    let port: CGPoint
    let end: CGPoint
    let delay: Double
    @ObservedObject private var motion = MotionPreferences.shared
    @Environment(\.treeEdgeShown) private var shown
    @State private var drawn = false

    var body: some View {
        TreeEdgeShape(port: port, end: end, progress: drawn ? shown : 0)
            .stroke(TreeEdgeStyle.ink, style: StrokeStyle(lineWidth: TreeEdgeStyle.lineWidth, lineCap: .round))
            .onAppear {
                guard motion.animates(.sidebar) else { drawn = true; return }
                withAnimation(TreeEdgeStyle.ease.delay(delay)) { drawn = true }
            }
    }
}

/// Retracts a leaving edge back into its port: the share of it still drawn,
/// handed to the edge as it animates down.
private struct TreeEdgeTrim: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.treeEdgeShown, progress)
    }
}

private struct TreeEdgeShownKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var treeEdgeShown: CGFloat {
        get { self[TreeEdgeShownKey.self] }
        set { self[TreeEdgeShownKey.self] = newValue }
    }
}

/// Down from the port, a rounded turn, and in to the child's mark. Animates
/// its ends, so it follows rows that move, and how much of it is drawn.
struct TreeEdgeShape: Shape {
    var port: CGPoint
    var end: CGPoint
    var progress: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(port.x, port.y), AnimatablePair(AnimatablePair(end.x, end.y), progress)) }
        set {
            port = CGPoint(x: newValue.first.first, y: newValue.first.second)
            end = CGPoint(x: newValue.second.first.first, y: newValue.second.first.second)
            progress = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(TreeEdgeStyle.corner, max(0, end.y - port.y), max(0, end.x - port.x))
        var path = Path()
        path.move(to: port)
        path.addLine(to: CGPoint(x: port.x, y: end.y - radius))
        path.addQuadCurve(to: CGPoint(x: port.x + radius, y: end.y), control: CGPoint(x: port.x, y: end.y))
        path.addLine(to: end)
        return progress >= 1 ? path : path.trimmedPath(from: 0, to: max(0, progress))
    }
}
