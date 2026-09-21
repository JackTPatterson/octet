// Draws the install window's background: an arrow from where the app's icon sits
// to where the Applications folder sits, and a line saying what to do.
//
// Usage: swift scripts/dmg-background.swift <out.png> <scale> <app-name>
// The layout constants here are in window points and must match make-dmg.sh.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <scale> <app-name>\n".data(using: .utf8)!)
    exit(1)
}

let width = 660.0, height = 400.0
let iconY = 170.0            // icon centres, measured from the top as Finder does
let appX = 180.0, applicationsX = 480.0

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
bitmap.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// AppKit draws from the bottom left; Finder places icons from the top left.
func y(_ fromTop: Double) -> Double { height - fromTop }

NSGradient(colors: [
    NSColor(calibratedWhite: 0.985, alpha: 1),
    NSColor(calibratedWhite: 0.93, alpha: 1),
])?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// The arrow, centred between the two icons.
let ink = NSColor(calibratedWhite: 0.62, alpha: 1)
let arrow = NSBezierPath()
let middle = (appX + applicationsX) / 2
let half = 38.0, head = 13.0
arrow.move(to: NSPoint(x: middle - half, y: y(iconY)))
arrow.line(to: NSPoint(x: middle + half, y: y(iconY)))
arrow.move(to: NSPoint(x: middle + half - head, y: y(iconY) + head))
arrow.line(to: NSPoint(x: middle + half, y: y(iconY)))
arrow.line(to: NSPoint(x: middle + half - head, y: y(iconY) - head))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
ink.setStroke()
arrow.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let caption = NSAttributedString(string: "Drag \(arguments[3]) into Applications to install", attributes: [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
    .paragraphStyle: paragraph,
])
caption.draw(in: NSRect(x: 0, y: y(330), width: width, height: 20))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
