import Foundation

/// Where a workspace icon command says the icon is: its first line, made
/// absolute against the workspace folder, and only a file inside it with an
/// image's extension. A plugin can't point the sidebar anywhere else.
///
/// Nor at another project's icon: a folder of projects (~/Developer) is not
/// a project, and an icon inside one of the repositories in it belongs to
/// that repository, not to the folder. So an icon with a `.git` between it
/// and the workspace folder is turned down, and the workspace shows its
/// plain state.
enum WorkspaceIconPath {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "ico", "icns", "svg", "webp", "gif"]

    static func resolve(_ output: String, in directory: String,
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let raw = line.hasPrefix("/") ? line : directory + "/" + line
        let path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              extensions.contains((path as NSString).pathExtension.lowercased()),
              exists(path),
              !insideNestedProject(path, root: root, exists: exists) else { return nil }
        return path
    }

    /// Whether a folder between `root` (not counted) and the file at `path`
    /// is a repository of its own.
    static func insideNestedProject(_ path: String, root: String,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        while folder.count > base.count, folder.hasPrefix(base + "/") {
            if exists(folder + "/.git") { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }
}
