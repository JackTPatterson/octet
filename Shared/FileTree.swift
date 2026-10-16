import Foundation

/// A project's files as a tree of folders, built from relative paths, for
/// the Files plane. Folders come first, then files, each by name.
struct FileTreeNode: Identifiable, Equatable {
    /// The path relative to the root; folders without a trailing slash.
    let path: String
    let name: String
    let isFolder: Bool
    var children: [FileTreeNode]

    var id: String { path }

    static func build(_ relativePaths: [String]) -> [FileTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [String] = []
        }
        let root = Folder()
        for path in relativePaths {
            let parts = path.split(separator: "/").map(String.init)
            guard let file = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() {
                if let next = folder.folders[part] { folder = next } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append(file)
        }
        func nodes(_ folder: Folder, prefix: String) -> [FileTreeNode] {
            let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            let folders = folder.folders.keys.sorted(by: order).map { name -> FileTreeNode in
                let path = prefix + name
                return FileTreeNode(path: path, name: name, isFolder: true,
                                    children: nodes(folder.folders[name]!, prefix: path + "/"))
            }
            let files = folder.files.sorted(by: order).map {
                FileTreeNode(path: prefix + $0, name: $0, isFolder: false, children: [])
            }
            return folders + files
        }
        return nodes(root, prefix: "")
    }

    /// The rows to draw: each node with its depth, skipping folded folders'
    /// contents.
    static func rows(_ nodes: [FileTreeNode], open: Set<String>, depth: Int = 0) -> [(node: FileTreeNode, depth: Int)] {
        nodes.flatMap { node -> [(node: FileTreeNode, depth: Int)] in
            [(node, depth)] + (node.isFolder && open.contains(node.path) ? rows(node.children, open: open, depth: depth + 1) : [])
        }
    }
}
