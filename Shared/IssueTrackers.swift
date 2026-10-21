import Foundation

/// One issue from any tracker, as the Issues pane draws it.
struct TrackerIssue: Identifiable, Equatable, Codable {
    struct Label: Equatable, Codable { let name: String; let color: String? }
    struct SubIssue: Equatable, Codable { let key, title, stateName: String; let closed: Bool }
    let id: String
    /// What people say aloud: "#142", "ENG-12", "PROJ-7".
    let key: String
    let title, body: String
    /// Vars so a write can show its result before the tracker answers.
    var stateName: String
    var closed: Bool
    let url: URL?
    var person: String?
    let labels: [Label]
    /// ISO 8601, so the list can say how long ago.
    let updatedAt: String
    var comments: Int
    // Added later; defaults keep older call sites compiling.
    var assignee: String? = nil
    /// The tracker's id for the assignee (login, Linear user id, Jira account id), to compare with the viewer's.
    var assigneeId: String? = nil
    /// "Urgent", "High", "Medium"…; nil when the tracker has none set.
    var priority: String? = nil
    /// 1 (most urgent) to 4, 0 when unset; drives the tag's tone.
    var priorityRank = 0
    /// Jira's issue type ("Bug", "Story").
    var issueType: String? = nil
    var teamId: String? = nil
    var subIssues: [SubIssue] = []

    /// The start of the description, whitespace collapsed.
    var preview: String {
        let text = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return "No description provided." }
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}

/// A comment on an issue, any tracker.
struct TrackerComment: Identifiable, Equatable, Codable {
    let id, author, body: String
    /// ISO 8601.
    let createdAt: String
}

/// A state an issue can move to: a Linear workflow state, a Jira transition
/// (its id is the transition's), or GitHub's open/closed.
struct TrackerStatus: Identifiable, Equatable, Codable {
    let id, name: String
    let closed: Bool
    var actionName: String? = nil
    var menuTitle: String { actionName.map { "\(name) — \($0) (\(id))" } ?? name }
}

/// Whose issues: the "who" dimension beside open/closed/all.
enum IssueWho: String, CaseIterable {
    case anyone, assigned, reported
    var title: String {
        switch self {
        case .anyone: "Anyone"
        case .assigned: "Assigned to me"
        case .reported: "Reported by me"
        }
    }
}

/// What a list asks for. `scope` is "open", "closed" or "all".
struct IssueFilter: Equatable {
    var scope = "open"
    var who = IssueWho.anyone
    /// Jira status names to keep; empty keeps every status.
    var statuses: [String] = []
    var savedFilter: String? = nil
}

enum IssueTracker: String, CaseIterable {
    case github = "GitHub", linear = "Linear", jira = "Jira"
    /// What the second picker chooses between, for the trackers that have one.
    var containerNoun: String { self == .linear ? "team" : "project" }
}

/// What a tracker lets you filter on, and a person's pick of it.
struct TrackerContainer: Equatable, Identifiable {
    let id, name: String
}

