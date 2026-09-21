import Foundation

/// An agent CLI Octet can configure. Nothing here is specific to one vendor:
/// agents keep their config in `~/.<agent>`, with `skills/` folders and a
/// prompts folder, so Octet discovers whichever ones are installed and treats
/// them alike. Skills, prompts, and MCP servers live once in Octet's shared
/// library and are installed into each host.
struct AgentHost: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Root of the host's own config (`~/.claude`, `~/.codex`, …).
    let home: String
    /// `<home>/skills/<slug>/SKILL.md`, the layout the agents share.
    let skillsDirectory: String
    /// Markdown prompt files the host exposes as slash commands. Agents name
    /// this folder either `commands` or `prompts`.
    let promptsDirectory: String
    /// Executable name, for plugin and MCP commands.
    let cli: String
    /// Whether the host keeps plugins (`<home>/plugins`).
    let supportsPlugins: Bool
    /// Whether its CLI manages MCP servers (`<cli> mcp …`).
    let supportsMCP: Bool

    func skillPath(_ slug: String) -> String { "\(skillsDirectory)/\(slug)" }
    func promptPath(_ slug: String) -> String { "\(promptsDirectory)/\(slug).md" }
}

enum AgentHosts {
    /// Agents whose CLI is named differently from their config folder.
    static let executables: [String: String] = [
        "agy": "antigravity", "cursor": "cursor-agent", "omp": "oh-my-posh",
    ]

    /// Agents whose CLI exposes `mcp` subcommands Octet can drive.
    static let mcpCapable: Set<String> = ["claude", "codex"]

    /// Agents that name their prompt folder `commands` rather than `prompts`.
    static let commandFolders: Set<String> = ["claude"]

    /// Shown first because Octet knows the most about them; the rest follow
    /// alphabetically.
    static let preferredOrder = ["claude", "codex"]

    /// Every agent Octet knows the name of, whether or not it is installed.
    static func all(home: String = NSHomeDirectory()) -> [AgentHost] {
        let ids = Set(AgentBrand.displayNames.keys).union(AgentBrand.logoIds).subtracting(["gpt", "omp"])
        return ids.map { host($0, home: home)! }
            .sorted { first, second in
                let firstRank = preferredOrder.firstIndex(of: first.id) ?? preferredOrder.count
                let secondRank = preferredOrder.firstIndex(of: second.id) ?? preferredOrder.count
                return firstRank == secondRank
                    ? first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
                    : firstRank < secondRank
            }
    }

    /// The agents actually set up on this machine.
    static func installed(home: String = NSHomeDirectory()) -> [AgentHost] {
        all(home: home).filter { FileManager.default.fileExists(atPath: $0.home) }
    }

    static func host(_ id: String, home: String = NSHomeDirectory()) -> AgentHost? {
        let id = AgentBrand.forAgent(id)?.id ?? id
        guard !id.isEmpty else { return nil }
        let root = "\(home)/.\(id)"
        let manager = FileManager.default
        // Follow whichever prompt folder the agent already has, else its
        // documented default.
        let prompts: String
        if manager.fileExists(atPath: "\(root)/commands") {
            prompts = "\(root)/commands"
        } else if manager.fileExists(atPath: "\(root)/prompts") {
            prompts = "\(root)/prompts"
        } else {
            prompts = commandFolders.contains(id) ? "\(root)/commands" : "\(root)/prompts"
        }
        return AgentHost(
            id: id,
            displayName: AgentBrand.displayNames[id] ?? id.capitalized,
            home: root,
            skillsDirectory: "\(root)/skills",
            promptsDirectory: prompts,
            cli: executables[id] ?? id,
            supportsPlugins: manager.fileExists(atPath: "\(root)/plugins"),
            supportsMCP: mcpCapable.contains(id)
        )
    }
}
