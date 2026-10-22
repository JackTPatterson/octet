import AVKit
import AppKit
import PDFKit
import SwiftUI

// MARK: - Breadcrumbs

/// The open file's path above it, after T3 Code's: each folder reveals itself
/// in the Files plane.
struct FileBreadcrumbs: View {
    struct Segment: Equatable {
        let name: String
        /// The folder to reveal; nil for the file itself and for folders
        /// outside the project, which the Files plane doesn't show.
        let folder: String?
    }

    let url: URL
    let root: String
    let reveal: (String) -> Void

    /// The project folder, then each folder down to the file. A file outside
    /// the project shows its path from home instead.
    static func segments(file: URL, root: String) -> [Segment] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard file.path.hasPrefix(prefix) else {
            return (file.path as NSString).abbreviatingWithTildeInPath
                .split(separator: "/").map { Segment(name: String($0), folder: nil) }
        }
        var segments = [Segment(name: rootURL.lastPathComponent, folder: rootURL.path)]
        var path = rootURL.path
        let parts = file.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            path += "/" + part
            segments.append(Segment(name: part, folder: index == parts.count - 1 ? nil : path))
        }
        return segments
    }

    var body: some View {
        let segments = Self.segments(file: url, root: root)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        OctetIcon("chevron.right", size: 9).foregroundStyle(Theme.textTertiary)
                    }
                    BreadcrumbSegment(segment: segment, last: index == segments.count - 1, reveal: reveal)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 26)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .background(Theme.terminalBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct BreadcrumbSegment: View {
    let segment: FileBreadcrumbs.Segment
    let last: Bool
    let reveal: (String) -> Void
    @State private var hovered = false

    var body: some View {
        let label = Text(segment.name)
            .font(Theme.uiFont)
            .foregroundStyle(last ? Theme.textPrimary : hovered ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 20)
        if let folder = segment.folder {
            Button { reveal(folder) } label: {
                label
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Show in Files")
        } else {
            label
        }
    }
}

// MARK: - Images

/// Zoom for the image viewer: ⌘+, ⌘− and ⌘0 (fit) while it has focus, ⌘-scroll,
/// and pinch.
@MainActor
final class ImageZoom: ObservableObject {
    static let steps: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8, 16]
    @Published private(set) var percent = 100
    fileprivate weak var scroll: ZoomScrollView?
    private var observation: NSKeyValueObservation?

    fileprivate func attach(_ scroll: ZoomScrollView) {
        self.scroll = scroll
        observation = scroll.observe(\.magnification, options: [.new]) { [weak self] view, _ in
            let value = Int((view.magnification * 100).rounded())
            DispatchQueue.main.async { self?.percent = value }
        }
    }

    func zoomIn() {
        guard let scroll else { return }
        scroll.setZoom(Self.steps.first { $0 > scroll.magnification + 0.001 } ?? Self.steps.last!)
    }

    func zoomOut() {
        guard let scroll else { return }
        scroll.setZoom(Self.steps.last { $0 < scroll.magnification - 0.001 } ?? Self.steps.first!)
    }

    func fit() { scroll?.fit() }
}

/// An image that fits the view until zoomed, then pans by scrolling.
fileprivate final class ZoomScrollView: NSScrollView {
    private var fitted = true
    weak var zoomControls: ImageZoom?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        if fitted { applyFit() }
    }

    func fit() {
        fitted = true
        applyFit()
    }

    func setZoom(_ value: CGFloat) {
        fitted = false
        magnification = min(maxMagnification, max(minMagnification, value))
    }

    /// Shrinks to fit; never enlarges a small image past its own size.
    private func applyFit() {
        guard let document = documentView, document.frame.width > 0, document.frame.height > 0 else { return }
        let available = contentSize
        let scale = min(available.width / document.frame.width, available.height / document.frame.height, 1)
        if abs(magnification - scale) > 0.0005 { magnification = max(minMagnification, scale) }
    }

    override func magnify(with event: NSEvent) {
        fitted = false
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        setZoom(magnification * (1 + event.scrollingDeltaY * 0.01))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers ?? ""
        switch (flags.contains(.command), key) {
        case (true, "="), (true, "+"): MainActor.assumeIsolated { zoomControls?.zoomIn() }
        case (true, "-"), (true, "_"): MainActor.assumeIsolated { zoomControls?.zoomOut() }
        case (true, "0"): fit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Keeps a document smaller than the view in the middle of it.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        if let document = documentView {
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        }
        return rect
    }
}

private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let zoom: ImageZoom

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.imageScaling = .scaleNone
        scroll.documentView = view
        scroll.zoomControls = zoom
        zoom.attach(scroll)
        DispatchQueue.main.async { scroll.window?.makeFirstResponder(scroll) }
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {}
}

