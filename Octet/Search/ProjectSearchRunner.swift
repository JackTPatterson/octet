import Foundation

/// Runs a project content search: ripgrep when it's installed (it reads
/// .gitignore and reports where each line matched), else `git grep` in a
/// repository, else a plain scan of the folder. Matches arrive in batches
/// as they're found; cancelling the task stops the process.
enum ProjectSearchRunner {
    enum Engine: String {
        case ripgrep = "ripgrep"
        case gitGrep = "git grep"
        case scan = "scan"
    }

    struct Outcome {
        var engine: Engine
        /// Stopped at `limit` with more to find.
        var truncated = false
    }

    enum Failure: Error, Equatable {
        case invalidPattern
        case failed(String)
    }

    /// The most matches one search returns.
    static let limit = 2000

    /// Folders the scan never enters (ripgrep and git skip ignored ones).
    private static let skippedFolders: Set<String> = [".git", "node_modules", "build", "DerivedData", ".build",
                                                      "dist", "Pods", ".next", ".venv", "target", ".cache"]

    /// ripgrep on this Mac, if any. An app started from the Finder has a
    /// short PATH, so the usual install places are looked in first.
    static let ripgrep: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", NSHomeDirectory() + "/.cargo/bin/rg",
                          "/run/current-system/sw/bin/rg", "/usr/bin/rg"]
            + path.split(separator: ":").map { $0 + "/rg" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func run(_ options: ProjectSearchOptions, in root: String, ripgrep: String? = Self.ripgrep,
                    emit: @escaping @Sendable ([ProjectSearchMatch]) async -> Void) async throws -> Outcome {
        guard !options.query.isEmpty else { return Outcome(engine: .scan) }
        let batcher = Batcher(emit: emit)
        if let ripgrep {
            let result = try await stream(ripgrep, options.ripgrepArguments, in: root) { line in
                guard let match = RipgrepJSON.match(fromLine: line) else { return true }
                return await batcher.add(match)
            }
            await batcher.flush()
            // 0 found something, 1 found nothing; 2 is an error, though with
            // --no-messages one unreadable file alone still gives matches.
            if result.status == 2, await batcher.count == 0 {
                if result.stderr.contains("regex parse error") || result.stderr.contains("error parsing") {
                    throw Failure.invalidPattern
                }
                if !result.stderr.isEmpty { throw Failure.failed(firstLine(result.stderr)) }
            }
            return Outcome(engine: .ripgrep, truncated: await batcher.full)
        }
        guard let matcher = ProjectSearchMatcher(options) else { throw Failure.invalidPattern }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), isInRepository(root) {
            let result = try await stream("/usr/bin/git", options.gitGrepArguments, in: root) { line in
                guard let match = GitGrepOutput.match(fromLine: line, matcher: matcher) else { return true }
                return await batcher.add(match)
            }
            await batcher.flush()
            // 128: not a repository after all (or git broke); scan instead.
            let found = await batcher.count
            if result.status != 128 || found > 0 {
                return Outcome(engine: .gitGrep, truncated: await batcher.full)
            }
        }
        try await scan(root, options: options, matcher: matcher, into: batcher)
        await batcher.flush()
        return Outcome(engine: .scan, truncated: await batcher.full)
    }

    /// Whether `folder` or a folder above it has a `.git` (a repository, or a
    /// worktree's file pointing at one).
    static func isInRepository(_ folder: String) -> Bool {
        var current = URL(fileURLWithPath: folder).standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// The folder to search for a workspace in `directory`: the repository
    /// (or worktree) it's in, unless that's the home folder's dotfiles repo,
    /// else the directory itself.
    static func searchRoot(for directory: String) -> String {
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        while current.path != "/" && current.path != home {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current.path }
            current.deleteLastPathComponent()
        }
        return directory
    }

    // MARK: Matches in batches

    /// Collects matches and hands them on every few dozen or every 60ms,
    /// so the list fills as results come in without redrawing per line.
    private actor Batcher {
        let emit: @Sendable ([ProjectSearchMatch]) async -> Void
        private var pending: [ProjectSearchMatch] = []
        private var lastFlush = Date()
        private(set) var count = 0
        private(set) var full = false

        init(emit: @escaping @Sendable ([ProjectSearchMatch]) async -> Void) { self.emit = emit }

        /// False once the limit is reached: stop looking.
        func add(_ match: ProjectSearchMatch) async -> Bool {
            guard count < ProjectSearchRunner.limit else {
                full = true
                return false
            }
            count += 1
            pending.append(match)
            if pending.count >= 64 || Date().timeIntervalSince(lastFlush) > 0.06 { await flush() }
            return true
        }

        func flush() async {
            lastFlush = Date()
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            await emit(batch)
        }
    }

    // MARK: Processes

    /// Runs `executable`, handing each line of its output to `onLine` until
    /// that returns false. Splits on "\n" alone: ripgrep's JSON can carry
    /// a raw U+2028, which Foundation's own line splitting breaks at.
    private static func stream(_ executable: String, _ arguments: [String], in folder: String,
                               onLine: (String) async -> Bool) async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Collected as it comes, so a chatty stderr can't fill its pipe and stall the process.
        let stderr = LockedData()
        errors.fileHandleForReading.readabilityHandler = { handle in stderr.append(handle.availableData) }
        try process.run()
        let stop = { if process.isRunning { process.terminate() } }
        do {
            try await withTaskCancellationHandler {
                var line: [UInt8] = []
                line.reserveCapacity(512)
                lines: for try await byte in output.fileHandleForReading.bytes {
                    if byte == 0x0A {
                        let keepGoing = await onLine(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                        if !keepGoing || Task.isCancelled { break lines }
                    } else {
                        line.append(byte)
                    }
                }
                if !line.isEmpty, !Task.isCancelled { _ = await onLine(String(decoding: line, as: UTF8.self)) }
            } onCancel: {
                stop()
            }
        } catch {
            stop()
            throw error
        }
        stop()
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        stderr.append(errors.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        return (process.terminationStatus, String(decoding: stderr.value, as: UTF8.self))
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var value: Data { lock.withLock { data } }
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? Substring(text)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Scan

    /// No ripgrep and no repository: every text file under `root`, skipping
    /// dependency and build folders, hidden ones, and anything over 2 MB.
    private static func scan(_ root: String, options: ProjectSearchOptions, matcher: ProjectSearchMatcher,
                             into batcher: Batcher) async throws {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        let globs = options.globs
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 2_000_000 else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            guard ProjectSearchGlobs.includes(relative, globs: globs),
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var number = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                number += 1
                let line = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
                let ranges = matcher.ranges(in: line)
                guard !ranges.isEmpty else { continue }
                if !(await batcher.add(ProjectSearchMatch(path: relative, line: number, text: line, ranges: ranges))) {
                    return
                }
            }
        }
    }
}
