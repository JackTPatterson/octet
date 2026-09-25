import Foundation

/// A snapshot of a working tree, taken as an agent starts a turn, so the
/// turn can be undone even where the agent's own rewind can't reach (edits
/// made through a shell, files it created). Nothing the person works with
/// is touched: the snapshot is built in a throwaway index and kept as a
/// commit under `refs/octet/checkpoints/`, which isn't a branch, isn't
/// pushed, and leaves HEAD, the index and the stash alone.
struct Checkpoint: Equatable, Identifiable {
    let ref: String
    let commit: String
    let date: Date
    let label: String

    var id: String { ref }
}

enum Checkpoints {
    static let refPrefix = "refs/octet/checkpoints/"
    /// Checkpoints kept per working tree; older ones are dropped.
    static let keep = 50

    struct GitError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Taking one

    /// Snapshots the working tree `directory` is in. Returns nil outside a
    /// repository, or when nothing changed since the last checkpoint (unless
    /// `force`).
    @discardableResult
    static func create(in directory: String, label: String, force: Bool = false,
                       git: Git = Git()) -> Checkpoint? {
        guard let top = git.topLevel(directory) else { return nil }
        guard let tree = try? snapshotTree(top: top, git: git) else { return nil }
        let prefix = self.prefix(for: top)
        if !force, let last = list(top: top, git: git).first,
           (try? git.run(["rev-parse", last.commit + "^{tree}"], in: top)) == tree {
            return nil
        }
        var args = ["commit-tree", tree, "-m", label]
        if let head = try? git.run(["rev-parse", "-q", "--verify", "HEAD"], in: top), !head.isEmpty {
            args += ["-p", head]
        }
        guard let commit = try? git.run(args, in: top, environment: Git.identity) else { return nil }
        // Milliseconds, so two in one second don't collide.
        let ref = prefix + String(Int((Date().timeIntervalSince1970 * 1000).rounded()))
        guard (try? git.run(["update-ref", ref, commit], in: top)) != nil else { return nil }
        prune(top: top, git: git)
        return list(top: top, git: git).first { $0.ref == ref }
    }

    /// The tree of everything in the working tree that git would track:
    /// tracked files as they are now, and untracked ones not ignored.
    static func snapshotTree(top: String, git: Git) throws -> String {
        let index = try temporaryIndex(top: top, git: git)
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE": index]
        _ = try git.run(["add", "-A", "--", "."], in: top, environment: environment)
        return try git.run(["write-tree"], in: top, environment: environment)
    }

    /// A copy of the real index, so `add -A` only has to look at what changed.
    private static func temporaryIndex(top: String, git: Git) throws -> String {
        let path = NSTemporaryDirectory() + "octet-checkpoint-\(UUID().uuidString).index"
        let real = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: top)
        if FileManager.default.fileExists(atPath: real) {
            try FileManager.default.copyItem(atPath: real, toPath: path)
        }
        return path
    }

    // MARK: - Listing

    /// Newest first.
    static func list(in directory: String, git: Git = Git()) -> [Checkpoint] {
        guard let top = git.topLevel(directory) else { return [] }
        return list(top: top, git: git)
    }

    private static func list(top: String, git: Git) -> [Checkpoint] {
        let format = "%(refname)%00%(objectname)%00%(committerdate:unix)%00%(contents:subject)"
        guard let output = try? git.run(["for-each-ref", "--sort=-refname", "--format=" + format, prefix(for: top)], in: top)
        else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let seconds = TimeInterval(parts[2]) else { return nil }
            return Checkpoint(ref: parts[0], commit: parts[1], date: Date(timeIntervalSince1970: seconds), label: parts[3])
        }
    }

    /// The files that differ between a checkpoint and the working tree now.
    static func changes(since checkpoint: Checkpoint, in directory: String, git: Git = Git()) -> [String] {
        changes(since: [checkpoint], in: directory, git: git)[checkpoint.ref] ?? []
    }

    /// The same for several, snapshotting the working tree once.
    static func changes(since checkpoints: [Checkpoint], in directory: String, git: Git = Git()) -> [String: [String]] {
        guard let top = git.topLevel(directory), let now = try? snapshotTree(top: top, git: git) else { return [:] }
        var result: [String: [String]] = [:]
        for checkpoint in checkpoints {
            guard let output = try? git.run(["diff", "--name-only", "--no-renames", checkpoint.commit, now], in: top) else { continue }
            result[checkpoint.ref] = output.split(separator: "\n").map(String.init)
        }
        return result
    }

    // MARK: - Restoring

    /// Puts the working tree back as it was at `checkpoint`: changed and
    /// deleted files come back, files made since are removed. The state it
    /// replaces is checkpointed first and returned, so a restore can itself
    /// be undone. The index and HEAD are left as they are.
    @discardableResult
    static func restore(_ checkpoint: Checkpoint, in directory: String, git: Git = Git()) throws -> Checkpoint {
        guard let top = git.topLevel(directory) else { throw GitError(description: "\(directory) isn't in a git repository") }
        let time = checkpoint.date.formatted(date: .omitted, time: .shortened)
        guard let before = create(in: top, label: "Before restoring \(time)", force: true, git: git) else {
            throw GitError(description: "Couldn't save the current state first, so nothing was restored")
        }
        // Files that exist now but didn't then.
        let added = try git.run(["diff", "--name-only", "--no-renames", "--diff-filter=A", checkpoint.commit, before.commit], in: top)
        for path in added.split(separator: "\n") {
            try? FileManager.default.removeItem(atPath: (top as NSString).appendingPathComponent(String(path)))
        }
        // Everything the checkpoint holds, written through a throwaway index.
        let index = NSTemporaryDirectory() + "octet-restore-\(UUID().uuidString).index"
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE": index]
        _ = try git.run(["read-tree", checkpoint.commit], in: top, environment: environment)
        _ = try git.run(["checkout-index", "-a", "-f"], in: top, environment: environment)
        return before
    }

    // MARK: - Housekeeping

    private static func prune(top: String, git: Git) {
        for old in list(top: top, git: git).dropFirst(keep) {
            _ = try? git.run(["update-ref", "-d", old.ref], in: top)
        }
    }

    /// Each working tree's checkpoints under their own prefix: worktrees
    /// share refs with their repository.
    static func prefix(for top: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in top.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return refPrefix + String(hash, radix: 16) + "/"
    }
}

/// Runs git without a shell, and without the person's config deciding the
/// outcome (hooks aren't run by plumbing).
struct Git {
    var executable = "/usr/bin/git"

    /// Who a checkpoint's commit says made it; git refuses without one.
    static let identity = [
        "GIT_AUTHOR_NAME": "Octet", "GIT_AUTHOR_EMAIL": "octet@localhost",
        "GIT_COMMITTER_NAME": "Octet", "GIT_COMMITTER_EMAIL": "octet@localhost",
    ]

    func topLevel(_ directory: String) -> String? {
        guard FileManager.default.fileExists(atPath: directory),
              let top = try? run(["rev-parse", "--show-toplevel"], in: directory), !top.isEmpty else { return nil }
        return top
    }

    /// Standard output, trimmed; throws with standard error on failure.
    @discardableResult
    func run(_ arguments: [String], in directory: String, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", directory] + arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // `waitUntilExit` spins a run loop and adds ~50 ms a call; a
        // checkpoint makes about ten.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Read before waiting, so a large output can't fill the pipe and stall.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard process.terminationStatus == 0 else {
            throw Checkpoints.GitError(description: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
