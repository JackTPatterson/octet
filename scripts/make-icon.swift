// Draws Octet's app icon and writes every size macOS asks for into
// Octet/Assets.xcassets/AppIcon.appiconset.
//
// The mark is a terminal's own: a prompt and a block cursor. The cursor is
// built from eight panes, the octet, and one is lit in the default theme's
// accent, the way the app lights the agent that wants you.
//
// Usage: swift scripts/make-icon.swift            (from the repo root)
//        swift scripts/make-icon.swift <out.png>  (one 1024px preview instead)
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Draws the icon into a square of `pixels`, designed on a 1024 grid.
func render(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)   // draw in design units
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // The tile: macOS's icon grid puts an 824pt rounded square on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = color(0x000000, 0.35)
    drop.shadowBlurRadius = 24
    drop.shadowOffset = NSSize(width: 0, height: -12)
    drop.set()
    color(0x0b0b0d).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x23252b), color(0x08080a)])!.draw(in: tilePath, angle: -90)

    // A hairline of light around the tile, so it has an edge on dark backgrounds.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    color(0xffffff, 0.10).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The prompt. Small sizes get heavier strokes and fatter panes so the
    // mark still reads at 16pt.
    let small = pixels <= 64
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 272, y: 672))
    chevron.line(to: NSPoint(x: 432, y: 512))
    chevron.line(to: NSPoint(x: 272, y: 352))
    chevron.lineWidth = small ? 92 : 76
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    // Stroke to a path-shaped clip so the prompt takes the same soft gradient
    // as the panes.
    let outline = chevron.cgPath.copy(strokingWithWidth: chevron.lineWidth, lineCap: .round,
                                      lineJoin: .round, miterLimit: 10)
    NSGraphicsContext.current!.cgContext.addPath(outline)
    NSGraphicsContext.current!.cgContext.clip()
    NSGradient(colors: [color(0xf6f7f9), color(0xc4c8d0)])!
        .draw(in: NSRect(x: 200, y: 280, width: 320, height: 470), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The block cursor: eight panes, two across and four down.
    let cell: CGFloat = small ? 118 : 104
    let gap: CGFloat = small ? 14 : 26
    let radius: CGFloat = small ? 22 : 28
    let width = cell * 2 + gap
    let height = cell * 4 + gap * 3
    let left: CGFloat = 792 - width
    let bottom = (1024 - height) / 2
    let lit = (column: 1, row: 3)   // top right

    for row in 0..<4 {
        for column in 0..<2 {
            let rect = NSRect(x: left + CGFloat(column) * (cell + gap),
                              y: bottom + CGFloat(row) * (cell + gap), width: cell, height: cell)
            let pane = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            if column == lit.column && row == lit.row {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = color(0x19aad8, 0.75)
                glow.shadowBlurRadius = 64
                glow.shadowOffset = .zero
                glow.set()
                color(0x19aad8).setFill()
                pane.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(colors: [color(0x5fd4f7), color(0x1196c2)])!.draw(in: pane, angle: -90)
            } else {
                NSGradient(colors: [color(0xf6f7f9), color(0xc4c8d0)])!.draw(in: pane, angle: -90)
            }
        }
    }
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to path: String) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

if CommandLine.arguments.count == 2 {
    try write(render(pixels: 1024), to: CommandLine.arguments[1])
    exit(0)
}

let directory = "Octet/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(render(pixels: points * scale), to: "\(directory)/\(name)")
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(directory)/Contents.json"))
print("Wrote \(images.count) sizes to \(directory)")
