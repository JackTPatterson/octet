import Foundation

/// Every file in a project, once, for the Files plane, the editor's file
/// list and its ⌘O picker. In a git checkout it's what git would show
/// (tracked files and untracked ones not ignored), so .gitignore is
/// honoured the way the person already set it up; elsewhere it walks the
/// folder, skipping the usual build and dependency folders.
enum ProjectFileIndex {
    struct Result: Equatable {
        /// Paths relative to the root, sorted as Finder would.
        var paths: [String]
        /// More files exist than `paths` holds.
        var truncated: Bool
        /// Read through git (so .gitignore applied) rather than a folder walk.
        var fromGit: Bool

        static let empty = Result(paths: [], truncated: false, fromGit: false)
    }

    static let defaultLimit = 20_000
    static let ignoredDirectories: Set<String> = [".git", "build", "DerivedData", "node_modules", ".build", "Pods"]

    static func list(root: String, limit: Int = defaultLimit, git: Git = Git()) -> Result {
        let rootPath = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        if let output = try? git.run(["-c", "core.quotepath=off", "ls-files", "--cached", "--others",
                                      "--exclude-standard", "-z"], in: rootPath) {
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            // Tracked files deleted since, and submodules, aren't files to open.
            let existing = parseGitList(output).filter { path in
                manager.fileExists(atPath: rootPath + "/" + path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
            return finish(existing, limit: limit, fromGit: true)
        }
        return finish(walk(rootPath, limit: limit + 1), limit: limit, fromGit: false)
    }

    /// `git ls-files -z`: NUL-separated paths, once each.
    static func parseGitList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\0").map(String.init).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func finish(_ paths: [String], limit: Int, fromGit: Bool) -> Result {
        let sorted = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Result(paths: Array(sorted.prefix(limit)), truncated: sorted.count > limit, fromGit: fromGit)
    }

    /// A folder walk for projects outside git: hidden files and the usual
    /// generated folders left out, symlinks not followed.
    private static func walk(_ rootPath: String, limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, ignoredDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            // Normalise aliases such as /var -> /private/var before cutting the prefix.
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            result.append(String(path.dropFirst(prefix.count)))
            if result.count >= limit { break }
        }
        return result
    }
}

/// What git says about each file under a folder, for the Files plane's
/// marks: a letter per changed file, and a dot on every folder holding one.
struct ProjectGitStatus: Equatable {
    enum Mark: String, Equatable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U", conflicted = "!"
    }

    /// By path relative to the folder the plane shows.
    var files: [String: Mark] = [:]
    /// Folders (relative, no trailing slash) with a change somewhere inside.
    var folders: Set<String> = []

    static let empty = ProjectGitStatus()

    /// `changes` are relative to the repository's top; `prefix` is where the
    /// shown folder sits inside it ("" at the top, "app/web" below it).
    init(changes: [AgentGit.FileChange] = [], prefix: String = "") {
        let lead = prefix.isEmpty ? "" : (prefix.hasSuffix("/") ? prefix : prefix + "/")
        for change in changes {
            guard change.path.hasPrefix(lead) else { continue }
            let path = String(change.path.dropFirst(lead.count))
            guard !path.isEmpty else { continue }
            files[path] = Self.mark(change.kind)
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty, folder != "." {
                guard folders.insert(folder).inserted else { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
    }

    static func mark(_ kind: AgentGit.FileChange.Kind) -> Mark {
        switch kind {
        case .modified: .modified
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .untracked: .untracked
        case .conflicted: .conflicted
        }
    }

    /// Reads it for `root`; empty outside a git checkout. Off the main thread.
    static func read(root: String, git: Git = Git()) -> ProjectGitStatus {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        guard let top = git.topLevel(rootPath),
              let status = try? git.run(["-c", "core.quotepath=off", "status", "--porcelain=v2", "-z",
                                         "--untracked-files=all"], in: rootPath) else { return .empty }
        let topPath = URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath == topPath ? "" : String(rootPath.dropFirst(topPath.count + 1))
        return ProjectGitStatus(changes: AgentGit.parseStatus(status).1, prefix: prefix)
    }
}
