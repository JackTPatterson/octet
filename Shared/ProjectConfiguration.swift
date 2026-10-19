import Foundation

/// Repository-owned settings. Optional fields allow a local file to override
/// only the sections it names; malformed configuration never runs commands.
struct ProjectConfiguration: Codable, Equatable {
    struct Action: Codable, Equatable {
        var id: String
        var name: String
        var command: String
        var icon: String?
    }
    struct Tab: Codable, Equatable {
        var title: String
        var command: String
    }
    var version: Int? = nil
    var setup: String? = nil
    var archive: String? = nil
    var archiveTimeoutSeconds: Int? = nil
    var waitForSetup: Bool? = nil
    var copyPaths: [String]? = nil
    var sharedDirectories: [String]? = nil
    var actions: [Action]? = nil
    var defaultTabs: [Tab]? = nil

    static let fileName = "octet.json"
    static let localName = ".octet/local.json"

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw ConfigError.invalid("Project configuration exceeds 256 KB.") }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let known: Set<String> = ["version", "setup", "archive", "archiveTimeoutSeconds", "waitForSetup", "copyPaths", "sharedDirectories", "actions", "defaultTabs"]
            let unknown = Set(object.keys).subtracting(known)
            guard unknown.isEmpty else { throw ConfigError.invalid("Unknown project settings: " + unknown.sorted().joined(separator: ", ")) }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == nil || value.version == 1 else { throw ConfigError.invalid("Unsupported octet.json version; expected 1.") }
        for path in (value.copyPaths ?? []) + (value.sharedDirectories ?? []) {
            guard safeRelativePath(path) else { throw ConfigError.invalid("Invalid project path: \(path)") }
        }
        if let timeout = value.archiveTimeoutSeconds, !(1...3600).contains(timeout) { throw ConfigError.invalid("Archive timeout must be 1–3600 seconds.") }
        let actions = value.actions ?? []
        guard actions.count <= 100, Set(actions.map(\.id)).count == actions.count,
              actions.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (value.defaultTabs ?? []).count <= 12,
              (value.defaultTabs ?? []).allSatisfy({ !$0.title.isEmpty && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (value.copyPaths ?? []).count + (value.sharedDirectories ?? []).count <= 1000 else { throw ConfigError.invalid("Invalid or duplicate project actions, or too many default tabs.") }
        return value
    }

    func overriding(with local: Self) -> Self {
        var result = self
        result.version = local.version ?? version
        result.setup = local.setup ?? setup
        result.archive = local.archive ?? archive
        result.archiveTimeoutSeconds = local.archiveTimeoutSeconds ?? archiveTimeoutSeconds
        result.waitForSetup = local.waitForSetup ?? waitForSetup
        result.copyPaths = local.copyPaths ?? copyPaths
        result.sharedDirectories = local.sharedDirectories ?? sharedDirectories
        result.defaultTabs = local.defaultTabs ?? defaultTabs
        if let overrides = local.actions {
            result.actions = (actions ?? []).filter { old in !overrides.contains { $0.id == old.id } } + overrides
        }
        return result
    }

    /// The checked-out branch owns shared config; the primary checkout owns local overrides.
    static func load(checkout: String, root: String? = nil) throws -> Self {
        func read(_ path: String) throws -> Self {
            guard FileManager.default.fileExists(atPath: path) else { return Self() }
            do { return try decode(Data(contentsOf: URL(fileURLWithPath: path))) }
            catch { throw ConfigError.invalid("\(path): \(error.localizedDescription)") }
        }
        return try read(checkout + "/" + fileName)
            .overriding(with: read((root ?? checkout) + "/" + localName))
    }

    static func safeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && !path.contains("\n") && !path.contains("\r")
            && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" })
            && !path.contains(where: { "*?[]!".contains($0) })
    }

    enum ConfigError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let reason): reason } }
    }
}

/// Copy/link explicitly named ignored paths. No overwrite, traversal or symlink escape.
enum ProjectWorkspaceFiles {
    static func materialize(_ config: ProjectConfiguration, root: String, checkout: String) throws -> [String] {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let targetRoot = URL(fileURLWithPath: checkout).resolvingSymlinksInPath().standardizedFileURL
        var copied: [String] = []
        var used = Set<String>()
        for (path, shared) in (config.sharedDirectories ?? []).map({ ($0, true) }) + (config.copyPaths ?? []).map({ ($0, false) }) {
            guard used.insert(path).inserted else { continue }
            guard ProjectConfiguration.safeRelativePath(path) else { throw ProjectConfiguration.ConfigError.invalid("Invalid project path: \(path)") }
            let source = sourceRoot.appendingPathComponent(path)
            let target = targetRoot.appendingPathComponent(path)
            guard source.resolvingSymlinksInPath().path.hasPrefix(sourceRoot.path + "/") else {
                throw ProjectConfiguration.ConfigError.invalid("Project path escapes its checkout: \(path)")
            }
            guard fm.fileExists(atPath: source.path) else { throw ProjectConfiguration.ConfigError.invalid("Project path is missing: \(path)") }
            // check-ignore omits tracked paths unless --no-index is supplied.
            guard try git(["check-ignore", "-q", "--", path], in: root).status == 0,
                  try git(["ls-files", "--", path], in: root).output.isEmpty else {
                throw ProjectConfiguration.ConfigError.invalid("Only wholly gitignored paths may be copied or shared: \(path)")
            }
            // Refuse escaping nested symlinks before copying a directory tree.
            if let entries = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let entry as URL in entries {
                    guard entry.resolvingSymlinksInPath().path.hasPrefix(sourceRoot.path + "/") else {
                        throw ProjectConfiguration.ConfigError.invalid("Symlink escapes the repository: \(entry.lastPathComponent)")
                    }
                }
            }
            // Existing files and our shared-directory links are never overwritten.
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { continue }
            guard target.resolvingSymlinksInPath().path.hasPrefix(targetRoot.path + "/") else {
                throw ProjectConfiguration.ConfigError.invalid("Destination escapes its checkout: \(path)")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if shared {
                guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw ProjectConfiguration.ConfigError.invalid("Shared path must be a directory: \(path)")
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: source)
            } else {
                try fm.copyItem(at: source, to: target)
            }
            copied.append(path)
        }
        return copied
    }

    private static func git(_ args: [String], in root: String) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
