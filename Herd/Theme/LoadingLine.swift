import AppKit
import SwiftUI

/// Herd's loading indicator in place of the system spinner: a line grows
/// left to right to full width, holds, then retracts left to right until it
/// is gone; then the same from the right; and again. Reduce Motion shows a
/// still, dim line.
struct LoadingLine: View {
    var width: CGFloat = 24
    var thickness: CGFloat = 2
    var color: Color = Theme.accent

    /// Seconds for each stroke, and the pauses between them.
    private static let stroke = 0.36
    private static let hold = 0.2
    private static let gap = 0.16
    private static var cycle: Double { 4 * stroke + 2 * hold + 2 * gap }

    var body: some View {
        Group {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                Capsule().fill(color.opacity(0.5)).frame(width: width, height: thickness)
            } else {
                TimelineView(.animation) { context in
                    let (start, end) = Self.extent(at: context.date.timeIntervalSinceReferenceDate)
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, (end - start) * width), height: thickness)
                        .offset(x: start * width)
                        .frame(width: width, height: max(thickness, 4), alignment: .leading)
                }
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
