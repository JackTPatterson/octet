import Foundation

/// What a file or folder looked like when it was last looked at.
struct FileStamp: Codable, Equatable {
    /// Modification time, in seconds since 1970.
    var modified: TimeInterval
    var size: Int64

    /// Not there. Something appearing where nothing was is a change too.
    static let missing = FileStamp(modified: 0, size: -1)

    /// The stamp at `path`, following symlinks: npm and Homebrew link their
    /// CLIs into a bin folder, and an update rewrites what the link points at.
    static func of(_ path: String) -> FileStamp {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return FileStamp(modified: modified, size: Int64(info.st_size))
    }
}

/// A cheap picture of what the last agent scan saw, so a later look can tell
/// whether anything changed without running a login shell or any CLI.
///
/// A folder's modification time moves when a file is added, removed or
/// renamed in it, which covers an install or uninstall into any bin folder
/// (`npm i -g`, Homebrew, `~/.local/bin`, `~/.bun/bin`). An update that
/// replaces a binary in place shows in the binary's own time or size.
struct AgentDiscoveryFingerprint: Codable, Equatable {
    /// The login shell's PATH that scan used.
    var shellPath: String
    /// Every folder searched, and each shell profile that could change PATH.
    var directories: [String: FileStamp]
    /// Each executable the scan found.
    var executables: [String: FileStamp]

    /// Profiles a login shell reads. Editing one may change PATH itself.
    static let shellProfiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]

    /// Stamps everything a scan with this PATH would look at.
    static func record(shellPath: String, directories: [String], executables: [String],
                       home: String = NSHomeDirectory(),
                       stamp: (String) -> FileStamp = FileStamp.of) -> AgentDiscoveryFingerprint {
        let watched = directories + shellProfiles.map { home + "/" + $0 }
        return AgentDiscoveryFingerprint(
            shellPath: shellPath,
            directories: Dictionary(watched.map { ($0, stamp($0)) }, uniquingKeysWith: { first, _ in first }),
            executables: Dictionary(executables.map { ($0, stamp($0)) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Whether a full scan is worth running. With nothing recorded there is
    /// nothing to compare against, so yes.
    static func needsRescan(recorded: AgentDiscoveryFingerprint?, stamp: (String) -> FileStamp) -> Bool {
        guard let recorded else { return true }
        // Executables first: an update is the likeliest change and the cheapest to catch.
        for (path, was) in recorded.executables where stamp(path) != was { return true }
        for (path, was) in recorded.directories where stamp(path) != was { return true }
        return false
    }
}
