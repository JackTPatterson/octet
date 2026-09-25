import Foundation

/// What a fresh worktree needs before an agent can work in it: the
/// git-ignored env files the main checkout has and a checkout never gets,
/// the project's own setup script, and a port range of its own so two
/// worktrees' dev servers don't both want 3000.
enum WorktreeSetup {
    /// A worktree the session server just made.
    struct Created: Equatable {
        let repoRoot: String
        let checkoutPath: String
        let paneId: String?
    }

    /// From a `worktree.create` result.
    static func parse(_ result: [String: Any]) -> Created? {
        let workspace = result["workspace"] as? [String: Any]
        let info = workspace?["worktree"] as? [String: Any]
        guard let root = info?["repo_root"] as? String,
              let path = (info?["checkout_path"] as? String) ?? ((result["worktree"] as? [String: Any])?["path"] as? String),
              root != path else { return nil }
        return Created(repoRoot: root, checkoutPath: path, paneId: (result["root_pane"] as? [String: Any])?["pane_id"] as? String)
    }

    // MARK: - Env files

    /// Folders whose env files belong to a dependency or a build, not the project.
    static let skippedFolders: Set<String> = ["node_modules", ".git", "vendor", ".venv", "venv", "dist", "build", ".next", "target"]

    /// Of the ignored files git lists (`git ls-files --others --ignored
    /// --exclude-standard -- ':(glob)**/.env*'`), the project's env files:
    /// `.env`, `.env.local`, `apps/web/.env.development.local`, …
    static func envFiles(ignored: [String]) -> [String] {
        ignored.filter { path in
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last, name == ".env" || name.hasPrefix(".env.") else { return false }
            return !parts.dropLast().contains { skippedFolders.contains($0) }
        }
        .sorted()
    }

    /// The arguments that list them.
    static let listEnvFilesArguments = ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--", ":(glob)**/.env*"]

    /// Copies the main checkout's ignored env files that the worktree lacks,
    /// never overwriting one. Returns what it copied. Runs git; call it off
    /// the main thread.
    static func copyEnvFiles(from root: String, to checkout: String, git: String = "/usr/bin/git") -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", root] + listEnvFilesArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let ignored = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        let files = FileManager.default
        return envFiles(ignored: ignored).filter { relative in
            let source = (root as NSString).appendingPathComponent(relative)
            let target = (checkout as NSString).appendingPathComponent(relative)
            guard !files.fileExists(atPath: target) else { return false }
            try? files.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
            return (try? files.copyItem(atPath: source, toPath: target)) != nil
        }
    }

    // MARK: - Setup script

    enum Script: Equatable {
        /// `.octet/setup`, run as a program.
        case file(String)
        /// A command line, from `conductor.json`'s `scripts.setup`, so a
        /// project already set up for Conductor works as it is.
        case command(String)
    }

    static let scriptPath = ".octet/setup"

    /// The setup the worktree's own checkout asks for, if any.
    static func script(in checkout: String, isExecutable: (String) -> Bool, read: (String) -> Data?) -> Script? {
        let file = (checkout as NSString).appendingPathComponent(scriptPath)
        if isExecutable(file) { return .file(scriptPath) }
        if let data = read((checkout as NSString).appendingPathComponent("conductor.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = object["scripts"] as? [String: Any],
           let setup = (scripts["setup"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !setup.isEmpty {
            return .command(setup)
        }
        return nil
    }

    // MARK: - Ports

    static let firstPort = 3100
    static let portsPerWorktree = 10
    static let lastPort = 3999

    /// The first port of a free block of ten for `checkout`: the block it
    /// already has, else the lowest nobody else holds. Nil when every block
    /// is taken.
    static func port(for checkout: String, assigned: [String: Int]) -> Int? {
        if let existing = assigned[checkout] { return existing }
        let taken = Set(assigned.values)
        return stride(from: firstPort, through: lastPort - portsPerWorktree + 1, by: portsPerWorktree)
            .first { !taken.contains($0) }
    }

    /// The typed line that runs the script in the worktree's pane, with
    /// where it is and its ports in the environment. Visible in the pane,
    /// so what ran is never a mystery.
    static func commandLine(_ script: Script, created: Created, port: Int?, quote: (String) -> String) -> String {
        var exports = ["OCTET_ROOT_PATH=\(quote(created.repoRoot))", "OCTET_WORKTREE_PATH=\(quote(created.checkoutPath))"]
        if let port { exports.append("OCTET_PORT=\(port)") }
        let run: String
        switch script {
        case .file(let path): run = "./" + path
        case .command(let command): run = command
        }
        return "export " + exports.joined(separator: " ") + "; " + run
    }
}
