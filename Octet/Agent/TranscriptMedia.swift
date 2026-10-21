import AppKit
import AVKit
import SwiftUI

/// The images and videos a reply links to or names, previewed under it,
/// after T3 Code's inline media: images at a readable size that enlarge on
/// a click, videos in a player, each with Open, Copy and Reveal.
struct TranscriptMediaStrip: View {
    let links: [TranscriptMediaLink]

    /// Only what can be shown: a named file has to exist.
    init(text: String, cwd: String?) {
        links = TranscriptMediaLink.links(in: text, cwd: cwd).filter { link in
            !link.isFile || FileManager.default.fileExists(atPath: link.url.path)
        }
    }

    var body: some View {
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(links) { link in
                        TranscriptMediaCard(link: link)
                    }
                }
            }
        }
    }
}

private struct TranscriptMediaCard: View {
    let link: TranscriptMediaLink
    @State private var data: Data?
    @State private var failed = false

    private var name: String {
        let last = link.url.lastPathComponent
        return last.isEmpty ? link.source : last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch link.kind {
            case .image:
                if let data {
                    ImageGallery(images: [data])
                } else {
                    placeholder(failed ? "Couldn't load the image" : nil)
                }
            case .video:
                MediaVideoPlayer(url: link.url)
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
            }
            HStack(spacing: 2) {
                OctetIcon(link.kind == .video ? "play.circle" : "photo", size: 12)
                    .foregroundStyle(Theme.textTertiary)
                Text(name)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(link.isFile ? link.url.path : link.url.absoluteString)
                Spacer(minLength: 4)
                OctetIconButton(icon: "arrow.up.right", help: "Open \(name)", compact: true) {
                    NSWorkspace.shared.open(link.url)
                }
                OctetIconButton(icon: "doc.on.doc", help: link.kind == .image && data != nil ? "Copy image" : "Copy \(link.isFile ? "path" : "link")",
                                compact: true) { copy() }
                if link.isFile {
                    OctetIconButton(icon: "folder", help: "Reveal in Finder", compact: true) {
                        NSWorkspace.shared.activateFileViewerSelecting([link.url])
                    }
                }
            }
        }
        .task(id: link.id) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(link.kind == .video ? "Video" : "Image") \(name)")
    }

    private func placeholder(_ message: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.card)
            if let message {
                Text(message).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            } else {
                LoadingLine(width: 18)
            }
        }
        .frame(width: 240, height: 140)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func load() async {
        guard link.kind == .image, data == nil else { return }
        let url = link.url
        let loaded: Data?
        if url.isFileURL {
            loaded = await Task.detached(priority: .utility) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
        } else {
            loaded = try? await URLSession.shared.data(from: url).0
        }
        // At most 40 MB, and only what is an image.
        if let loaded, loaded.count < 40_000_000, NSImage(data: loaded) != nil {
            data = loaded
        } else {
            failed = true
        }
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        if link.kind == .image, let data, let image = NSImage(data: data) {
            board.writeObjects([image])
            ToastCenter.shared.info("Copied the image")
        } else {
            board.setString(link.isFile ? link.url.path : link.url.absoluteString, forType: .string)
            ToastCenter.shared.info(link.isFile ? "Copied the path" : "Copied the link")
        }
    }
}

/// AVKit's player for a video in a reply. It waits to be played, and
/// stops when it scrolls away.
struct MediaVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        view.setAccessibilityLabel("Video \(url.lastPathComponent)")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
