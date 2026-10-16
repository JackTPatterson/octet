import CoreGraphics
import Foundation

/// Window arrangements made for the displays actually attached, like a
/// trading app's monitor layouts: one window per display, or each display
/// split along its long side so a portrait screen stacks rather than
/// squeezes. Frames are in global screen coordinates (AppKit's, bottom-left
/// origin), one per window, the first for the window it was picked from.
struct MonitorArrangement: Identifiable, Equatable {
    let id: String
    let title: String
    let frames: [CGRect]

    /// Arrangements across every display, then for `current` alone.
    /// `displays` are visible frames; `current` is the index of the display
    /// the window is on, so its windows come first.
    static func across(_ displays: [CGRect], current: Int = 0) -> [MonitorArrangement] {
        guard !displays.isEmpty else { return [] }
        let start = min(max(current, 0), displays.count - 1)
        // The window's own display first, then the others left to right.
        let ordered = [displays[start]] + displays.enumerated()
            .filter { $0.offset != start }.map(\.element).sorted { $0.minX < $1.minX }
        var result: [MonitorArrangement] = []
        if displays.count > 1 {
            result.append(.init(id: "each.1", title: "One on Each Display", frames: ordered))
        }
        for count in [2, 3, 4] {
            let frames = ordered.flatMap { split($0, into: count) }
            let title = displays.count > 1 ? "\(count) on Each Display" : "\(count) Windows"
            result.append(.init(id: "each.\(count)", title: title, frames: frames))
        }
        return result
    }

    /// `display` split into `count` windows along its long side; four make
    /// a grid, three a large one beside (or above) two.
    static func split(_ display: CGRect, into count: Int) -> [CGRect] {
        let landscape = display.width >= display.height
        switch count {
        case ..<2:
            return [display]
        case 4:
            let w = display.width / 2, h = display.height / 2
            return [
                CGRect(x: display.minX, y: display.minY + h, width: w, height: h),
                CGRect(x: display.minX + w, y: display.minY + h, width: w, height: h),
                CGRect(x: display.minX, y: display.minY, width: w, height: h),
                CGRect(x: display.minX + w, y: display.minY, width: w, height: h),
            ].map(rounded)
        case 3:
            if landscape {
                let w = display.width / 2, h = display.height / 2
                return [
                    CGRect(x: display.minX, y: display.minY, width: w, height: display.height),
                    CGRect(x: display.minX + w, y: display.minY + h, width: w, height: h),
                    CGRect(x: display.minX + w, y: display.minY, width: w, height: h),
                ].map(rounded)
            }
            let h = display.height / 3
            return (0..<3).map { CGRect(x: display.minX, y: display.maxY - CGFloat($0 + 1) * h, width: display.width, height: h) }
                .map(rounded)
        default:
            if landscape {
                let w = display.width / CGFloat(count)
                return (0..<count).map { CGRect(x: display.minX + CGFloat($0) * w, y: display.minY, width: w, height: display.height) }
                    .map(rounded)
            }
            let h = display.height / CGFloat(count)
            return (0..<count).map { CGRect(x: display.minX, y: display.maxY - CGFloat($0 + 1) * h, width: display.width, height: h) }
                .map(rounded)
        }
    }

    /// A layout's unit rects (top-left origin), turned to suit a portrait
    /// display: columns become rows, so nothing gets narrower than it is tall.
    static func fitted(_ rects: [PaneLayoutNode.Rect], toPortrait portrait: Bool) -> [PaneLayoutNode.Rect] {
        guard portrait else { return rects }
        return rects.map { PaneLayoutNode.Rect(x: $0.y, y: $0.x, width: $0.height, height: $0.width) }
    }

    private static func rounded(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }
}
