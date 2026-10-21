import Foundation

/// Tells when a todo file is written, renamed or deleted, so an agent
/// ticking an item shows straight away rather than on the next look. Editors
/// and atomic writes replace the file, which ends this watch; the model
/// starts a new one on its next read, and looks on its tick meanwhile.
final class TodoFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private(set) var isWatching = false

    init(path: String, changed: @escaping @MainActor () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.isWatching = false
                source.cancel()
            }
            MainActor.assumeIsolated { changed() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        isWatching = true
        source.resume()
    }

    deinit { source?.cancel() }
}
