import Foundation

/// Whether this copy of Octet may write its own octet-cli path into the
/// agents' configs on its own (repairing hooks, syncing MCP servers). A copy
/// run from a temporary folder or an agent's worktree, e.g. to check a build,
/// would otherwise point Claude Code, Codex and OpenCode at a binary that's
/// about to be deleted. OCTET_NO_AGENT_CONFIG=1 turns it off explicitly.
enum AgentConfigWrites {
    static func allowed(bundlePath: String, environment: [String: String],
                        temporaryDirectory: String = NSTemporaryDirectory()) -> Bool {
        if environment["OCTET_NO_AGENT_CONFIG"] == "1" { return false }
        let path = (bundlePath as NSString).standardizingPath
        let temporary = (temporaryDirectory as NSString).standardizingPath
        let throwaway = ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
        if throwaway.contains(where: path.hasPrefix) || (!temporary.isEmpty && path.hasPrefix(temporary)) { return false }
        if path.contains("/.claude/worktrees/") { return false }
        return true
    }

    /// For this process.
    static var allowedHere: Bool {
        allowed(bundlePath: Bundle.main.bundlePath, environment: ProcessInfo.processInfo.environment)
    }
}
