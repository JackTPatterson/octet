import Foundation

/// An agent launched in one project that keeps working in another: every
/// command `cd`s over there first (`cd ~/code/api && npm test`), or Codex is
/// handed that folder as its `workdir`. Read from the agent's own
/// transcript, since the agent's process never moves: only its commands do.
enum AgentDrift {
    /// How many commands in a row have to go to the same other project
    /// before it counts as where the agent is really working.
    static let streak = 3

    /// The repository the agent's last `streak` commands all worked in, when
    /// that isn't the one it was launched in; nil otherwise.
    static func destination(
        targets: [String],
        launchCwd: String,
        gitRoot: (String) -> String?
    ) -> String? {
        guard targets.count >= streak else { return nil }
        let roots = targets.suffix(streak).map(gitRoot)
        guard let root = roots.first ?? nil, roots.allSatisfy({ $0 == root }) else { return nil }
        let launch = standardized(launchCwd)
        let launchRoot = gitRoot(launch) ?? launch
        // Somewhere inside the project it's in, or around it, is still that project.
        guard root != launchRoot, !launch.hasPrefix(root + "/"), !root.hasPrefix(launchRoot + "/") else { return nil }
        return root
    }

    /// The folders a transcript's commands worked in, oldest first. `base` is
    /// where a relative `cd` starts from: the folder the agent was launched in.
    static func targets(transcript lines: [String], base: String) -> [String] {
        lines.flatMap { line -> [String] in
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            return commands(in: entry).compactMap { directory(of: $0.command, workdir: $0.workdir, base: base) }
        }
    }

    /// Shell commands in one transcript entry, Claude's or Codex's.
    static func commands(in entry: [String: Any]) -> [(command: String, workdir: String?)] {
        // Claude: an assistant message's Bash tool calls.
        if let message = entry["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                      let command = (block["input"] as? [String: Any])?["command"] as? String else { return nil }
                return (command, nil)
            }
        }
        // Codex: a function call whose arguments are a JSON string.
        guard let payload = entry["payload"] as? [String: Any], payload["type"] as? String == "function_call",
              let raw = payload["arguments"] as? String, let data = raw.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let workdir = arguments["workdir"] as? String
        if let command = arguments["cmd"] as? String ?? arguments["command"] as? String { return [(command, workdir)] }
        if let argv = arguments["command"] as? [String], !argv.isEmpty {
            // `["bash", "-lc", "cd … && …"]`: the script is the last word.
            let shells: Set<String> = ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"]
            return [(shells.contains(argv[0]) && argv.count >= 3 ? argv[argv.count - 1] : argv.joined(separator: " "), workdir)]
        }
        return workdir.map { [("", $0)] } ?? []
    }

    /// Where a command runs: the folder a leading `cd` goes to, else its
    /// `workdir`, else nowhere in particular (nil).
    static func directory(of command: String, workdir: String?, base: String) -> String? {
        let from = workdir.map { resolve($0, from: base) } ?? base
        let pattern = #"^\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))\s*(?:&&|;|\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else {
            return workdir.map { resolve($0, from: base) }
        }
        let path = (1...3).lazy.compactMap { Range(match.range(at: $0), in: command).map { String(command[$0]) } }.first
        guard let path, path != "-" else { return workdir.map { resolve($0, from: base) } }
        return resolve(path, from: from)
    }

    static func resolve(_ path: String, from base: String, home: String = NSHomeDirectory()) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return standardized(expanded.hasPrefix("/") ? expanded : base + "/" + expanded)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
