import Foundation

/// One MCP server a conversation's agent has, and whether it's working,
/// read from whichever shape the agent reports it in.
struct MCPServerState: Equatable, Identifiable {
    enum Status: String {
        case connected, starting, failed, needsAuth, disabled, unknown

        var title: String {
            switch self {
            case .connected: "Connected"
            case .starting: "Starting"
            case .failed: "Failed"
            case .needsAuth: "Needs sign-in"
            case .disabled: "Off"
            case .unknown: "Unknown"
            }
        }

        /// Something the person should look at.
        var isProblem: Bool { self == .failed || self == .needsAuth }
    }

    let name: String
    let status: Status
    /// Why it failed, or how many tools it offers.
    var detail: String?

    var id: String { name }

    /// Octet's own permission server, which every Claude conversation has.
    static let hidden: Set<String> = [PermissionMCP.serverName]

    /// Every agent's words for a server's state, as one.
    static func status(_ raw: String?) -> Status {
        switch raw?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "connected", "ready": .connected
        case "pending", "starting", "connecting", "notstarted", "not-started": .starting
        case "failed", "error", "disconnected", "cancelled": .failed
        case "needs-auth", "authenticationrequired", "needs-client-registration", "needs-login": .needsAuth
        case "disabled": .disabled
        default: .unknown
        }
    }

    /// Claude Code's `mcp_status` answer and Qwen Code's and Claude Code's
    /// init event: `[{name, status, error?}]`.
    static func list(_ servers: [[String: Any]]) -> [MCPServerState] {
        servers.compactMap { server in
            guard let name = server["name"] as? String, !hidden.contains(name) else { return nil }
            return MCPServerState(name: name, status: status(server["status"] as? String),
                                  detail: server["error"] as? String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Codex's `mcpServerStatus/list`: `{data: [{name, runtimeStatus,
    /// toolsError, tools, authStatus}]}`.
    static func codex(_ result: [String: Any]) -> [MCPServerState] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { server in
            guard let name = server["name"] as? String else { return nil }
            var state = status(server["runtimeStatus"] as? String)
            if state == .unknown, server["authStatus"] as? String == "notLoggedIn" { state = .needsAuth }
            let tools = (server["tools"] as? [String: Any])?.count
            let detail = server["toolsError"] as? String ?? tools.map { $0 == 1 ? "1 tool" : "\($0) tools" }
            return MCPServerState(name: name, status: state, detail: detail)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// OpenCode's `GET /mcp`: `{name: {status, error?}}`.
    static func openCode(_ servers: [String: Any]) -> [MCPServerState] {
        servers.compactMap { name, value -> MCPServerState? in
            guard let server = value as? [String: Any] else { return nil }
            return MCPServerState(name: name, status: status(server["status"] as? String), detail: server["error"] as? String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
