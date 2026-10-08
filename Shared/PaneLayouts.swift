import Foundation

/// A way to split a tab into panes, as a plugin describes it: like the
/// layout picker in a trading app, two, three or four views side by side,
/// stacked or in a grid. A layout is a tree of `"pane"`s inside
/// `{"columns": [...]}` and `{"rows": [...]}`, each optionally `"weights"`
/// for how much room each part gets:
///
///     {"columns": ["pane", {"rows": ["pane", "pane"]}], "weights": [2, 1]}
///
/// is one wide pane on the left with two stacked on the right.
indirect enum PaneLayoutNode: Codable, Equatable {
    case pane
    case split(axis: Axis, children: [PaneLayoutNode], weights: [Double])

    enum Axis: String, Codable { case columns, rows }

    static let maxPanes = 9
    static let maxDepth = 4

    // MARK: - JSON

    private enum Keys: String, CodingKey { case columns, rows, weights }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let word = try? single.decode(String.self) {
            guard word == "pane" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected \"pane\""))
            }
            self = .pane
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        let axis: Axis
        let children: [PaneLayoutNode]
        if let columns = try container.decodeIfPresent([PaneLayoutNode].self, forKey: .columns) {
            axis = .columns
            children = columns
        } else if let rows = try container.decodeIfPresent([PaneLayoutNode].self, forKey: .rows) {
            axis = .rows
            children = rows
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected columns or rows"))
        }
        let weights = try container.decodeIfPresent([Double].self, forKey: .weights) ?? Array(repeating: 1, count: children.count)
        self = .split(axis: axis, children: children, weights: weights)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane:
            var single = encoder.singleValueContainer()
            try single.encode("pane")
        case .split(let axis, let children, let weights):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(children, forKey: axis == .columns ? .columns : .rows)
            if weights.contains(where: { $0 != 1 }) { try container.encode(weights, forKey: .weights) }
        }
    }

    // MARK: - Shape

    var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, let children, _): children.reduce(0) { $0 + $1.paneCount }
        }
    }

    var depth: Int {
        switch self {
        case .pane: 0
        case .split(_, let children, _): 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    /// Why it can't be used, or nil.
    var problem: String? {
        if paneCount > Self.maxPanes { return "has more than \(Self.maxPanes) panes" }
        if depth > Self.maxDepth { return "nests deeper than \(Self.maxDepth)" }
        return splitProblem
    }

    private var splitProblem: String? {
        guard case .split(_, let children, let weights) = self else { return nil }
        if children.count < 2 { return "splits into fewer than two parts" }
        if weights.count != children.count { return "has \(weights.count) weights for \(children.count) parts" }
        if weights.contains(where: { !($0 > 0) || !$0.isFinite }) { return "has a weight that isn't a positive number" }
        return children.lazy.compactMap(\.splitProblem).first
    }

    /// Each pane's frame in a unit square, left to right and top to bottom,
    /// for drawing the layout's picture.
    func rects(in frame: Rect = Rect(x: 0, y: 0, width: 1, height: 1)) -> [Rect] {
        switch self {
        case .pane:
            return [frame]
        case .split(let axis, let children, let weights):
            let total = weights.reduce(0, +)
            guard total > 0 else { return [] }
            var offset = 0.0
            var rects: [Rect] = []
            for (child, weight) in zip(children, weights) {
                let share = weight / total
                let part = axis == .columns
                    ? Rect(x: frame.x + offset * frame.width, y: frame.y, width: share * frame.width, height: frame.height)
                    : Rect(x: frame.x, y: frame.y + offset * frame.height, width: frame.width, height: share * frame.height)
                rects += child.rects(in: part)
                offset += share
            }
            return rects
        }
    }

    struct Rect: Equatable {
        var x: Double, y: Double, width: Double, height: Double
    }

    // MARK: - For the session server

    /// The tree `layout.apply` takes: binary splits, each pane a shell in `cwd`.
    /// A split of three is the first part, then a split of the other two,
    /// with the ratio that keeps each part its share.
    func engineTree(cwd: String) -> [String: Any] {
        switch self {
        case .pane:
            return ["type": "pane", "cwd": cwd]
        case .split(let axis, let children, let weights):
            guard children.count > 1, let first = children.first else {
                return children.first?.engineTree(cwd: cwd) ?? ["type": "pane", "cwd": cwd]
            }
            let total = weights.reduce(0, +)
            let rest: PaneLayoutNode = children.count == 2
                ? children[1]
                : .split(axis: axis, children: Array(children.dropFirst()), weights: Array(weights.dropFirst()))
            let ratio = total > 0 ? (weights[0] / total) : 0.5
            return [
                "type": "split",
                "direction": axis == .columns ? "right" : "down",
                "ratio": (ratio * 1000).rounded() / 1000,
                "first": first.engineTree(cwd: cwd),
                "second": rest.engineTree(cwd: cwd),
            ]
        }
    }

    /// `layout.apply`'s params: the layout as a new tab.
    func request(title: String, cwd: String, workspaceId: String?) -> [String: Any] {
        var params: [String: Any] = ["tab_label": title, "root": engineTree(cwd: cwd), "focus": true]
        if let workspaceId { params["workspace_id"] = workspaceId }
        return params
    }
}

/// One layout a plugin offers.
struct PaneLayoutContribution: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let layout: PaneLayoutNode
}
