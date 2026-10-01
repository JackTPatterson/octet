import AppKit

/// Each workspace folder's project icon, from enabled plugins' workspace
/// icon commands: the first that prints an image inside the folder wins.
/// Read again every so often, sooner when nothing was found, so a plugin
/// just installed or an icon just added shows up.
@MainActor
final class WorkspaceIconStore: ObservableObject {
    static let shared = WorkspaceIconStore()

    @Published private(set) var images: [String: NSImage] = [:]
    private var nextRead: [String: Date] = [:]
    private var reading: Set<String> = []

    /// The icon for `directory`, if one was found; asks for it in the
    /// background when it's due, never while a view is drawing.
    func image(for directory: String?) -> NSImage? {
        guard let directory else { return nil }
        if Date() >= nextRead[directory] ?? .distantPast, !reading.contains(directory) {
            reading.insert(directory)
            DispatchQueue.main.async { self.read(directory) }
        }
        return images[directory]
    }

    private func read(_ directory: String) {
        let host = OctetPluginHost.shared
        let entries = host.plugins.filter(host.isEnabled).flatMap { plugin in
            plugin.manifest.contributes.workspaceIcons.filter { !$0.run.isEmpty }.map { ($0, plugin) }
        }
        attempt(entries[...], in: directory)
    }

    /// Asks each contribution in turn until one finds an image.
    private func attempt(_ entries: ArraySlice<(OctetPluginManifest.WorkspaceIconContribution, OctetPlugin)>, in directory: String) {
        guard let (icon, plugin) = entries.first else {
            // None found: look again soon, and show nothing meanwhile.
            finish(directory, image: nil, every: 60)
            return
        }
        let timeout = min(max(icon.timeoutSeconds ?? 5, 1), 20)
        StatusCommand.run(icon.run, in: directory, environment: OctetPluginHost.environment(plugin, directory: directory),
                          timeout: timeout) { [weak self] output in
            guard let self else { return }
            if let image = Self.image(fromOutput: output, in: directory) {
                self.finish(directory, image: image, every: max(icon.refreshSeconds ?? 600, 30))
            } else {
                self.attempt(entries.dropFirst(), in: directory)
            }
        }
    }

    private func finish(_ directory: String, image: NSImage?, every seconds: TimeInterval) {
        reading.remove(directory)
        nextRead[directory] = Date().addingTimeInterval(seconds)
        if images[directory] !== image { images[directory] = image }
    }

    /// The image a command printed the path of: inside the folder, and one
    /// macOS can draw.
    static func image(fromOutput output: String, in directory: String) -> NSImage? {
        guard let path = WorkspaceIconPath.resolve(output, in: directory),
              let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}
