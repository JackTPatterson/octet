import Foundation
import CoreFoundation

/// Read-only stdio tools reuse the CLI's Keychain-backed clients.
enum IssueMCP {
    static let serverName = "octet-issues"
    static let fields: [String: [String]] = [
        "connections": ["tracker"],
        "containers": ["tracker", "connection"],
        "list": ["tracker", "connection", "container", "scope", "who", "in", "cursor", "limit"],
        "read": ["tracker", "connection", "key", "in", "current", "include-comments"]
    ]
    static var tools: [[String: Any]] {
        fields.keys.sorted().map { action in
            var properties: [String: Any] = [:]
            for field in fields[action]! {
                var schema: [String: Any] = ["type": field == "limit" ? "integer" : ["current", "include-comments"].contains(field) ? "boolean" : "string"]
                if field == "tracker" { schema["enum"] = ["github", "linear", "jira"] }
                if field == "scope" { schema["enum"] = ["open", "closed", "all"] }
                if field == "who" { schema["enum"] = ["anyone", "assigned", "reported"] }
                if field == "limit" { schema["minimum"] = 1; schema["maximum"] = 1000; schema["default"] = 100 }
                properties[field] = schema
            }
            return ["name": "issues_" + action,
                    "description": action == "read" ? "Read an issue by tracker/key, or current:true with in set to a linked checkout. Optionally include-comments." : "Read issue \(action). List returns issues, truncated and nextCursor; reuse selectors with cursor to continue.",
                    "inputSchema": ["type": "object", "properties": properties, "required": action == "read" ? [] : ["tracker"], "additionalProperties": false],
                    "annotations": ["readOnlyHint": true, "destructiveHint": false]]
        }
    }
    static func arguments(action: String, values: [String: Any]) throws -> [String] {
        func invalid() -> IssueTrackerError { .unreadable("Invalid arguments for issues_\(action). Use the advertised schema; read requires tracker/key or current:true.") }
        guard let allowed = fields[action], Set(values.keys).isSubset(of: Set(allowed)) else { throw invalid() }
        var result = [action]
        for key in allowed {
            guard let value = values[key] else { continue }
            if ["current", "include-comments"].contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
                if number.boolValue { result.append("--" + key) }
            } else if key == "limit" {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue), (1...1000).contains(number.intValue) else { throw invalid() }
                result += ["--limit", String(number.intValue)]
            } else {
                guard let string = value as? String, !string.isEmpty, string.count <= 16384,
                      !string.hasPrefix("--"), !string.contains("\0") else { throw invalid() }
                let choices = ["tracker": ["github", "linear", "jira"], "scope": ["open", "closed", "all"], "who": ["anyone", "assigned", "reported"]]
                if let choices = choices[key], !choices.contains(string) { throw invalid() }
                result += ["--" + key, string]
            }
        }
        let current = result.contains("--current")
        guard current || values["tracker"] != nil else { throw invalid() }
        if action == "read" {
            guard current ? values["key"] == nil : values["key"] != nil else { throw invalid() }
        }
        if action == "list", values["limit"] == nil { result += ["--limit", "100"] }
        return result
    }
    static func respond(to line: String, call: ([String]) async throws -> Data) async -> String? {
        func encode(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        }
        func rpcError(_ id: Any, _ code: Int, _ message: String) -> String {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }
        guard line.utf8.count <= 65536, let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return rpcError(NSNull(), -32700, "Invalid JSON") }
        guard let request = parsed as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else { return rpcError(NSNull(), -32600, "Invalid request") }
        guard let id = request["id"] else { return nil }
        guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            return rpcError(NSNull(), -32600, "Invalid request ID")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": serverName, "version": "1.0"],
                      "instructions": "Read-only issue access through Octet's saved connections. Use in for repository/linked-worktree context. Continue lists using nextCursor with identical selectors. Credentials are never returned."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "tools/call":
            guard let name = params["name"] as? String, name.hasPrefix("issues_"), fields[String(name.dropFirst(7))] != nil,
                  let values = params["arguments"] as? [String: Any] else { return rpcError(id, -32602, "Unknown tool or invalid arguments") }
            let args: [String]
            do { args = try arguments(action: String(name.dropFirst(7)), values: values) }
            catch { return rpcError(id, -32602, error.localizedDescription) }
            do {
                let output = try await call(args)
                result = ["content": [["type": "text", "text": String(decoding: output, as: UTF8.self)]]]
                if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] { result["structuredContent"] = object }
            } catch {
                result = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
            }
        default: return rpcError(id, -32601, "Method not found")
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
