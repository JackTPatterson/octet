import Foundation

/// Reads the checked-out branch for a directory from `.git/HEAD` without
/// spawning git. Worktree `.git` files are followed to their gitdir.
enum GitBranch {
    static func current(in directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir: URL
                if isDirectory.boolValue {
                    gitDir = dotGit
                } else if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = raw.hasPrefix("/")
                        ? URL(fileURLWithPath: raw)
                        : url.appendingPathComponent(raw)
                } else {
                    return nil
                }
                return branch(fromHead: try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Where a directory's repository keeps its git data, the working tree
    /// it belongs to, and whether that tree is a linked worktree.
    static func location(for directory: String) -> (gitDir: String, root: String, isLinkedWorktree: Bool)? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (dotGit.path, url.path, false) }
                guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = raw.hasPrefix("/") ? raw : url.appendingPathComponent(raw).standardizedFileURL.path
                // Submodules keep their data under the parent's modules/;
                // only worktrees are "linked".
                return (gitDir, url.path, gitDir.contains("/worktrees/"))
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Whether HEAD names a commit rather than a branch.
    static func isDetached(gitDir: String) -> Bool {
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return false }
        return !head.hasPrefix("ref:")
    }

    /// The working tree a directory belongs to, or nil outside a repo.
    static func repositoryRoot(for directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func branch(fromHead head: String?) -> String? {
        guard let head = head?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        let prefix = "ref: refs/heads/"
        if head.hasPrefix(prefix) { return String(head.dropFirst(prefix.count)) }
        return String(head.prefix(7))
    }
}
