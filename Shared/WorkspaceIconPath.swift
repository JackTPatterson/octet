import Foundation

/// Where a workspace icon command says the icon is: its first line, made
/// absolute against the workspace folder, and only a file inside it with an
/// image's extension. A plugin can't point the sidebar anywhere else.
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
              exists(path) else { return nil }
        return path
    }
}
