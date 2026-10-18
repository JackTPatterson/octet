import SwiftUI

/// A placeholder block for content that's still loading.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.cardSelected)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

extension View {
    /// Breathes while content loads; still when motion is reduced.
    func skeletonPulse() -> some View { modifier(SkeletonPulse()) }
}

private struct SkeletonPulse: ViewModifier {
    @State private var dim = false
    @ObservedObject private var motion = MotionPreferences.shared

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard motion.animates(.agentStatus) else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// A line chart that draws itself while the real one's data loads: a soft
/// curve eases in across faint gridlines, rests, fades out and draws again.
/// The curve's shape drifts slowly with time, so no loop jumps.
struct LoadingLineChart: View {
    var color: Color = Theme.accent
    @ObservedObject private var motion = MotionPreferences.shared

    /// Seconds per loop: draw, rest, fade.
    private static let cycle = 2.8

    var body: some View {
        let animates = motion.animates(.agentStatus)
        TimelineView(.animation(paused: !animates)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let t = animates ? time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle : 0.6
                // Draw over the first 55% with ease-in-out, rest, then fade
                // over the last 25% with ease-in.
                let drawn = animates ? Self.easeInOut(min(1, t / 0.55)) : 1
                let fade = t < 0.75 ? 1 : 1 - Self.easeIn((t - 0.75) / 0.25)

                for row in 0...3 {
                    let y = min(size.height * CGFloat(row) / 3, size.height - 1)
                    canvas.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                with: .color(Theme.divider.opacity(0.6)))
                }

                // A slow drift, not a new curve per loop.
                let drift = animates ? time * 0.18 : 0
                let points = Self.points(count: 20, drift: drift, in: size)
                let line = Self.smooth(points)
                var area = line
                if let last = points.last, let first = points.first {
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                }

                // Line and fill revealed together, left to right, so the
                // fill's edge always sits under the line's tip.
                let tip = size.width * CGFloat(drawn)
                canvas.drawLayer { layer in
                    layer.clip(to: Path(CGRect(x: -2, y: -2, width: tip + 2, height: size.height + 4)))
                    layer.fill(area, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.22 * fade), color.opacity(0)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    layer.stroke(line, with: .color(color.opacity(0.8 * fade)),
                                 style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("Loading chart")
    }

    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func easeIn(_ x: Double) -> Double { x * x * x }

    /// A plausible usage curve: a few bumps that shift gently over time.
    private static func points(count: Int, drift: Double, in size: CGSize) -> [CGPoint] {
        (0..<count).map { index in
            let x = size.width * CGFloat(index) / CGFloat(count - 1)
            let phase = Double(index) * 0.6
            let value = 0.38 + 0.2 * sin(phase + drift) + 0.12 * sin(phase * 2.1 - drift * 1.3) + 0.07 * cos(phase * 0.6 + drift * 0.7)
            let y = size.height * (1 - CGFloat(min(0.9, max(0.08, value))))
            return CGPoint(x: x, y: y)
        }
    }

    /// Catmull-Rom through the points: one smooth curve.
    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let p0 = points[max(index - 2, 0)], p1 = points[index - 1]
            let p2 = points[index], p3 = points[min(index + 1, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
