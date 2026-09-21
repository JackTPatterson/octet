import AppKit

/// ⌘V in a pane. Octet sees the key before the terminal does, so an image on
/// the clipboard can be written to a file and pasted as a path — the thing
/// agents accept and terminals mangle. Text pastes are left to the terminal.
@MainActor
enum PasteHandler {
    /// Image types worth writing out, in the order they're preferred.
    private static let types: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (.tiff, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (.pdf, "pdf"),
    ]

    /// Handles the key when the clipboard holds an image. Returns false for
    /// everything else, so ordinary paste behaves as it always did.
    static func handleCommandV(store: SessionStore) -> Bool {
        guard SettingsStore.shared.values.pasteImagesAsFiles else { return false }
        let pasteboard = NSPasteboard.general
        // A file the user copied in Finder already has a path: paste that.
        if let files = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let file = files.first, file.isFileURL, isImage(file) {
            return send(path: file.path, store: store, copied: false)
        }
        guard let (data, ext) = imageData(from: pasteboard) else { return false }
        do {
            let path = try ImagePaste.save(data, extension: ext)
            ImagePaste.prune()
            return send(path: path, store: store, copied: true)
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't save the pasted image", detail: String(describing: error))
            return true
        }
    }

    private static func imageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        for (type, ext) in types {
            guard let data = pasteboard.data(forType: type) else { continue }
            if type == .tiff {
                // TIFF is what a screenshot lands as; PNG is what tools read.
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { continue }
                return (png, ext)
            }
            return (data, ext)
        }
        return nil
    }

    private static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "pdf", "heic"].contains(url.pathExtension.lowercased())
    }

    /// Types the path into the focused pane.
    private static func send(path: String, store: SessionStore, copied: Bool) -> Bool {
        guard let paneId = store.keyPaneId else { return false }
        let client = store.client
        let text = ImagePaste.insertion(for: path) + " "
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? client.call("pane.send_text", ["pane_id": paneId, "text": text])
        }
        ToastCenter.shared.info(
            copied ? "Pasted the image as a file" : "Pasted the image's path",
            detail: (path as NSString).lastPathComponent
        )
        return true
    }
}
