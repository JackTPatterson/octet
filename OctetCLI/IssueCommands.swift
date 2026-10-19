import Foundation

/// Read-only agent access, sharing the app's API clients and Keychain entries.
enum IssueCommands {
    static func run(_ args: [String]) async throws -> Data {
        let usage = "usage: octet-cli issues connections|containers|list|read --tracker github|linear|jira [--connection ID] [--container ID] [--scope open|closed|all] [--who anyone|assigned|reported] [--in PATH] [--key KEY | --current] [--cursor CURSOR] [--limit N]"
        let directory = option("--in", in: args) ?? FileManager.default.currentDirectoryPath
        let linked = args.contains("--current") ? try WorkspaceIssueLink.read(in: directory) : nil
        if args.contains("--current"), linked == nil { throw IssueTrackerError.unreadable("This checkout has no linked issue.") }
        guard let action = args.first, ["connections", "containers", "list", "read"].contains(action),
              let name = option("--tracker", in: args) ?? linked?.tracker,
              let tracker = IssueTracker.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            throw IssueTrackerError.unreadable(usage)
        }
        if let linked {
            guard tracker.rawValue == linked.tracker,
                  option("--connection", in: args).map({ $0 == linked.connectionId }) ?? true,
                  option("--key", in: args) == nil else { throw IssueTrackerError.unreadable("--current uses the saved tracker, connection and issue; omit conflicting selectors.") }
        }
        let id = option("--connection", in: args) ?? linked?.connectionId
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch action {
        case "connections":
            // Deliberately never serialize TrackerConnection: it contains credentials.
            return try JSONSerialization.data(withJSONObject: IssueService.connections(tracker).map {
                ["id": $0.id, "name": $0.credentials.name, "tracker": tracker.rawValue]
            }, options: [.prettyPrinted, .sortedKeys])
        case "containers":
            let rows = try await IssueService.containers(tracker, connectionId: id)
            return try JSONSerialization.data(withJSONObject: rows.map { ["id": $0.id, "name": $0.name] }, options: [.prettyPrinted, .sortedKeys])
        case "read":
            guard let key = option("--key", in: args) ?? linked?.key, !key.isEmpty else { throw IssueTrackerError.unreadable(usage) }
            let issue = try await IssueService.issue(tracker: tracker, key: key, connectionId: id, directory: directory)
            if args.contains("--include-comments") {
                struct Read: Encodable { let issue: TrackerIssue; let comments: [TrackerComment] }
                return try encoder.encode(Read(issue: issue, comments: try await IssueService.comments(tracker: tracker, issue: issue, connectionId: id, directory: directory)))
            }
            return try encoder.encode(issue)
        default:
            let scope = option("--scope", in: args) ?? "open"
            guard ["open", "closed", "all"].contains(scope),
                  let who = IssueWho(rawValue: option("--who", in: args) ?? "anyone") else { throw IssueTrackerError.unreadable(usage) }
            let rawLimit = option("--limit", in: args)
            if let rawLimit, Int(rawLimit) == nil { throw IssueTrackerError.unreadable("Limit must be a number.") }
            return try encoder.encode(await IssueService.listPages(tracker: tracker, connectionId: id,
                container: option("--container", in: args), filter: IssueFilter(scope: scope, who: who), directory: directory, cursor: option("--cursor", in: args), limit: rawLimit.flatMap(Int.init)))
        }
    }
}
