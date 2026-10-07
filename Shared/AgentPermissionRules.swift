import Foundation

/// "Always allow" for Claude Code: turning the request on the screen into a
/// rule narrow enough to keep, the way Claude Code writes them in
/// `.claude/settings.local.json` (`Bash(swift test:*)`, `Edit`,
/// `WebFetch(domain:docs.swift.org)`), and reading and editing that file.
///
/// A rule is only offered when it can be narrow. A command that can delete,
/// publish, run other code or reach the network is allowed once or for the
/// session, never for good; one that chains commands is matched whole.
enum AgentPermissionRules {
    struct Rule: Equatable {
        /// What goes in the settings file.
        let text: String
        /// What the button says.
        let title: String
    }

    // MARK: - From a request to a rule

    static func rule(forTool name: String, input: [String: Any]) -> Rule? {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return Rule(text: "Edit", title: "Always Allow Edits")
        case "Bash":
            return bashRule(input["command"] as? String ?? "")
        case "WebFetch":
            guard let host = (input["url"] as? String).flatMap({ URL(string: $0)?.host }), !host.isEmpty else { return nil }
            return Rule(text: "WebFetch(domain:\(host))", title: "Always Allow \(host)")
        case "ExitPlanMode", "AskUserQuestion", "":
            return nil
        default:
            return Rule(text: name, title: "Always Allow \(displayName(name))")
        }
    }

    /// `mcp__github__create_issue` reads as `github: create issue`.
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return tool }
        return "\(parts[0]): \(parts[1...].joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
    }

    static func bashRule(_ raw: String) -> Rule? {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.count <= 200,
              !command.contains("("), !command.contains(")"), !command.contains("\n") else { return nil }
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = tokens.first(where: { !isAssignment($0) }) else { return nil }
        let name = (program as NSString).lastPathComponent
        if refused.contains(name) { return nil }
        // A search that deletes or runs things.
        if [" -exec", " -execdir", " -delete", " -ok "].contains(where: command.contains) { return nil }
        if isCompound(command) {
            // Matched whole, never as a prefix, and only if no part of it is
            // something that is never kept.
            let parts = command.components(separatedBy: CharacterSet(charactersIn: "&|;\n`$<>"))
            for part in parts {
                let first = part.split(whereSeparator: \.isWhitespace).map(String.init).first { !isAssignment($0) }
                if let first, refused.contains((first as NSString).lastPathComponent) { return nil }
            }
            return exact(command)
        }
        let index = tokens.firstIndex(of: program) ?? 0
        let after = Array(tokens[(index + 1)...])
        if subcommanded.contains(name) {
            guard let sub = after.first, !sub.hasPrefix("-") else { return exact(command) }
            if (refusedSubcommands[name] ?? []).contains(sub) { return nil }
            var prefix = tokens[...(index + 1)].joined(separator: " ")
            // `npm run build`, not every script.
            if sub == "run", ["npm", "pnpm", "yarn", "bun"].contains(name), after.count >= 2, !after[1].hasPrefix("-") {
                prefix += " " + after[1]
            }
            return Rule(text: "Bash(\(prefix):*)", title: "Always Allow “\(prefix)”")
        }
        if readOnly.contains(name), !(name == "find" && command.contains("-exec")) {
            let prefix = tokens[...index].joined(separator: " ")
            return Rule(text: "Bash(\(prefix):*)", title: "Always Allow “\(prefix)”")
        }
        return exact(command)
    }

    private static func exact(_ command: String) -> Rule {
        let shown = command.count > 36 ? String(command.prefix(34)) + "…" : command
        return Rule(text: "Bash(\(command))", title: "Always Allow “\(shown)”")
    }

    private static func isAssignment(_ token: String) -> Bool {
        token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    /// More than one command, a redirect, a substitution or a background job.
    static func isCompound(_ command: String) -> Bool {
        ["&&", "||", ";", "|", "$(", "`", ">", "<", "&", "\n"].contains { command.contains($0) }
    }

    /// Never offered for good: they delete, escalate, run other code, or reach out.
    private static let refused: Set<String> = [
        "rm", "rmdir", "sudo", "su", "doas", "dd", "mkfs", "shred", "chmod", "chown", "kill", "killall", "pkill",
        "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "eval", "exec", "sh", "bash", "zsh", "fish",
        "source", "xargs", "env", "python", "python3", "node", "ruby", "perl", "php", "osascript", "open", "mv", "cp",
        "ln", "tee", "crontab", "launchctl", "defaults", "diskutil", "hdiutil", "security", "tar", "unzip", "zip",
    ]

    /// Programs whose first argument says what they do.
    private static let subcommanded: Set<String> = [
        "git", "npm", "pnpm", "yarn", "bun", "swift", "cargo", "go", "docker", "kubectl", "gh", "make", "xcodebuild",
        "brew", "pip", "pip3", "uv", "bundle", "gradle", "mvn", "dotnet", "deno", "flutter", "dart", "rake", "poetry",
        "composer", "terraform", "helm", "xcrun", "swiftlint", "swiftformat",
    ]

    private static let refusedSubcommands: [String: Set<String>] = [
        "git": ["push", "reset", "clean", "rebase", "checkout", "restore", "rm", "filter-branch", "gc", "prune", "switch",
                "stash", "branch", "tag", "remote", "config", "commit", "merge", "cherry-pick", "revert", "pull", "fetch",
                "clone", "init", "worktree", "submodule", "apply", "am", "update-ref", "reflog"],
        "npm": ["publish", "unpublish", "login", "adduser", "deprecate", "owner", "access", "exec", "install", "i", "ci", "uninstall"],
        "pnpm": ["publish", "login", "exec", "dlx", "install", "i", "add", "remove"],
        "yarn": ["publish", "npm", "dlx", "install", "add", "remove"],
        "bun": ["publish", "x", "install", "add", "remove", "create"],
        "cargo": ["publish", "yank", "login", "owner", "install", "uninstall", "add", "remove"],
        "docker": ["rm", "rmi", "system", "volume", "network", "run", "exec", "push", "login", "kill", "stop", "compose", "container", "image"],
        "kubectl": ["delete", "apply", "exec", "create", "replace", "patch", "edit", "scale", "rollout", "drain", "cordon", "run", "cp"],
        "gh": ["repo", "pr", "release", "auth", "secret", "api", "workflow", "gist", "issue", "ssh-key", "gpg-key", "extension", "alias"],
        "brew": ["uninstall", "remove", "install", "upgrade", "reinstall", "untap", "tap", "cleanup", "link", "unlink"],
        "pip": ["install", "uninstall"], "pip3": ["install", "uninstall"],
        "uv": ["pip", "tool", "publish", "add", "remove", "run"],
        "terraform": ["apply", "destroy", "import", "taint", "untaint", "state", "force-unlock", "login"],
        "helm": ["install", "upgrade", "uninstall", "delete", "rollback"],
        "gem": ["install", "uninstall", "push", "yank"],
        "composer": ["install", "require", "remove", "update"],
        "poetry": ["publish", "add", "remove", "install", "run"],
        "bundle": ["install", "exec", "add", "remove"],
        "xcrun": ["simctl", "notarytool", "altool", "stapler"],
        "dotnet": ["publish", "nuget", "add", "remove", "new", "tool"],
        "deno": ["install", "run", "eval", "publish", "task"],
        "make": [], "swift": ["package"],
    ]

    /// Reads and checks, nothing else.
    private static let readOnly: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "echo", "pwd", "grep", "rg", "which", "stat", "file", "diff", "sort", "uniq",
        "tree", "du", "df", "date", "whoami", "uname", "basename", "dirname", "realpath", "find", "fd", "jq", "cut", "tr",
    ]

    // MARK: - Does a rule cover a request

    /// Whether any of `rules` covers this tool call. Only forms Octet writes
    /// are understood; anything else is left to Claude Code to apply.
    static func allows(_ rules: [String], tool: String, input: [String: Any]) -> Bool {
        rules.contains { covers($0, tool: tool, input: input) }
    }

    static func covers(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        let (name, spec) = parse(rule)
        let edits: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
        if name == "Edit" { return spec == nil && edits.contains(tool) }
        guard name == tool else { return false }
        guard let spec else { return true }
        switch tool {
        case "Bash":
            let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return false }
            // A whole command matches only itself.
            guard spec.hasSuffix(":*") else { return command == spec }
            // A prefix never covers a chain.
            guard !isCompound(command) else { return false }
            let prefix = String(spec.dropLast(2))
            return command == prefix || command.hasPrefix(prefix + " ")
        case "WebFetch":
            guard spec.hasPrefix("domain:"), let host = (input["url"] as? String).flatMap({ URL(string: $0)?.host }) else { return false }
            return host == String(spec.dropFirst("domain:".count))
        default:
            return false
        }
    }

    /// `Bash(swift test:*)` as ("Bash", "swift test:*"); `Edit` as ("Edit", nil).
    static func parse(_ rule: String) -> (name: String, spec: String?) {
        guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else { return (rule, nil) }
        return (String(rule[..<open]), String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)]))
    }

    // MARK: - The settings file

    /// Where "always" is kept for a conversation in `cwd`: Claude Code's
    /// per-project file that isn't meant for version control.
    static func localSettingsPath(cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(".claude/settings.local.json")
    }

    static func sharedSettingsPath(cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(".claude/settings.json")
    }

    /// The allow rules in a settings file's contents.
    static func allowRules(in data: Data?) -> [String] {
        guard let data, !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let permissions = object["permissions"] as? [String: Any] else { return [] }
        return (permissions["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The file with `rule` among its allow rules, everything else kept.
    /// Nil when the file isn't a JSON object, which is left alone.
    static func adding(_ rule: String, to data: Data?) -> Data? {
        edited(data) { allow in
            if !allow.contains(rule) { allow.append(rule) }
        }
    }

    static func removing(_ rule: String, from data: Data?) -> Data? {
        edited(data) { allow in allow.removeAll { $0 == rule } }
    }

    private static func edited(_ data: Data?, _ change: (inout [String]) -> Void) -> Data? {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            root = object
        }
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = (permissions["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
        // A rule that isn't a string is kept as it was.
        let others = (permissions["allow"] as? [Any])?.filter { !($0 is String) } ?? []
        change(&allow)
        permissions["allow"] = allow as [Any] + others
        root["permissions"] = permissions
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
