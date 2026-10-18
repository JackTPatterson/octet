import SwiftUI

/// A placeholder block for content that's still loading. Blocks breathe
/// in a wave down the page: each one's pulse lags by how far down it sits,
/// so a skeleton shimmers top to bottom rather than blinking as one.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 4
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var offset: CGFloat = 0

    /// Seconds per breath, and how far apart (in points) blocks a full
    /// breath out of step sit.
    private static let period = 1.6
    private static let wavelength: CGFloat = 520

    var body: some View {
        let animates = motion.animates(.agentStatus)
        TimelineView(.animation(paused: !animates)) { context in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardSelected)
            if animates {
                let time = context.date.timeIntervalSinceReferenceDate / Self.period
                let phase = (time - Double(offset / Self.wavelength)) * 2 * .pi
                // Eased breath between 45% and 100%.
                shape.opacity(0.45 + 0.55 * (0.5 + 0.5 * cos(phase)))
            } else {
                shape
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background {
            GeometryReader { geometry in
                let y = geometry.frame(in: .global).minY + geometry.frame(in: .global).minX * 0.25
                Color.clear
                    .onAppear { offset = y }
                    .onChange(of: y) { _, new in offset = new }
            }
        }
    }
}

/// Circles and other shapes that stand in for content, breathing in step
/// with the blocks around them.
struct SkeletonCircle: View {
    var size: CGFloat

    var body: some View {
        SkeletonBlock(width: size, height: size, radius: size / 2)
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

/// A line chart revealed by a clip while the real one's data loads: one
/// fixed curve wipes in left to right with easing, rests, fades and wipes
/// in again. The line itself never moves.
struct LoadingLineChart: View {
    var color: Color = Theme.accent
    @ObservedObject private var motion = MotionPreferences.shared

    /// Seconds per loop: draw, rest, fade.
    private static let cycle = 1.9

    var body: some View {
        let animates = motion.animates(.agentStatus)
        TimelineView(.animation(paused: !animates)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let t = animates ? time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle : 0.6
                // Draw over the first 72% with ease-in-out, a short hold,
                // then fade over the last 20% with ease-in.
                let drawn = animates ? Self.easeInOut(min(1, t / 0.72)) : 1
                let fade = t < 0.8 ? 1 : 1 - Self.easeIn((t - 0.8) / 0.2)

                for row in 0...3 {
                    let y = min(size.height * CGFloat(row) / 3, size.height - 1)
                    canvas.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                with: .color(Theme.divider.opacity(0.6)))
                }

                let points = Self.points(count: 64, in: size)
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

    /// A sine wave, two full periods across the chart.
    private static func points(count: Int, in size: CGSize) -> [CGPoint] {
        (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            let value = 0.5 + 0.3 * sin(fraction * 2 * .pi * 2)
            return CGPoint(x: size.width * CGFloat(fraction), y: size.height * (1 - CGFloat(value)))
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