/// Pixel size of the image on disk, which `NSImage.size` (points) can miss.
private func pixelSize(of image: NSImage) -> CGSize {
    let rep = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
    if let rep, rep.pixelsWide > 0, rep.pixelsHigh > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
    return image.size
}

func previewFileSize(_ url: URL) -> String {
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    return ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file)
}

struct ImagePreview: View {
    let url: URL
    /// An SVG's current text, so edits show before they're saved.
    var svgText: String?
    @Binding var detail: String
    @StateObject private var zoom = ImageZoom()
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image, zoom: zoom)
                    .overlay(alignment: .bottomTrailing) { controls }
            } else if failed {
                NoPreviewCard(url: url, reason: "This image can't be read.")
            } else {
                LoadingLine().padding(8).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .task(id: svgText ?? url.path) {
            let url = url
            let data = svgText.map { Data($0.utf8) }
            let loaded = await Task.detached { data.map { NSImage(data: $0) } ?? NSImage(contentsOf: url) }.value
            guard let loaded, loaded.size.width > 0 else { failed = true; return }
            image = loaded
            let size = pixelSize(of: loaded)
            detail = "\(Int(size.width)) × \(Int(size.height)) · \(previewFileSize(url))"
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            OctetIconButton(icon: "minus", help: "Zoom Out (⌘−)") { zoom.zoomOut() }
            Text("\(zoom.percent)%")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .frame(minWidth: 38)
            OctetIconButton(icon: "plus", help: "Zoom In (⌘+)") { zoom.zoomIn() }
            OctetIconButton(icon: "arrow.up.left.and.arrow.down.right", help: "Fit to View (⌘0)") { zoom.fit() }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card))
        .padding(10)
    }
}

// MARK: - Tables

struct DelimitedTablePreview: View {
    let text: String
    let delimiter: Character
    @Binding var detail: String
    @State private var parsed: DelimitedTable.Parsed?
    @State private var column: Int?
    @State private var ascending = true
    @State private var order: [Int] = []

    private static let indexWidth: CGFloat = 46

