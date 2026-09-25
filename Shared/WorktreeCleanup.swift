import Foundation

/// Worktrees pile up: every agent task leaves one, each with its own
/// dependencies. This finds a repository's worktrees, which are merged and
/// clean (safe to remove), and how much disk each holds.
enum WorktreeCleanup {
    struct Worktree: Equatable, Identifiable {
        let path: String
        let branch: String?
        let isMain: Bool
        var merged = false
        var dirty = false
        var bytes: Int64?

        var id: String { path }
        /// Merged into the default branch with nothing uncommitted.
        var removable: Bool { !isMain && merged && !dirty }
    }

    /// `git worktree list --porcelain`.
    static func parse(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, bare = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line == "bare" { bare = true }
            }
            guard let path, !bare else { continue }
            result.append(Worktree(path: path, branch: branch, isMain: result.isEmpty))
        }
        return result
    }

    /// Every worktree of the repository `directory` is in, marked. Sizes are
    /// left to `measure`, which is slower.
    static func list(in directory: String, git: Git = Git()) -> [Worktree] {
        guard let top = git.topLevel(directory),
              let text = try? git.run(["worktree", "list", "--porcelain"], in: top) else { return [] }
        var worktrees = parse(text)
        let base = ReviewDiff.defaultBranch(top: top, git: git)
        let merged = Set(base.flatMap { try? git.run(["branch", "--format=%(refname:short)", "--merged", $0], in: top) }?
            .split(separator: "\n").map(String.init) ?? [])
        for index in worktrees.indices where !worktrees[index].isMain {
            let worktree = worktrees[index]
            guard FileManager.default.fileExists(atPath: worktree.path) else { continue }
            if let branch = worktree.branch { worktrees[index].merged = merged.contains(branch) && branch != base }
            let status = (try? git.run(["status", "--porcelain", "--untracked-files=normal"], in: worktree.path)) ?? "?"
            worktrees[index].dirty = !status.isEmpty
        }
        return worktrees
    }

    /// Bytes on disk under `path`, dependencies included.
    static func measure(_ path: String) -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard let kilobytes = String(decoding: data, as: UTF8.self).split(separator: "\t").first.flatMap({ Int64($0) })
        else { return nil }
        return kilobytes * 1024
    }

    /// Removes a worktree's checkout and its bookkeeping; the branch stays.
    static func remove(_ worktree: Worktree, in directory: String, git: Git = Git()) throws {
        guard !worktree.isMain else { throw Checkpoints.GitError(description: "The main checkout isn't a worktree to remove") }
        guard let top = git.topLevel(directory) else { throw Checkpoints.GitError(description: "Not a git repository") }
        try git.run(["worktree", "remove", worktree.path], in: top)
    }
}
