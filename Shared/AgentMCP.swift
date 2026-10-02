import Foundation

/// Puts one of Octet's own stdio MCP servers (the other-Macs tools, the
/// delegation tools) into each installed agent's settings, the way that
/// agent takes it: its own `mcp add` where it has one, else its JSON config.
enum AgentMCP {
    /// A server: run as `command args…` over stdio.
    struct Server: Equatable {
        let name: String
        let command: String
        let args: [String]
    }

    /// One thing to do for one agent.
    enum Step: Equatable {
        /// A shell command; one that fails saying it's already there, or
        /// already gone, still counts as done.
        case run(String)
        /// Add or remove the server under `key` in a JSON config file.
        case json(path: String, key: String, entry: [String: MCPConfigValue]?)
    }

    /// The agents Octet knows how to give a server to.
    static let supported = ["claude", "codex", "gemini", "qwen", "opencode", "cursor", "copilot"]

    /// What adds `server` to `agent`, after removing any earlier copy so a
    /// moved app's path is picked up; nil for an agent without MCP support.
    static func install(_ server: Server, agent: String, home: String = NSHomeDirectory()) -> [Step]? {
        let invocation = ([server.command] + server.args).map(quote).joined(separator: " ")
        let name = quote(server.name)
        switch agent {
        case "claude":
            return [.run("claude mcp remove --scope user \(name)"),
                    .run("claude mcp add --scope user \(name) -- \(invocation)")]
        case "codex":
            return [.run("codex mcp remove \(name)"),
                    .run("codex mcp add \(name) -- \(invocation)")]
        case "gemini", "qwen":
            return [.run("\(agent) mcp remove --scope user \(name)"),
                    .run("\(agent) mcp add --scope user \(name) \(invocation)")]
        case "opencode":
            return [.json(path: opencodeConfig(home: home), key: "mcp", entry: [
                "type": .string("local"),
                "command": .array(([server.command] + server.args).map(MCPConfigValue.string)),
                "enabled": .bool(true),
            ])]
        case "cursor":
            return [.json(path: "\(home)/.cursor/mcp.json", key: "mcpServers", entry: [
                "command": .string(server.command), "args": .array(server.args.map(MCPConfigValue.string)),
            ])]
        case "copilot":
            return [.json(path: "\(home)/.copilot/mcp-config.json", key: "mcpServers", entry: [
                "type": .string("local"), "command": .string(server.command),
                "args": .array(server.args.map(MCPConfigValue.string)), "tools": .array([.string("*")]),
            ])]
        default:
            return nil
        }
    }

    /// What takes `server` back out of `agent`.
    static func remove(_ server: Server, agent: String, home: String = NSHomeDirectory()) -> [Step]? {
        let name = quote(server.name)
        switch agent {
        case "claude": return [.run("claude mcp remove --scope user \(name)")]
        case "codex": return [.run("codex mcp remove \(name)")]
        case "gemini", "qwen": return [.run("\(agent) mcp remove --scope user \(name)")]
        case "opencode": return [.json(path: opencodeConfig(home: home), key: "mcp", entry: nil)]
        case "cursor": return [.json(path: "\(home)/.cursor/mcp.json", key: "mcpServers", entry: nil)]
        case "copilot": return [.json(path: "\(home)/.copilot/mcp-config.json", key: "mcpServers", entry: nil)]
        default: return nil
        }
    }

    static func opencodeConfig(home: String) -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        return "\(base)/opencode/opencode.json"
    }

    /// Whether a failed command's output says there was nothing to do.
    static func isHarmless(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return ["already", "not found", "no mcp server", "does not exist", "no server", "not exist"].contains { lowered.contains($0) }
    }

    /// `config` with the server set under `key` (or taken out when `entry`
    /// is nil), keeping everything else. Nil when the file isn't a JSON
    /// object, which is left alone rather than overwritten.
    static func edited(_ config: Data?, server: String, key: String, entry: [String: MCPConfigValue]?) -> Data? {
        var root: [String: Any] = [:]
        if let config, !config.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else { return nil }
            root = object
        }
        var servers = root[key] as? [String: Any] ?? [:]
        if let entry {
            servers[server] = entry.mapValues(\.any)
        } else {
            guard servers[server] != nil else { return config }
            servers[server] = nil
        }
        root[key] = servers
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func quote(_ value: String) -> String {
        guard value.contains(where: { !($0.isLetter || $0.isNumber || "-_./=:@".contains($0)) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The JSON a config entry is made of, comparable so steps can be tested.
enum MCPConfigValue: Equatable {
    case string(String)
    case bool(Bool)
    case array([MCPConfigValue])

    var any: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.any)
        }
    }
}