    var body: some View {
        Group {
            if let parsed, let header = parsed.rows.first {
                let widths = Self.widths(parsed.rows, columns: header.count)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(order, id: \.self) { index in
                                row(parsed.rows[index + 1], number: index + 1, widths: widths)
                            }
                            if parsed.truncated {
                                Text("Showing the first \(DelimitedTable.maximumRows.formatted()) rows.")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(10)
                            }
                        } header: {
                            headerRow(header, widths: widths)
                        }
                    }
                }
                .octetScrollIndicators()
            } else if parsed != nil {
                OctetEmptyState(icon: "doc", title: "Empty table", message: "This file has no rows.", compact: true)
            } else {
                LoadingLine().padding(8).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .task(id: text) {
            let delimiter = delimiter
            let text = text
            let result = await Task.detached(priority: .userInitiated) { DelimitedTable.parse(text, delimiter: delimiter) }.value
            parsed = result
            column = nil
            resort()
            let count = max(0, result.rows.count - 1)
            detail = "\(count.formatted())\(result.truncated ? "+" : "") rows × \(result.rows.first?.count ?? 0) columns"
        }
    }

    private func resort() {
        guard let rows = parsed?.rows, !rows.isEmpty else { order = []; return }
        let body = Array(rows.dropFirst())
        order = DelimitedTable.order(body, column: column, ascending: ascending)
    }

    /// A click sorts by the column, again flips it, a third restores file order.
    private func sort(by index: Int) {
        if column != index { column = index; ascending = true }
        else if ascending { ascending = false }
        else { column = nil; ascending = true }
        resort()
    }

    private func headerRow(_ header: [String], widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("#").frame(width: Self.indexWidth, alignment: .trailing).padding(.trailing, 8)
            ForEach(widths.indices, id: \.self) { index in
                Button { sort(by: index) } label: {
                    HStack(spacing: 4) {
                        Text(header.indices.contains(index) ? header[index] : "").lineLimit(1)
                        if column == index { OctetIcon(ascending ? "arrow.up" : "arrow.down", size: 10) }
                        Spacer(minLength: 0)
                    }
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by this column")
            }
        }
        .font(Theme.uiFontMedium)
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 28)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func row(_ cells: [String], number: Int, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .frame(width: Self.indexWidth, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(widths.indices, id: \.self) { index in
                Text(cells.indices.contains(index) ? cells[index] : "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .font(Theme.uiFont)
        .foregroundStyle(Theme.textPrimary)
        .frame(height: 24)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider.opacity(0.5)).frame(height: 1) }
    }

    /// Column widths from the longest of the first rows, within bounds.
    private static func widths(_ rows: [[String]], columns: Int) -> [CGFloat] {
        let count = max(columns, rows.prefix(200).map(\.count).max() ?? 0)
        return (0..<count).map { column in
            let longest = rows.prefix(200).map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
            return min(320, max(64, CGFloat(longest) * 7 + 8))
        }
    }
}

// MARK: - Audio, video, PDF

/// Native AVKit controls. Playback stops when the file is closed.
struct MediaPreview: NSViewRepresentable {
    let url: URL
    let video: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = video ? .floating : .inline
        view.showsFullScreenToggleButton = video
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct AudioPreview: View {
    let url: URL

    var body: some View {
        VStack(spacing: 14) {
            OctetIcon("doc", size: 28).foregroundStyle(Theme.textTertiary)
            Text(url.lastPathComponent).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
            MediaPreview(url: url, video: false)
                .frame(width: 420, height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }
}

struct PDFPreview: View {
    let url: URL
    @Binding var detail: String
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
            } else if failed {
                NoPreviewCard(url: url, reason: "This PDF can't be read.")
            } else {
                LoadingLine().padding(8).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .task(id: url) {
            let loaded = await Task.detached { PDFDocument(url: url) }.value
            guard let loaded else { failed = true; return }
            document = loaded
            detail = "\(loaded.pageCount) \(loaded.pageCount == 1 ? "page" : "pages") · \(previewFileSize(url))"
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(Theme.terminalBackground)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

// MARK: - No preview

/// What a file Octet can't show looks like: quiet, with a way out.
struct NoPreviewCard: View {
    let url: URL
    var reason: String?

    var body: some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        VStack(spacing: 14) {
            OctetEmptyState(icon: "doc", title: "No preview",
                            message: reason ?? "\(url.lastPathComponent) · \(previewFileSize(url))", compact: true)
                .frame(maxHeight: 120)
            HStack(spacing: 8) {
                OctetButton(title: "Reveal in Finder", icon: "folder", compact: true) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                OctetMenuButton({
                    var items: [OctetMenuItem] = [.action("Default App") { NSWorkspace.shared.open(url) }]
                    if !apps.isEmpty { items.append(.divider) }
                    for app in apps {
                        items.append(.action(FileManager.default.displayName(atPath: app.path)) {
                            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        })
                    }
                    return items
                }) {
                    Text("Open With").font(Theme.uiFontMedium)
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }
}
