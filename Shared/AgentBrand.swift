import Foundation

/// Agent vendor identity: display name, logo asset, and brand hue.
///
/// Hues are each vendor's published color, adjusted only where the published
/// value is unreadable on a dark or light panel. Vendors that sign in black
/// have no hue and render in the neutral ink.
struct AgentBrand: Equatable {
    let id: String
    let displayName: String
    /// Hex like `#d97757`, or nil for monochrome brands.
    let hueHex: String?

    /// Asset catalog image name for the vendor mark, if bundled.
    var logoAssetName: String? {
        Self.logoIds.contains(id) ? "agent-\(id)" : nil
    }

    static func forAgent(_ rawAgent: String?) -> AgentBrand? {
        guard let raw = rawAgent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        let id = aliases[raw] ?? raw
        return AgentBrand(
            id: id,
            displayName: displayNames[id] ?? rawAgent!,
            hueHex: hues[id] ?? (displayNames[id] != nil ? nil : hues["other"])
        )
    }

    /// A process-table executable that represents a model CLI. This is kept
    /// deliberately narrower than every branded integration: Runtime should
    /// not call an unrelated helper process an agent merely because it has a
    /// logo elsewhere in Octet.
    static func runtimeAgentID(forExecutable raw: String) -> String? {
        let command = (raw as NSString).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        let ids = ["claude": "claude", "codex": "codex", "pi": "pi", "qwen": "qwen",
                   "qwen-code": "qwen", "opencode": "opencode"]
        return ids[command]
    }

    // Brand hues.
    static let hues: [String: String] = [
        "claude": "#d97757",
        "gemini": "#4285f4",
        "kimi": "#1783ff",
        "deepseek": "#4d6bfe",
        "qwen": "#615ced",
        "kiro": "#9046ff",
        "cline": "#586876",
        "kilo": "#9a9808",
        "other": "#c78a1f",
    ]

    // Display names.
    static let displayNames: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "omp": "OhMyPosh",
        "cline": "Cline", "mastracode": "Mastra", "kimi": "Kimi", "kilo": "Kilo", "maki": "Maki",
        "pi": "Pi", "hermes": "Hermes", "cursor": "Cursor", "copilot": "Copilot",
        "deepseek": "DeepSeek", "gemini": "Gemini", "gpt": "GPT", "qwen": "Qwen", "grok": "grok",
        "agy": "Antigravity", "kiro": "Kiro", "amp": "Amp", "devin": "Devin", "qodercli": "Qoder",
    ]

    /// Agent ids the session server reports that differ from the logo keys.
    static let aliases: [String: String] = [
        "claude_code": "claude", "claude-code": "claude", "antigravity": "agy",
        "open_code": "opencode", "github_copilot": "copilot", "hermes-agent": "hermes",
    ]

    static let logoIds: Set<String> = [
        "agy", "amp", "claude", "cline", "codex", "copilot", "cursor", "deepseek", "devin",
        "gemini", "gpt", "grok", "hermes", "kilo", "kimi", "kiro", "maki", "mastracode",
        "omp", "opencode", "pi", "qodercli", "qwen",
    ]
}

/// State colors: green and red are
/// semantic and outrank branding.
enum AgentStateColor {
    static let done = "#4c9a5a"
    static let blocked = "#c04a4a"
    static let unknown = "#907aa9"
    static let none = "#9a9eb3"
}
