import Foundation

/// One agent Octet looked for on this machine.
///
/// `AgentHosts.installed` answers a narrower question: whether an agent keeps
/// config in `~/.<agent>`. That misses a CLI installed but never run, and
/// counts one uninstalled but leaving its folder behind. Discovery looks for
/// the executable itself, and asks it what version it is.
struct DiscoveredAgent: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    /// Where the executable is, if it was found.
    var executablePath: String?
    /// The first line of `<cli> --version`, when it answers.
    var version: String?
    /// Its config folder, when it has one.
    var configPath: String?
    /// The command as you would type it.
    var command: String
    /// Whether that command resolves on the login shell's PATH, so a shell
    /// can run it by name. Nil in scans saved before this was recorded.
    var onShellPath: Bool?

    /// Found as an executable, config on disk, or both.
    var isPresent: Bool { executablePath != nil || configPath != nil }
    /// Installed but never run, or run and then removed.
    var isConfigured: Bool { configPath != nil }
}

/// Looks for every agent CLI Octet knows the name of.
///
/// Octet is a GUI app, so its own PATH is whatever launched it, usually
/// launchd's. The shell's PATH is the honest one, and beyond it agents land
/// in a handful of per-tool bin folders that installers add to a shell
/// profile Octet never reads.
enum AgentDiscovery {
    /// Bin folders that are not always on PATH, in the order they should win.
    static let extraDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        "~/.local/bin", "~/bin", "~/.bun/bin", "~/.deno/bin", "~/.cargo/bin", "~/go/bin",
        "~/.volta/bin", "~/.asdf/shims", "~/.npm-global/bin", "~/.yarn/bin",
        "~/Library/pnpm", "~/.nvm/versions/node",
    ]

    /// Every place to look: the login shell's PATH first, then the folders
    /// installers use, then each agent's own `~/.<agent>/bin`.
    static func searchDirectories(shellPath: String?, home: String = NSHomeDirectory()) -> [String] {
        var directories = (shellPath?.components(separatedBy: ":") ?? []).filter { !$0.isEmpty }
        directories += extraDirectories.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        // NVM keeps executables under a versioned directory. GUI launches
        // often do not source the shell line that adds the active one to PATH.
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            directories += versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending })
                .map { nvmRoot + "/" + $0 + "/bin" }
        }
        directories += AgentHosts.all(home: home).map { "\($0.home)/bin" }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    /// The executable `command` resolves to, or nil. Symlinks are kept as
    /// found: where it is on PATH is the answer, not where it points.
    static func locate(command: String, in directories: [String]) -> String? {
        let manager = FileManager.default
        for directory in directories {
            let path = directory + "/" + command
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  manager.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }

    /// What every known agent looks like on this machine. `version` runs each
    /// CLI it found, so this belongs off the main thread.
    static func scan(home: String = NSHomeDirectory(), readVersions: Bool = true) -> [DiscoveredAgent] {
        scanRecordingFingerprint(home: home, readVersions: readVersions).agents
    }

    /// A scan, plus a fingerprint of what it looked at so a later cheap check
    /// can tell whether anything changed since.
    static func scanRecordingFingerprint(home: String = NSHomeDirectory(), readVersions: Bool = true)
        -> (agents: [DiscoveredAgent], fingerprint: AgentDiscoveryFingerprint?) {
        let shellPath = loginShellPath()
        let pathDirectories = (shellPath ?? "").components(separatedBy: ":").filter { !$0.isEmpty }
        let directories = searchDirectories(shellPath: shellPath, home: home)
        // Stamped before looking, so a change made mid-scan shows next time.
        let directoryStamps = AgentDiscoveryFingerprint.record(shellPath: shellPath ?? "", directories: directories,
                                                               executables: [], home: home)
        let manager = FileManager.default
        var agents = AgentHosts.all(home: home).map { host in
            let command = AgentHosts.executables[host.id] ?? host.cli
            let path = locate(command: command, in: directories)
            var agent = DiscoveredAgent(id: host.id, displayName: host.displayName, executablePath: path,
                                        version: nil,
                                        configPath: manager.fileExists(atPath: host.home) ? host.home : nil,
                                        command: command)
            // A shell runs the first match on its PATH, so the bare name is
            // safe only when that match is the one found here.
            agent.onShellPath = path.map { locate(command: command, in: pathDirectories) == $0 }
            return agent
        }
        // Before the versions run, for the same reason. Without a shell
        // PATH there's no baseline worth trusting, so the next check rescans.
        var fingerprint: AgentDiscoveryFingerprint?
        if shellPath != nil {
            fingerprint = directoryStamps
            for path in agents.compactMap(\.executablePath) { fingerprint?.executables[path] = FileStamp.of(path) }
        }
        if readVersions {
            // All at once: one after another, a few slow CLIs add up.
            let versions = VersionResults(count: agents.count)
            let paths = agents.map(\.executablePath)
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                if let path = paths[index] { versions.set(index, version(of: path)) }
            }
            for index in agents.indices { agents[index].version = versions.get(index) }
        }
        let present = agents
        .filter(\.isPresent)
        .sorted { first, second in
            let ranks = (AgentHosts.preferredOrder.firstIndex(of: first.id) ?? AgentHosts.preferredOrder.count,
                         AgentHosts.preferredOrder.firstIndex(of: second.id) ?? AgentHosts.preferredOrder.count)
            return ranks.0 == ranks.1
                ? first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
                : ranks.0 < ranks.1
        }
        return (present, fingerprint)
    }

    /// Versions read on several threads at once.
    private final class VersionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?]

        init(count: Int) { values = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ value: String?) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }

        func get(_ index: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[index]
        }
    }

    /// `<cli> --version`, trimmed to its first line. A CLI that doesn't take
    /// the flag, hangs, or writes a paragraph gets nothing rather than noise.
    static func version(of path: String) -> String? {
        guard let output = run(path, ["--version"], timeout: 4) else { return nil }
        guard let line = output.components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }), line.count <= 80 else { return nil }
        return line
    }

    /// The PATH a terminal would have. Read once per scan.
    static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return run(shell, ["-l", "-c", "echo $PATH"], timeout: 6)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command and returns its output, killing it at `timeout`. An
    /// agent CLI that waits on input or a network call must not hold a scan.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
