import AppKit
import SwiftUI

/// Octet's loading indicator in place of the system spinner: a line grows
/// left to right to full width, holds, then retracts left to right until it
/// is gone; then the same from the right; and again. Reduce Motion shows a
/// still, dim line.
struct LoadingLine: View {
    var width: CGFloat = 24
    var thickness: CGFloat = 2
    var color: Color = Theme.accent
    @ObservedObject private var motion = MotionPreferences.shared

    /// Seconds for each stroke, and the pauses between them.
    fileprivate static let stroke = 0.36
    fileprivate static let hold = 0.2
    fileprivate static let gap = 0.16
    fileprivate static var cycle: Double { 4 * stroke + 2 * hold + 2 * gap }

    var body: some View {
        Group {
            if !motion.animates(.agentStatus) {
                Capsule().fill(color.opacity(0.5)).frame(width: width, height: thickness)
            } else {
                LoadingLineLayer(color: color, thickness: thickness, duration: Self.cycle)
            }
        }
        .frame(width: width, height: max(thickness, 4))
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// CSS `cubic-bezier(0, 0.55, 0.45, 1)`: a quick start that settles
    /// gently. Solves the curve's x for `progress`, then returns its y.
    static func curve(_ progress: Double) -> Double {
        let (x1, y1, x2, y2) = (0.0, 0.55, 0.45, 1.0)
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        let x = min(1, max(0, progress))
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<24 {
            let current = bezier(t, x1, x2)
            if abs(current - x) < 1e-5 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezier(t, y1, y2)
    }

    /// Where the line runs, as fractions of the width, at a moment.
    static func extent(at time: TimeInterval) -> (start: Double, end: Double) {
        var t = time.truncatingRemainder(dividingBy: cycle)
        let eased = { (p: Double) in Self.curve(p) }
        // Left to right: grow, hold, retract, pause.
        if t < stroke { return (0, eased(t / stroke)) }
        t -= stroke
        if t < hold { return (0, 1) }
        t -= hold
        if t < stroke { return (eased(t / stroke), 1) }
        t -= stroke
        if t < gap { return (1, 1) }
        t -= gap
        // Right to left: grow, hold, retract, pause.
        if t < stroke { return (1 - eased(t / stroke), 1) }
        t -= stroke
        if t < hold { return (0, 1) }
        t -= hold
        if t < stroke { return (0, 1 - eased(t / stroke)) }
        return (0, 0)
    }
}

/// Runs the loading stroke on Core Animation's render server. The previous
/// TimelineView implementation invalidated every SwiftUI row at display rate;
/// a transcript with several live tools could therefore rebuild hundreds of
/// view bodies per second. A stroked CAShapeLayer produces the same motion
/// without waking the transcript tree for each frame.
private struct LoadingLineLayer: NSViewRepresentable {
    let color: Color
    let thickness: CGFloat
    let duration: TimeInterval

    func makeNSView(context: Context) -> LoadingLineNSView {
        let view = LoadingLineNSView()
        view.configure(color: NSColor(color), thickness: thickness, duration: duration)
        return view
    }

    func updateNSView(_ view: LoadingLineNSView, context: Context) {
        view.configure(color: NSColor(color), thickness: thickness, duration: duration)
    }
}

private final class LoadingLineNSView: NSView {
    private let stroke = CAShapeLayer()
    private var thickness: CGFloat = 0
    private var duration: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        stroke.fillColor = NSColor.clear.cgColor
        stroke.lineCap = .round
        layer?.addSublayer(stroke)
    }

    required init?(coder: NSCoder) { nil }

    func configure(color: NSColor, thickness: CGFloat, duration: TimeInterval) {
        stroke.strokeColor = color.cgColor
        stroke.lineWidth = thickness
        let animationChanged = self.duration != duration || stroke.animation(forKey: "octet.loading") == nil
        self.thickness = thickness
        self.duration = duration
        needsLayout = true
        if animationChanged { installAnimation() }
    }

    override func layout() {
        super.layout()
        stroke.frame = bounds
        let inset = min(thickness / 2, bounds.width / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: bounds.midY))
        path.addLine(to: CGPoint(x: max(inset, bounds.width - inset), y: bounds.midY))
        stroke.path = path
    }

    private func installAnimation() {
        guard duration > 0 else { return }
        let strokeDuration = LoadingLine.stroke / duration
        let holdDuration = LoadingLine.hold / duration
        let gapDuration = LoadingLine.gap / duration
        let a = strokeDuration
        let b = a + holdDuration
        let c = b + strokeDuration
        let d = c + gapDuration
        let e = d + strokeDuration
        let f = e + holdDuration
        let g = f + strokeDuration
        let times = [0, a, b, c, d, e, f, g, 1].map { NSNumber(value: $0) }
        let ease = CAMediaTimingFunction(controlPoints: 0, 0.55, 0.45, 1)
        let linear = CAMediaTimingFunction(name: .linear)

        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 0, 1, 1, 0, 0, 0, 0]
        start.keyTimes = times
        start.timingFunctions = [linear, linear, ease, linear, ease, linear, linear, linear]

        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1, 1, 1, 1, 1, 0, 0]
        end.keyTimes = times
        end.timingFunctions = [ease, linear, linear, linear, linear, linear, ease, linear]

        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = duration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        // A common media-time origin keeps every visible indicator in phase.
        group.beginTime = 0
        stroke.add(group, forKey: "octet.loading")
    }
}