enum IssueTrackerError: LocalizedError, Equatable {
    case unauthorized, badSite, http(Int, String), unreadable(String), notConnected(String), githubCLI(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "The tracker rejected these credentials. Check them and try again."
        case .badSite: "That isn't an https site address (http is never used)."
        case .http(let code, let detail): "The tracker answered \(code). \(detail)".trimmingCharacters(in: .whitespaces)
        case .unreadable(let why): "Couldn't read the tracker's answer. \(why)"
        case .notConnected(let name): "\(name) isn't connected."
        case .githubCLI(let output): "GitHub CLI failed. Check sign-in with gh auth login.\n\n\(output)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Credentials as the Keychain keeps them, one JSON blob per connection.
struct TrackerCredentials: Codable, Equatable {
    var token = ""
    /// Jira only: the site, e.g. "acme.atlassian.net", and the account's email
    /// (a username for self-hosted; empty there means a personal access token).
    var site = ""
    var email = ""
    /// Jira Server / Data Center: REST v2, site path kept, Bearer or Basic.
    var server = false
    /// Jira Cloud scoped tokens: "https://api.atlassian.com/ex/jira/<cloudId>".
    var gateway = ""
    /// What the connection list shows (Linear workspace, Jira site); empty until known.
    var name = ""
}

extension TrackerCredentials {
    /// Blobs written before these fields existed hold only token/site/email.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        server = try c.decodeIfPresent(Bool.self, forKey: .server) ?? false
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
    private enum Keys: String, CodingKey { case token, site, email, server, gateway, name }
}

/// One saved account: a Linear workspace or a Jira site. The first one ever
/// saved lives at the old single-entry Keychain account and has id "default".
struct TrackerConnection: Identifiable, Equatable {
    static let legacyId = "default"
    let id: String
    let tracker: IssueTracker
    var credentials: TrackerCredentials
    var displayName: String {
        if !credentials.name.isEmpty { return credentials.name }
        if tracker == .jira { return JiraAPI.baseURL(credentials.site, keepPath: credentials.server)?.host ?? "Jira" }
        return tracker.rawValue
    }
}

// MARK: - Linear

enum LinearAPI {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    static func request(query: String, variables: [String: Any] = [:], token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A personal API key goes bare; "Bearer" is for OAuth tokens.
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return request
    }

    static let teamsQuery = "query { viewer { id name } organization { name } teams(first: 100) { nodes { id key name } } }"

    private static let issueFields = """
        id identifier title description url updatedAt priority priorityLabel
        team { id }
        state { name type }
        assignee { id name } creator { name }
        labels { nodes { name color } }
        comments { nodes { id } }
        children { nodes { identifier title state { name type } } }
        """

    static func issuesQuery() -> String {
        "query($filter: IssueFilter, $after: String, $first: Int = 100) { issues(first: $first, after: $after, orderBy: updatedAt, filter: $filter) { nodes { \(issueFields) } pageInfo { hasNextPage endCursor } } }"
    }

    /// The `filter` variable: the team, the scope's state types and, for
    /// "mine", the viewer as assignee or creator.
    static func issuesVariables(team: String, filter: IssueFilter) -> [String: Any] {
        var clause: [String: Any] = [
            "team": ["id": ["eq": team]],
            "state": ["type": ["in": stateTypes(scope: filter.scope)]],
        ]
        switch filter.who {
        case .anyone: break
        case .assigned: clause["assignee"] = ["isMe": ["eq": true]]
        case .reported: clause["creator"] = ["isMe": ["eq": true]]
        }
        return ["filter": clause]
    }

    static func issueQuery() -> String { "query($id: String!) { issue(id: $id) { \(issueFields) } }" }

    static let commentsQuery = "query($id: String!, $after: String) { issue(id: $id) { comments(first: 50, after: $after) { nodes { id body createdAt user { name } } pageInfo { hasNextPage endCursor } } } }"
    static let statesQuery = "query($id: String!) { issue(id: $id) { team { states { nodes { id name type position } } } } }"
    static let commentMutation = "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success comment { id body createdAt user { name } } } }"
    static let updateMutation = "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }"

    static func stateVariables(issue id: String, stateId: String) -> [String: Any] { ["id": id, "input": ["stateId": stateId]] }
    static func assignVariables(issue id: String, userId: String) -> [String: Any] { ["id": id, "input": ["assigneeId": userId]] }

    /// Linear's workflow state types, grouped the way the scope picker is.
    static func stateTypes(scope: String) -> [String] {
        switch scope {
        case "closed": ["completed", "canceled"]
        case "all": ["triage", "backlog", "unstarted", "started", "completed", "canceled"]
        default: ["triage", "backlog", "unstarted", "started"]
        }
    }

    private static func data(_ body: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw IssueTrackerError.unreadable("The response wasn't JSON.")
        }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            let message = first["message"] as? String ?? "Unknown error."
            let code = (first["extensions"] as? [String: Any])?["type"] as? String ?? ""
            if code.lowercased().contains("authentication") || message.lowercased().contains("authentication") {
                throw IssueTrackerError.unauthorized
            }
            throw IssueTrackerError.unreadable(message)
        }
        guard let data = root["data"] as? [String: Any] else { throw IssueTrackerError.unreadable("No data.") }
        return data
    }

