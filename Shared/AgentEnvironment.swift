import Foundation

/// Agents mark their own child processes through the environment (Claude
/// Code's `CLAUDECODE`, session ids, sandbox markers). When Octet is launched
/// from inside an agent's shell, those markers reach every pane it opens and
/// the agents started there behave as nested children — Claude Code, for one,
/// stops saving transcripts, which also costs Octet its session recovery.
/// Octet drops them from its own environment at launch, for every agent.
enum AgentEnvironment {
    /// Marker names an agent sets on its children, whatever the vendor.
    static let exactNames: Set<String> = ["CLAUDECODE", "CODEXCLI", "CURSOR_AGENT", "OPENCODE"]

    /// Anything like `<AGENT>_..._SESSION`, `..._CHILD_SESSION`, an agent's
    /// entrypoint marker, or its sandbox flag.
    static let suffixes = ["_CHILD_SESSION", "_SESSION_ID", "_SESSION", "_ENTRYPOINT", "_PARENT_SESSION"]

    /// Prefixes of known agent CLIs, so unrelated variables are left alone.
    static var prefixes: [String] {
        let ids = Set(AgentBrand.displayNames.keys).union(AgentBrand.logoIds)
        return ids.map { $0.uppercased().replacingOccurrences(of: "-", with: "_") } + ["CLAUDE_CODE", "CODEX", "AGENT"]
    }

    /// The names to drop from `environment`.
    static func markers(in environment: [String: String]) -> [String] {
        environment.keys.filter { name in
            if exactNames.contains(name) { return true }
            guard prefixes.contains(where: { name.hasPrefix($0 + "_") || name == $0 }) else { return false }
            return suffixes.contains { name.hasSuffix($0) }
        }
        .sorted()
    }

    /// Environment without the markers, for spawning panes.
    static func sanitized(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        for name in markers(in: environment) { environment.removeValue(forKey: name) }
        return environment
    }

    /// Drops the markers from this process, so everything Octet spawns —
    /// panes, shells, agents — starts as its own session.
    @discardableResult
    static func clearInheritedMarkers() -> [String] {
        let names = markers(in: ProcessInfo.processInfo.environment)
        for name in names { unsetenv(name) }
        return names
    }
}
