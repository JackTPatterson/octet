import Foundation

/// A file's working-tree contents kept from just before its changes were
/// discarded, so the toast's Undo can put them back. Undo is refused once
/// the file changed again after the discard: writing the old bytes then
/// would throw away whatever came since.
struct DiscardedFile: Equatable {
    /// Relative to the checkout's top level.
    let path: String
    /// What was there before; nil when there was no file.
    let before: Data?
    /// What the discard left; nil when it removed the file.
    var after: Data?
    /// Where an untracked file or folder went in the Trash, which is what
    /// Undo moves back: a folder (a clone, a worktree) has no contents to keep.
    var trashed: URL?

    static func read(_ path: String, in top: String) -> Data? {
        FileManager.default.contents(atPath: (top as NSString).appendingPathComponent(path))
    }

    /// Keeps the file as it is now, before it's discarded.
    static func capture(_ path: String, in top: String) -> DiscardedFile {
        DiscardedFile(path: path, before: read(path, in: top), after: nil)
    }

    /// Notes what the discard left, the state Undo checks against.
    mutating func discarded(in top: String) {
        after = Self.read(path, in: top)
    }

    /// Still as the discard left it.
    func canUndo(in top: String) -> Bool {
        if trashed != nil {
            return !FileManager.default.fileExists(atPath: (top as NSString).appendingPathComponent(path))
        }
        return Self.read(path, in: top) == after
    }

    struct Changed: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) changed after it was discarded, so undoing would lose that." }
    }

    /// Puts the kept contents back; throws `Changed` when the file moved on.
    func undo(in top: String) throws {
        guard canUndo(in: top) else { throw Changed(path: path) }
        let url = URL(fileURLWithPath: (top as NSString).appendingPathComponent(path))
        if let trashed {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: url)
            return
        }
        var isDirectory: ObjCBool = false
        if let before {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try before.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            // Never a folder: nil here only means there were no bytes to keep
            // (a submodule's, say), not that nothing was there.
            try FileManager.default.removeItem(at: url)
        }
    }
}