    static func parseTeams(_ body: Data) throws -> (viewer: String, viewerId: String, workspace: String, teams: [TrackerContainer]) {
        let data = try data(body)
        let viewer = data["viewer"] as? [String: Any]
        let nodes = ((data["teams"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return (viewer?["name"] as? String ?? "", viewer?["id"] as? String ?? "",
                (data["organization"] as? [String: Any])?["name"] as? String ?? "",
                nodes.compactMap { node in
            guard let id = node["id"] as? String else { return nil }
            let name = node["name"] as? String ?? node["key"] as? String ?? id
            return TrackerContainer(id: id, name: name)
        })
    }

    private static func issue(_ node: [String: Any]) -> TrackerIssue? {
        guard let id = node["id"] as? String, let title = node["title"] as? String else { return nil }
        let state = node["state"] as? [String: Any]
        let type = state?["type"] as? String ?? ""
        let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { label -> TrackerIssue.Label? in
            guard let name = label["name"] as? String else { return nil }
            return .init(name: name, color: (label["color"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
        let assignee = node["assignee"] as? [String: Any]
        let rank = node["priority"] as? Int ?? 0
        let subs = ((node["children"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { child -> TrackerIssue.SubIssue? in
            guard let key = child["identifier"] as? String, let title = child["title"] as? String else { return nil }
            let childState = child["state"] as? [String: Any]
            let childType = childState?["type"] as? String
            return .init(key: key, title: title, stateName: childState?["name"] as? String ?? "",
                         closed: childType == "completed" || childType == "canceled")
        }
        return TrackerIssue(
            id: id, key: node["identifier"] as? String ?? id, title: title,
            body: node["description"] as? String ?? "", stateName: state?["name"] as? String ?? "",
            closed: type == "completed" || type == "canceled",
            url: (node["url"] as? String).flatMap(URL.init(string:)),
            person: assignee?["name"] as? String ?? (node["creator"] as? [String: Any])?["name"] as? String,
            labels: labels, updatedAt: node["updatedAt"] as? String ?? "",
            comments: ((node["comments"] as? [String: Any])?["nodes"] as? [Any])?.count ?? 0,
            assignee: assignee?["name"] as? String, assigneeId: assignee?["id"] as? String,
            priority: rank == 0 ? nil : node["priorityLabel"] as? String, priorityRank: rank,
            teamId: (node["team"] as? [String: Any])?["id"] as? String, subIssues: subs)
    }

    static func parseIssues(_ body: Data) throws -> [TrackerIssue] {
        let data = try data(body)
        return ((data["issues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(issue)
    }

    static func parseIssue(_ body: Data) throws -> TrackerIssue {
        guard let node = try data(body)["issue"] as? [String: Any], let parsed = issue(node) else {
            throw IssueTrackerError.unreadable("That issue wasn't found.")
        }
        return parsed
    }

    private static func comment(_ node: [String: Any]) -> TrackerComment? {
        guard let id = node["id"] as? String else { return nil }
        return TrackerComment(id: id, author: (node["user"] as? [String: Any])?["name"] as? String ?? "Unknown",
                              body: node["body"] as? String ?? "", createdAt: node["createdAt"] as? String ?? "")
    }

    static func parseComments(_ body: Data) throws -> [TrackerComment] {
        let issue = try data(body)["issue"] as? [String: Any]
        let nodes = (issue?["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap(comment).sorted { $0.createdAt < $1.createdAt }
    }

    /// The comment `commentCreate` returns, or an error when Linear said no.
    static func parseCreatedComment(_ body: Data) throws -> TrackerComment {
        let created = try data(body)["commentCreate"] as? [String: Any]
        guard created?["success"] as? Bool == true, let node = created?["comment"] as? [String: Any],
              let parsed = comment(node) else { throw IssueTrackerError.unreadable("Linear didn't save the comment.") }
        return parsed
    }

    static func parseStates(_ body: Data) throws -> [TrackerStatus] {
        let team = (try data(body)["issue"] as? [String: Any])?["team"] as? [String: Any]
        let nodes = (team?["states"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.sorted { ($0["position"] as? Double ?? 0) < ($1["position"] as? Double ?? 0) }.compactMap { node in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            let type = node["type"] as? String
            return TrackerStatus(id: id, name: name, closed: type == "completed" || type == "canceled")
        }
    }

    /// Throws unless an `issueUpdate` answered `success: true`.
    static func checkUpdate(_ body: Data) throws {
        let update = try data(body)["issueUpdate"] as? [String: Any]
        guard update?["success"] as? Bool == true else { throw IssueTrackerError.unreadable("Linear didn't apply the change.") }
    }
}

// MARK: - Jira (Cloud, Cloud gateway, Server / Data Center)

enum JiraAPI {
    /// Atlassian rejects writes that carry a browser User-Agent ("XSRF check failed").
    static let userAgent = "Octet"
    static let gatewayPrefix = "https://api.atlassian.com/ex/jira/"

    /// "acme", "acme.atlassian.net" or "https://acme.atlassian.net/" → the site's base URL;
    /// https only, no credentials in the address. `keepPath` is for self-hosted
    /// sites that live under a context path (https://host/jira).
    static func baseURL(_ value: String, keepPath: Bool = false) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + (text.contains(".") || keepPath ? text : text + ".atlassian.net") }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        let path = keepPath ? url.path.split(separator: "/").joined(separator: "/") : ""
        return URL(string: "https://\(host)\(url.port.map { ":\($0)" } ?? "")\(path.isEmpty ? "" : "/" + path)")
    }

    /// The Atlassian gateway for a cloud ID, or nil when it isn't one.
    static func gatewayURL(cloudId: String) -> URL? {
        guard !cloudId.isEmpty, cloudId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return URL(string: gatewayPrefix + cloudId)
    }

    /// A stored gateway address, re-checked before anything is sent to it.
    static func gatewayURL(stored: String) -> URL? {
        stored.hasPrefix(gatewayPrefix) ? gatewayURL(cloudId: String(stored.dropFirst(gatewayPrefix.count))) : nil
    }

    /// Where `https://<site>/_edge/tenant_info` is asked.
    static func tenantInfoURL(site: URL) -> URL? { URL(string: "/_edge/tenant_info", relativeTo: site)?.absoluteURL }

    static func parseCloudId(_ body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["cloudId"] as? String
    }

    static func siteURL(_ credentials: TrackerCredentials) -> URL? { baseURL(credentials.site, keepPath: credentials.server) }

    /// Where REST paths hang: the gateway for scoped tokens, else the site.
    static func apiRoot(_ credentials: TrackerCredentials) -> URL? {
        if !credentials.server, let gateway = gatewayURL(stored: credentials.gateway) { return gateway }
        return siteURL(credentials)
    }

    /// Self-hosted only speaks REST v2.
    static func apiPath(_ credentials: TrackerCredentials) -> String { credentials.server ? "rest/api/2" : "rest/api/3" }

    /// Basic with an email/username; a bare token is a personal access token, sent as Bearer.
    static func authorization(email: String, token: String) -> String {
        email.isEmpty ? "Bearer \(token)" : "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    static func request(path: String, query: [URLQueryItem] = [], site: URL, email: String, token: String,
                        method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        var components = URLComponents(url: site.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization(email: email, token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// A call to `<api root>/rest/api/<2|3>/<path>` for a connection.
    static func request(_ credentials: TrackerCredentials, _ path: String, query: [URLQueryItem] = [],
                        method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let root = apiRoot(credentials) else { return nil }
        return request(path: "\(apiPath(credentials))/\(path)", query: query, site: root,
                       email: credentials.email, token: credentials.token, method: method, body: body)
    }

    static func jql(project: String, scope: String, who: IssueWho = .anyone, statuses: [String] = []) -> String {
        let key = project.replacingOccurrences(of: "\"", with: "")
        var clauses = ["project = \"\(key)\""]
        switch who {
        case .anyone: break
        case .assigned: clauses.append("assignee = currentUser()")
        case .reported: clauses.append("reporter = currentUser()")
        }
        if scope == "closed" { clauses.append("statusCategory = Done") }
        else if scope != "all" { clauses.append("statusCategory != Done") }
        if !statuses.isEmpty {
            let names = statuses.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            clauses.append("status in (\(names.joined(separator: ", ")))")
        }
        return clauses.joined(separator: " AND ") + " ORDER BY updated DESC"
    }

    static let issueFields = "summary,status,assignee,reporter,labels,updated,comment,description,priority,issuetype,subtasks"

    /// Cloud searches at `search/jql`; Server / Data Center at `search`.
    static func searchRequest(_ credentials: TrackerCredentials, jql: String) -> URLRequest? {
        request(credentials, credentials.server ? "search" : "search/jql", query: [
            URLQueryItem(name: "jql", value: jql), URLQueryItem(name: "fields", value: issueFields),
            URLQueryItem(name: "maxResults", value: "100")])
    }

    private static func escaped(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? key
    }

    static func issueRequest(_ c: TrackerCredentials, key: String) -> URLRequest? {
        request(c, "issue/\(escaped(key))", query: [URLQueryItem(name: "fields", value: issueFields)])
    }
    static func commentsRequest(_ c: TrackerCredentials, key: String) -> URLRequest? {
        request(c, "issue/\(escaped(key))/comment", query: [URLQueryItem(name: "maxResults", value: "50")])
    }
    static func addCommentRequest(_ c: TrackerCredentials, key: String, text: String) -> URLRequest? {
        // Cloud (v3) comments are Atlassian Document Format; Server (v2) takes plain text.
        request(c, "issue/\(escaped(key))/comment", method: "POST", body: ["body": c.server ? text : adfDocument(text)])
    }
    static func transitionsRequest(_ c: TrackerCredentials, key: String) -> URLRequest? {
        request(c, "issue/\(escaped(key))/transitions")
    }
    static func transitionRequest(_ c: TrackerCredentials, key: String, transitionId: String) -> URLRequest? {
        request(c, "issue/\(escaped(key))/transitions", method: "POST", body: ["transition": ["id": transitionId]])
    }
    static func assignRequest(_ c: TrackerCredentials, key: String, userId: String) -> URLRequest? {
        request(c, "issue/\(escaped(key))/assignee", method: "PUT", body: c.server ? ["name": userId] : ["accountId": userId])
    }
    static func myselfRequest(_ c: TrackerCredentials) -> URLRequest? { request(c, "myself") }

    /// Plain text as an ADF document, one paragraph per non-empty line.
    static func adfDocument(_ text: String) -> [String: Any] {
        let paragraphs = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { line -> [String: Any] in
                ["type": "paragraph", "content": [["type": "text", "text": line]]]
            }
        return ["type": "doc", "version": 1, "content": paragraphs]
    }

    private static func object(_ body: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw IssueTrackerError.unreadable("The response wasn't JSON.")
        }
        return root
    }

    /// The signed-in person: their account id (Cloud) or username (Server), and a display name.
    static func parseMyself(_ body: Data) throws -> (id: String, name: String) {
        let me = try object(body)
        return (me["accountId"] as? String ?? me["name"] as? String ?? me["key"] as? String ?? "",
                me["displayName"] as? String ?? "")
    }

    static func parseProjects(_ body: Data) throws -> [TrackerContainer] {
        let root = try object(body)
        return ((root["values"] as? [[String: Any]]) ?? []).compactMap { project in
            guard let key = project["key"] as? String else { return nil }
            return TrackerContainer(id: key, name: "\(project["name"] as? String ?? key) (\(key))")
        }
    }

    /// Server's `project` endpoint answers a bare array instead of a page.
    static func parseProjectList(_ body: Data) throws -> [TrackerContainer] {
        guard let list = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return try parseProjects(body) }
        return list.compactMap { project in
            guard let key = project["key"] as? String else { return nil }
            return TrackerContainer(id: key, name: "\(project["name"] as? String ?? key) (\(key))")
        }
    }

    private static func issue(_ issue: [String: Any], site: URL) -> TrackerIssue? {
        guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any],
              let title = fields["summary"] as? String else { return nil }
        let status = fields["status"] as? [String: Any]
        let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String
        let assignee = fields["assignee"] as? [String: Any]
        let person = assignee?["displayName"] as? String ?? (fields["reporter"] as? [String: Any])?["displayName"] as? String
        let labels = (fields["labels"] as? [String] ?? []).map { TrackerIssue.Label(name: $0, color: nil) }
        let priority = (fields["priority"] as? [String: Any])?["name"] as? String
        return TrackerIssue(
            id: issue["id"] as? String ?? key, key: key, title: title,
            body: plainText(fields["description"]), stateName: status?["name"] as? String ?? "",
            closed: category == "done", url: site.appendingPathComponent("browse/\(key)"),
            person: person, labels: labels, updatedAt: iso(fields["updated"] as? String ?? ""),
            comments: (fields["comment"] as? [String: Any])?["total"] as? Int ?? 0,
            assignee: assignee?["displayName"] as? String,
            assigneeId: assignee?["accountId"] as? String ?? assignee?["name"] as? String ?? assignee?["key"] as? String,
            priority: priority, priorityRank: rank(priority: priority),
            issueType: (fields["issuetype"] as? [String: Any])?["name"] as? String,
            subIssues: (fields["subtasks"] as? [[String: Any]] ?? []).compactMap { child in
                guard let key = child["key"] as? String, let f = child["fields"] as? [String: Any], let title = f["summary"] as? String else { return nil }
                let state = f["status"] as? [String: Any]
                return TrackerIssue.SubIssue(key: key, title: title, stateName: state?["name"] as? String ?? "",
                    closed: (state?["statusCategory"] as? [String: Any])?["key"] as? String == "done")
            })
    }

    /// Jira's priority names on Linear's 1–4 scale.
    static func rank(priority: String?) -> Int {
        switch priority?.lowercased() {
        case "highest", "blocker", "critical": 1
        case "high", "major": 2
        case "medium": 3
        case "low", "lowest", "minor", "trivial": 4
        default: 0
        }
    }

    static func parseIssues(_ body: Data, site: URL) throws -> [TrackerIssue] {
        ((try object(body)["issues"] as? [[String: Any]]) ?? []).compactMap { issue($0, site: site) }
    }

    static func parseIssue(_ body: Data, site: URL) throws -> TrackerIssue {
        guard let parsed = issue(try object(body), site: site) else { throw IssueTrackerError.unreadable("That issue wasn't found.") }
        return parsed
    }

    static func parseComments(_ body: Data) throws -> [TrackerComment] {
        ((try object(body)["comments"] as? [[String: Any]]) ?? []).compactMap { comment in
            guard let id = comment["id"] as? String else { return nil }
            return TrackerComment(id: id, author: (comment["author"] as? [String: Any])?["displayName"] as? String ?? "Unknown",
                                  body: plainText(comment["body"]), createdAt: iso(comment["created"] as? String ?? ""))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Each transition, named for the status it leads to.
    static func parseTransitions(_ body: Data) throws -> [TrackerStatus] {
        ((try object(body)["transitions"] as? [[String: Any]]) ?? []).compactMap { transition in
            guard let id = transition["id"] as? String else { return nil }
            let to = transition["to"] as? [String: Any]
            let category = (to?["statusCategory"] as? [String: Any])?["key"] as? String
            return TrackerStatus(id: id, name: to?["name"] as? String ?? transition["name"] as? String ?? id, closed: category == "done", actionName: transition["name"] as? String)
        }
    }

    /// Jira writes "2026-10-19T09:00:00.000+0000"; the list reads ISO 8601.
    static func iso(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return ISO8601DateFormatter().string(from: date) }
        }
        return value
    }

    /// Jira's descriptions are Atlassian Document Format (a JSON tree); this
    /// keeps the words, one block per line.
    static func plainText(_ node: Any?) -> String {
        if let text = node as? String { return text }
        guard let node = node as? [String: Any] else { return "" }
        if let text = node["text"] as? String { return text }
        let children = (node["content"] as? [Any] ?? []).map { plainText($0) }
        let type = node["type"] as? String ?? ""
        if type == "hardBreak" { return "\n" }
        // Blocks stack, one per line; inline runs (text, marks, mentions) run together.
        let blocks: Set<String> = ["doc", "bulletList", "orderedList", "blockquote", "codeBlock", "listItem"]
        if blocks.contains(type) { return children.filter { !$0.isEmpty }.joined(separator: "\n") }
        return children.joined()
    }
}

// MARK: - GitHub (through gh)

/// `gh issue …` argument lists and their JSON, so the shell call itself stays thin.
enum GitHubIssueCLI {
    static let fields = "number,title,body,state,url,author,assignees,labels,updatedAt,comments"

    static func listArguments(filter: IssueFilter) -> [String] {
        var arguments = ["gh", "issue", "list", "--state", filter.scope, "--limit", "100", "--json", fields]
        switch filter.who {
        case .anyone: break
        case .assigned: arguments += ["--assignee", "@me"]
        case .reported: arguments += ["--author", "@me"]
        }
        return arguments
    }

    /// "#142" or "142" → "142"; nil for anything else, so a key never reaches argv as an option.
    static func number(_ key: String) -> String? {
        let digits = key.hasPrefix("#") ? String(key.dropFirst()) : key
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    static func viewArguments(number: String) -> [String] { ["gh", "issue", "view", number, "--json", fields] }
    static func commentsArguments(number: String) -> [String] { ["gh", "issue", "view", number, "--json", "comments"] }
    /// The body goes to stdin, never into argv.
    static func commentArguments(number: String) -> [String] { ["gh", "issue", "comment", number, "--body-file", "-"] }
    static func closeArguments(number: String) -> [String] { ["gh", "issue", "close", number] }
    static func reopenArguments(number: String) -> [String] { ["gh", "issue", "reopen", number] }
    static func assignArguments(number: String) -> [String] { ["gh", "issue", "edit", number, "--add-assignee", "@me"] }
    static let viewerArguments = ["gh", "api", "user", "--jq", ".login"]

    /// GitHub has just the two states.
    static let statuses = [TrackerStatus(id: "open", name: "Open", closed: false), TrackerStatus(id: "closed", name: "Closed", closed: true)]

    static func parseIssues(_ body: Data) throws -> [TrackerIssue] {
        do { return try JSONDecoder().decode([ProjectIssue].self, from: body).map(\.tracker) }
        catch { throw IssueTrackerError.unreadable("GitHub's answer wasn't an issue list.") }
    }

    static func parseIssue(_ body: Data) throws -> TrackerIssue {
        do { return try JSONDecoder().decode(ProjectIssue.self, from: body).tracker }
        catch { throw IssueTrackerError.unreadable("GitHub's answer wasn't an issue.") }
    }

    static func parseComments(_ body: Data) throws -> [TrackerComment] {
        struct Page: Decodable {
            struct Comment: Decodable {
                struct Author: Decodable { let login: String }
                let id: String?
                let author: Author?
                let body, createdAt: String
            }
            let comments: [Comment]
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: body) else {
            throw IssueTrackerError.unreadable("GitHub's answer wasn't a comment list.")
        }
        return page.comments.enumerated().map {
            TrackerComment(id: $0.element.id ?? "\($0.offset)", author: $0.element.author?.login ?? "ghost",
                           body: $0.element.body, createdAt: $0.element.createdAt)
        }
    }
}

/// `gh issue list --json` rows.
struct ProjectIssue: Decodable, Identifiable {
    var id: Int { number }
    let number: Int
    let title, body, state, url: String
    let author: Author?
    var assignees: [Author] = []
    let labels: [Label]
    let updatedAt: String
    let comments: [Comment]
    struct Author: Decodable { let login: String }
    struct Label: Decodable { let name: String; let color: String? }
    struct Comment: Decodable {}

    private enum Keys: String, CodingKey { case number, title, body, state, url, author, assignees, labels, updatedAt, comments }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try c.decode(String.self, forKey: .state)
        url = try c.decode(String.self, forKey: .url)
        author = try c.decodeIfPresent(Author.self, forKey: .author)
        assignees = try c.decodeIfPresent([Author].self, forKey: .assignees) ?? []
        labels = try c.decodeIfPresent([Label].self, forKey: .labels) ?? []
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }

    var tracker: TrackerIssue {
        TrackerIssue(id: String(number), key: "#\(number)", title: title, body: body, stateName: state.capitalized,
                     closed: state.uppercased() == "CLOSED", url: URL(string: url), person: author?.login,
                     labels: labels.map { .init(name: $0.name, color: $0.color) }, updatedAt: updatedAt, comments: comments.count,
                     assignee: assignees.first?.login, assigneeId: assignees.first?.login)
    }
}
