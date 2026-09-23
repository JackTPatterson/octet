// Verification helper: when OCTET_SNAPSHOT_DIR is set, writes window.png (the
// SwiftUI chrome with the terminal's rendered IOSurface composited in place)
// and terminal.txt (visible terminal text) every second. Self-capture needs no
// Screen Recording permission. Adapted from Spikes/TerminalSpike.
import AppKit
import CoreImage
import GhosttyKit
import IOSurface

@MainActor
enum DebugSnapshot {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static var writeInFlight = false
    /// What is covering the terminal right now, by name. One shared flag lost
    /// captures: whichever overlay changed last decided for all of them, and
    /// the terminal image landed on top of a panel that was still open.
    private static var overlays: Set<String> = []

    /// Records whether one named overlay covers the terminal.
    static func overlay(_ name: String, _ visible: Bool) {
        if visible { overlays.insert(name) } else { overlays.remove(name) }
    }

    static var overlayVisible: Bool { !overlays.isEmpty }
    /// Set while a SwiftUI cover sits over part of the terminal.
    static var coverActive = false

    /// Toasts draw over the terminal area, so the composited terminal image
    /// would erase them from the capture.
    @MainActor
    static var overlaysOnTop: Bool {
        overlayVisible || !ToastCenter.shared.visibleToasts.isEmpty || !AgentBannerCenter.shared.banners.isEmpty
            || coverActive
    }
    static func start() {
        // Encoding window PNGs is main-thread heavy: debug builds only.
        #if !DEBUG
        return
        #endif
        guard let dir = ProcessInfo.processInfo.environment["OCTET_SNAPSHOT_DIR"] else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { dump(to: dir) }
        }
        // .common keeps snapshots flowing while modal alerts run.
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func findSurface(in view: NSView) -> TerminalEngine.SurfaceView? {
        if let surface = view as? TerminalEngine.SurfaceView { return surface }
        for sub in view.subviews { if let surface = findSurface(in: sub) { return surface } }
        return nil
    }

    /// Saves secondary windows (Settings, panels) as `window-<title>.png`.
    private static func dumpSecondaryWindows(to dir: String, main: NSWindow) {
        for window in NSApp.windows where window !== main && window.isVisible {
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: rep)
            let name = window.title.isEmpty ? "untitled" : window.title.replacingOccurrences(of: " ", with: "-")
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/window-\(name).png"))
            }
        }
    }

    private static func dump(to dir: String) {
        guard !writeInFlight else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && findSurface(in: $0.contentView!) != nil }),
              let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        dumpSecondaryWindows(to: dir, main: window)
        let chrome = NSImage(size: content.bounds.size)
        chrome.addRepresentation(rep)

        let composed = NSImage(size: content.bounds.size)
        composed.lockFocus()
        chrome.draw(in: content.bounds)
        let toasts = ToastCenter.shared.visibleToasts
        var info = "window=\(window.frame) key=\(window.isKeyWindow)\n"
        info += "toasts=\(toasts.map { "[\($0.style)] \($0.title)\($0.detail.map { " — \($0)" } ?? "")" })\n"
        info += "overlays=\(overlays.sorted()) cover=\(coverActive)\n"
        if let surfaceView = findSurface(in: content) {
            let frame = surfaceView.convert(surfaceView.bounds, to: content)
            if let clip = surfaceView.superview as? TopRowClippingView {
                let clipFrame = clip.convert(clip.bounds, to: content)
                NSBezierPath(rect: content.isFlipped
                    ? NSRect(x: clipFrame.minX, y: content.bounds.height - clipFrame.maxY, width: clipFrame.width, height: clipFrame.height)
                    : clipFrame).setClip()
            }
            info += "terminal=\(frame) firstResponder=\(window.firstResponder === surfaceView)\n"
            let contents = surfaceView.layer?.contents ?? surfaceView.layer?.sublayers?.first?.contents
            if !overlaysOnTop, toasts.isEmpty, let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let ioSurface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let image = CIImage(ioSurface: ioSurface)
                if let cg = ciContext.createCGImage(image, from: image.extent) {
                    NSImage(cgImage: cg, size: frame.size).draw(in: content.isFlipped
                        ? NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                        : frame)
                }
            }
            if let surface = surfaceView.surface {
                var text = ghostty_text_s()
                let selection = ghostty_selection_s(
                    top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                    bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                    rectangle: false
                )
                if ghostty_surface_read_text(surface, selection, &text) {
                    info += String(cString: text.text)
                    ghostty_surface_free_text(surface, &text)
                }
            }
        }
        composed.unlockFocus()
        guard let image = composed.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        writeInFlight = true
        let snapshotInfo = info
        DispatchQueue.global(qos: .utility).async {
            try? snapshotInfo.write(toFile: dir + "/terminal.txt", atomically: true, encoding: .utf8)
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/window.png"))
            }
            DispatchQueue.main.async { writeInFlight = false }
        }
    }
}
