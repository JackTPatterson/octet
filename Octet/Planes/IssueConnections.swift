import Foundation
import Security

/// Linear and Jira credentials, kept in the Keychain (one entry per
/// connection, as a small JSON blob) and never in preferences or logs.
///
/// The first entry ever saved sits at account "Linear" / "Jira" (the old
/// single-entry layout) and is read as the connection with id "default";
/// more connections are saved at account "Linear:<uuid>" / "Jira:<uuid>".
enum IssueCredentialStore {
    private static let service = "Octet issue tracker"

    private static func account(_ tracker: IssueTracker, _ id: String) -> String {
        id == TrackerConnection.legacyId ? tracker.rawValue : "\(tracker.rawValue):\(id)"
    }

    /// The pre-multi-account entry, if there is one.
    static func load(_ tracker: IssueTracker) -> TrackerCredentials? {
        connections(tracker).first { $0.id == TrackerConnection.legacyId }?.credentials
    }

    /// Every saved connection for a tracker, the old single entry first.
    static func connections(_ tracker: IssueTracker) -> [TrackerConnection] {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return ServiceSample.connections(tracker) }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let rows = items as? [[String: Any]] else { return [] }
        let found: [(connection: TrackerConnection, created: Date)] = rows.compactMap { row in
            guard let name = row[kSecAttrAccount as String] as? String, let data = row[kSecValueData as String] as? Data,
                  let credentials = try? JSONDecoder().decode(TrackerCredentials.self, from: data) else { return nil }
            let id: String
            if name == tracker.rawValue { id = TrackerConnection.legacyId }
            else if name.hasPrefix(tracker.rawValue + ":") { id = String(name.dropFirst(tracker.rawValue.count + 1)) }
            else { return nil }
            return (TrackerConnection(id: id, tracker: tracker, credentials: credentials),
                    row[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
        return found.sorted { ($0.connection.id == TrackerConnection.legacyId ? 0 : 1, $0.created) < ($1.connection.id == TrackerConnection.legacyId ? 0 : 1, $1.created) }
            .map(\.connection)
    }

    /// Saves credentials as a new connection, or over the one for the same
    /// workspace or site/account if there is one.
    @discardableResult
    static func add(_ credentials: TrackerCredentials, for tracker: IssueTracker) throws -> TrackerConnection {
        let existing = connections(tracker)
        let same = existing.first {
            tracker == .linear ? $0.credentials.token == credentials.token
                               : JiraAPI.siteURL($0.credentials) == JiraAPI.siteURL(credentials) && $0.credentials.email == credentials.email && $0.credentials.server == credentials.server
        }
        let connection = TrackerConnection(id: same?.id ?? UUID().uuidString, tracker: tracker, credentials: credentials)
        try update(connection)
        return connection
    }

    static func update(_ connection: TrackerConnection) throws {
        let name = account(connection.tracker, connection.id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let data = try JSONEncoder().encode(connection.credentials)
        let attributes: [String: Any] = [
            kSecAttrLabel as String: "Octet \(connection.tracker.rawValue) connection",
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw IssueTrackerError.unreadable("Couldn't save the connection in Keychain (\(status)).")
        }
    }

    static func remove(_ connection: TrackerConnection) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(connection.tracker, connection.id),
        ] as CFDictionary)
    }
}

/// Talks to Linear and Jira over their own APIs; no web view, no cookies.
enum IssueConnection {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest?) async throws -> Data {
        guard let request else { throw IssueTrackerError.badSite }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IssueTrackerError.unreadable("No response.") }
        switch http.statusCode {
        case 200..<300: return data
        // A refused write is a permissions answer, not bad credentials.
        case 401: throw IssueTrackerError.unauthorized
        case 403 where request.httpMethod == "GET": throw IssueTrackerError.unauthorized
        default:
            throw IssueTrackerError.http(http.statusCode, detail(data))
        }
    }

    /// Jira's `errorMessages` / `errors` when it sends them, else the start of the body.
    private static func detail(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let messages = (root["errorMessages"] as? [String] ?? []) + ((root["errors"] as? [String: String])?.values.map { $0 } ?? [])
            if !messages.isEmpty { return messages.joined(separator: " ") }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    // MARK: Linear

    private static func linear(_ credentials: TrackerCredentials, _ query: String, _ variables: [String: Any] = [:]) async throws -> Data {
        try await send(LinearAPI.request(query: query, variables: variables, token: credentials.token))
    }

    /// Checks the key and returns what it can see: the teams, who it is and the workspace's name.
    static func linearTeams(token: String) async throws -> (viewer: String, viewerId: String, workspace: String, teams: [TrackerContainer]) {
        try LinearAPI.parseTeams(await send(LinearAPI.request(query: LinearAPI.teamsQuery, token: token)))
    }

    static func linearIssues(_ credentials: TrackerCredentials, team: String, filter: IssueFilter) async throws -> [TrackerIssue] {
        try LinearAPI.parseIssues(await linear(credentials, LinearAPI.issuesQuery(), LinearAPI.issuesVariables(team: team, filter: filter)))
    }

    static func linearIssue(_ credentials: TrackerCredentials, key: String) async throws -> TrackerIssue {
        try LinearAPI.parseIssue(await linear(credentials, LinearAPI.issueQuery(), ["id": key]))
    }

    static func linearComments(_ credentials: TrackerCredentials, issue: String) async throws -> [TrackerComment] {
        var result: [TrackerComment] = [], after: String? = nil
        for _ in 0..<200 {
            var variables: [String: Any] = ["id": issue]
            if let after { variables["after"] = after }
            let data = try await linear(credentials, LinearAPI.commentsQuery, variables)
            result += try LinearAPI.parseComments(data)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let payload = (root?["data"] as? [String: Any])?["issue"] as? [String: Any]
            let info = (payload?["comments"] as? [String: Any])?["pageInfo"] as? [String: Any]
            guard info?["hasNextPage"] as? Bool == true else { return result }
            guard let next = info?["endCursor"] as? String, next != after else { throw IssueTrackerError.unreadable("Invalid comments continuation.") }
            after = next
        }
        throw IssueTrackerError.unreadable("Comments exceeded 10,000 entries; result is incomplete.")
    }

    static func linearStates(_ credentials: TrackerCredentials, issue: String) async throws -> [TrackerStatus] {
        try LinearAPI.parseStates(await linear(credentials, LinearAPI.statesQuery, ["id": issue]))
    }

    static func linearComment(_ credentials: TrackerCredentials, issue: String, body: String) async throws -> TrackerComment {
        try LinearAPI.parseCreatedComment(await linear(credentials, LinearAPI.commentMutation, ["id": issue, "body": body]))
    }

    static func linearSetState(_ credentials: TrackerCredentials, issue: String, stateId: String) async throws {
        try LinearAPI.checkUpdate(await linear(credentials, LinearAPI.updateMutation, LinearAPI.stateVariables(issue: issue, stateId: stateId)))
    }

    static func linearAssign(_ credentials: TrackerCredentials, issue: String, userId: String) async throws {
        try LinearAPI.checkUpdate(await linear(credentials, LinearAPI.updateMutation, LinearAPI.assignVariables(issue: issue, userId: userId)))
    }

    // MARK: Jira

    /// Checks the site and credentials and returns them completed (the gateway
    /// a scoped token needs, the site as the connection's name) with the
    /// projects they can see. Cloud tries the site first, then Atlassian's
    /// gateway for the cloud ID the site names.
    static func jiraConnect(_ credentials: TrackerCredentials) async throws -> (credentials: TrackerCredentials, projects: [TrackerContainer]) {
        var trial = credentials
        guard let site = JiraAPI.siteURL(trial) else { throw IssueTrackerError.badSite }
        trial.name = site.host ?? "Jira"
        do {
            _ = try await send(JiraAPI.myselfRequest(trial))
        } catch IssueTrackerError.unauthorized where !trial.server {
            guard let tenant = JiraAPI.tenantInfoURL(site: site) else { throw IssueTrackerError.badSite }
            var info = URLRequest(url: tenant)
            info.setValue(JiraAPI.userAgent, forHTTPHeaderField: "User-Agent")
            guard let cloudId = JiraAPI.parseCloudId(try await send(info)), let gateway = JiraAPI.gatewayURL(cloudId: cloudId) else {
                throw IssueTrackerError.unauthorized
            }
            trial.gateway = gateway.absoluteString
            _ = try await send(JiraAPI.myselfRequest(trial))
        }
        return (trial, try await jiraProjects(trial))
    }

    static func jiraProjects(_ credentials: TrackerCredentials) async throws -> [TrackerContainer] {
        if credentials.server {
            return try JiraAPI.parseProjectList(await send(JiraAPI.request(credentials, "project")))
        }
        return try JiraAPI.parseProjects(await send(JiraAPI.request(credentials, "project/search", query: [URLQueryItem(name: "maxResults", value: "100")])))
    }

    static func jiraSavedFilters(_ credentials: TrackerCredentials) async throws -> [TrackerContainer] {
        let data = try await send(JiraAPI.request(credentials, "filter/favourite"))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw IssueTrackerError.unreadable("Invalid saved filters response.")
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let id = (row["id"] as? String) ?? (row["id"] as? NSNumber)?.stringValue
            return id.map { TrackerContainer(id: $0, name: name) }
        }
    }

    static func jiraMyself(_ credentials: TrackerCredentials) async throws -> (id: String, name: String) {
        try JiraAPI.parseMyself(await send(JiraAPI.myselfRequest(credentials)))
    }

    static func jiraIssues(_ credentials: TrackerCredentials, project: String, filter: IssueFilter) async throws -> [TrackerIssue] {
        guard let site = JiraAPI.siteURL(credentials) else { throw IssueTrackerError.badSite }
        var jql = JiraAPI.jql(project: project, scope: filter.scope, who: filter.who, statuses: filter.statuses)
        if let saved = filter.savedFilter, !saved.isEmpty, saved.allSatisfy(\.isNumber) {
            jql = "filter = " + saved + " AND " + jql
        }
        return try JiraAPI.parseIssues(await send(JiraAPI.searchRequest(credentials, jql: jql)), site: site)
    }

    static func jiraIssue(_ credentials: TrackerCredentials, key: String) async throws -> TrackerIssue {
        guard let site = JiraAPI.siteURL(credentials) else { throw IssueTrackerError.badSite }
        return try JiraAPI.parseIssue(await send(JiraAPI.issueRequest(credentials, key: key)), site: site)
    }

    static func jiraComments(_ credentials: TrackerCredentials, key: String) async throws -> [TrackerComment] {
        var result: [TrackerComment] = [], offset = 0
        for _ in 0..<200 {
            guard var request = JiraAPI.commentsRequest(credentials, key: key), let url = request.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw IssueTrackerError.badSite }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "startAt", value: String(offset))]
            request.url = components.url
            let data = try await send(request)
            let rows = try JiraAPI.parseComments(data)
            result += rows
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            offset += rows.count
            if offset >= (root?["total"] as? Int ?? offset) { return result }
            guard !rows.isEmpty else { throw IssueTrackerError.unreadable("Comments pagination stopped before completion.") }
        }
        throw IssueTrackerError.unreadable("Comments exceeded 10,000 entries; result is incomplete.")
    }

    static func jiraTransitions(_ credentials: TrackerCredentials, key: String) async throws -> [TrackerStatus] {
        try JiraAPI.parseTransitions(await send(JiraAPI.transitionsRequest(credentials, key: key)))
    }

    static func jiraTransition(_ credentials: TrackerCredentials, key: String, transitionId: String) async throws {
        _ = try await send(JiraAPI.transitionRequest(credentials, key: key, transitionId: transitionId))
    }

    static func jiraComment(_ credentials: TrackerCredentials, key: String, text: String) async throws {
        _ = try await send(JiraAPI.addCommentRequest(credentials, key: key, text: text))
    }

    static func jiraAssign(_ credentials: TrackerCredentials, key: String, userId: String) async throws {
        _ = try await send(JiraAPI.assignRequest(credentials, key: key, userId: userId))
    }
}

/// What the Issues pane, and anything else that wants issues (a CLI or MCP
/// bridge, "start a workspace from this issue"), calls. No views in here:
/// it picks the saved connection, runs gh or the tracker's API and hands back
/// `TrackerIssue`s. `directory` is the project folder gh runs in (GitHub only);
/// `connectionId` nil means the tracker's first saved connection.
enum IssueService {
    private static let cacheLock = NSLock()
    private static var viewers: [String: String] = [:]

    static func connections(_ tracker: IssueTracker) -> [TrackerConnection] { IssueCredentialStore.connections(tracker) }

    static func connection(_ tracker: IssueTracker, _ id: String?) throws -> TrackerConnection {
        guard let found = connections(tracker).first(where: { id == nil || $0.id == id }) else {
            throw IssueTrackerError.notConnected(tracker.rawValue)
        }
        return found
    }

    private static func gh(_ arguments: [String], directory: String?, input: String? = nil) async throws -> String {
        guard let directory else { throw IssueTrackerError.unreadable("Open a project first.") }
        let result = await Task.detached(priority: .userInitiated) {
            LoginShell.run(arguments, in: directory, input: input.map { Data($0.utf8) })
        }.value
        guard result.status == 0 else { throw IssueTrackerError.githubCLI(result.output) }
        return result.output
    }

    private static func number(_ issue: TrackerIssue) throws -> String {
        guard let number = GitHubIssueCLI.number(issue.key) else { throw IssueTrackerError.unreadable("\(issue.key) isn't a GitHub issue number.") }
        return number
    }

    // MARK: Reading

    /// The teams (Linear) or projects (Jira) a connection can see.
    static func containers(_ tracker: IssueTracker, connectionId: String? = nil) async throws -> [TrackerContainer] {
        switch tracker {
        case .github: return []
        case .linear:
            let connection = try connection(tracker, connectionId)
            #if DEBUG && !OCTET_CLI
            if ServiceSample.shows("tickets") { return ServiceSample.containers(tracker) }
            #endif
            let found = try await IssueConnection.linearTeams(token: connection.credentials.token)
            remember(found.viewerId, for: connection)
            // A connection saved before names existed learns its workspace's.
            if connection.credentials.name.isEmpty, !found.workspace.isEmpty {
                var named = connection
                named.credentials.name = found.workspace
                try IssueCredentialStore.update(named)
            }
            return found.teams
        case .jira:
            let connection = try connection(tracker, connectionId)
            #if DEBUG && !OCTET_CLI
            if ServiceSample.shows("tickets") { return ServiceSample.containers(tracker) }
            #endif
            return try await IssueConnection.jiraProjects(connection.credentials)
        }
    }

    static func list(tracker: IssueTracker, connectionId: String? = nil, container: String? = nil,
                     filter: IssueFilter = IssueFilter(), directory: String? = nil) async throws -> [TrackerIssue] {
        let page = try await listPages(tracker: tracker, connectionId: connectionId, container: container, filter: filter, directory: directory)
        guard !page.truncated else { throw IssueTrackerError.unreadable("Issue list is incomplete. Narrow the filters, or continue with octet-cli --cursor.") }
        return page.issues
    }

    /// One issue by key ("#142", "ENG-12", "PROJ-7").
    static func issue(tracker: IssueTracker, key: String, connectionId: String? = nil, directory: String? = nil) async throws -> TrackerIssue {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") {
            guard let found = try ServiceSample.trackerIssues(tracker, filter: IssueFilter(scope: "all")).first(where: { $0.key == key }) else {
                throw IssueTrackerError.unreadable("That issue wasn't found.")
            }
            return found
        }
        #endif
        switch tracker {
        case .github:
            guard let number = GitHubIssueCLI.number(key) else { throw IssueTrackerError.unreadable("\(key) isn't a GitHub issue number.") }
            return try GitHubIssueCLI.parseIssue(Data(try await gh(GitHubIssueCLI.viewArguments(number: number), directory: directory).utf8))
        case .linear: return try await IssueConnection.linearIssue(try connection(tracker, connectionId).credentials, key: key)
        case .jira: return try await IssueConnection.jiraIssue(try connection(tracker, connectionId).credentials, key: key)
        }
    }

    static func comments(tracker: IssueTracker, issue: TrackerIssue, connectionId: String? = nil, directory: String? = nil) async throws -> [TrackerComment] {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return ServiceSample.comments(issue) }
        #endif
        switch tracker {
        case .github:
            return try GitHubIssueCLI.parseComments(Data(try await gh(GitHubIssueCLI.commentsArguments(number: number(issue)), directory: directory).utf8))
        case .linear: return try await IssueConnection.linearComments(try connection(tracker, connectionId).credentials, issue: issue.id)
        case .jira: return try await IssueConnection.jiraComments(try connection(tracker, connectionId).credentials, key: issue.key)
        }
    }

    // MARK: Writing

    /// The states an issue can move to: its team's workflow states (Linear),
    /// the transitions open on it (Jira) or open/closed (GitHub).
    static func statuses(tracker: IssueTracker, issue: TrackerIssue, connectionId: String? = nil) async throws -> [TrackerStatus] {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return ServiceSample.statuses(tracker) }
        #endif
        switch tracker {
        case .github: return GitHubIssueCLI.statuses
        case .linear: return try await IssueConnection.linearStates(try connection(tracker, connectionId).credentials, issue: issue.id)
        case .jira: return try await IssueConnection.jiraTransitions(try connection(tracker, connectionId).credentials, key: issue.key)
        }
    }

    static func setStatus(tracker: IssueTracker, issue: TrackerIssue, to status: TrackerStatus,
                          connectionId: String? = nil, directory: String? = nil) async throws {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { try ServiceSample.write(status: status); return }
        #endif
        switch tracker {
        case .github:
            let args = status.closed ? GitHubIssueCLI.closeArguments(number: try number(issue)) : GitHubIssueCLI.reopenArguments(number: try number(issue))
            _ = try await gh(args, directory: directory)
        case .linear: try await IssueConnection.linearSetState(try connection(tracker, connectionId).credentials, issue: issue.id, stateId: status.id)
        case .jira: try await IssueConnection.jiraTransition(try connection(tracker, connectionId).credentials, key: issue.key, transitionId: status.id)
        }
    }

    /// Posts a comment; returns it as the tracker has it, where the tracker says (Linear), else nil.
    @discardableResult
    static func addComment(tracker: IssueTracker, issue: TrackerIssue, body: String,
                           connectionId: String? = nil, directory: String? = nil) async throws -> TrackerComment? {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { try ServiceSample.write(comment: body); return nil }
        #endif
        switch tracker {
        case .github:
            _ = try await gh(GitHubIssueCLI.commentArguments(number: number(issue)), directory: directory, input: body)
            return nil
        case .linear: return try await IssueConnection.linearComment(try connection(tracker, connectionId).credentials, issue: issue.id, body: body)
        case .jira:
            try await IssueConnection.jiraComment(try connection(tracker, connectionId).credentials, key: issue.key, text: body)
            return nil
        }
    }

    /// The signed-in person's id in the tracker's terms (login, Linear user id,
    /// Jira account id), to tell which issues are theirs. Cached per connection.
    static func viewerId(tracker: IssueTracker, connectionId: String? = nil, directory: String? = nil) async -> String? {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return ServiceSample.viewerId }
        #endif
        let cacheKey: String
        if tracker == .github { cacheKey = "github:\(directory ?? "")" }
        else if let connection = try? connection(tracker, connectionId) { cacheKey = "\(tracker.rawValue):\(connection.id)" }
        else { return nil }
        cacheLock.lock(); let cached = viewers[cacheKey]; cacheLock.unlock()
        if let cached { return cached }
        let found: String?
        switch tracker {
        case .github: found = try? await gh(GitHubIssueCLI.viewerArguments, directory: directory)
        case .linear:
            guard let connection = try? connection(tracker, connectionId) else { return nil }
            found = try? await IssueConnection.linearTeams(token: connection.credentials.token).viewerId
        case .jira:
            guard let connection = try? connection(tracker, connectionId) else { return nil }
            found = try? await IssueConnection.jiraMyself(connection.credentials).id
        }
        guard let found, !found.isEmpty else { return nil }
        cacheLock.lock(); viewers[cacheKey] = found; cacheLock.unlock()
        return found
    }

    private static func remember(_ id: String, for connection: TrackerConnection) {
        guard !id.isEmpty else { return }
        cacheLock.lock(); viewers["\(connection.tracker.rawValue):\(connection.id)"] = id; cacheLock.unlock()
    }

    static func assignToMe(tracker: IssueTracker, issue: TrackerIssue, connectionId: String? = nil, directory: String? = nil) async throws {
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return }
        #endif
        switch tracker {
        case .github: _ = try await gh(GitHubIssueCLI.assignArguments(number: try number(issue)), directory: directory)
        case .linear:
            guard let me = await viewerId(tracker: tracker, connectionId: connectionId) else { throw IssueTrackerError.unauthorized }
            try await IssueConnection.linearAssign(try connection(tracker, connectionId).credentials, issue: issue.id, userId: me)
        case .jira:
            guard let me = await viewerId(tracker: tracker, connectionId: connectionId) else { throw IssueTrackerError.unauthorized }
            try await IssueConnection.jiraAssign(try connection(tracker, connectionId).credentials, key: issue.key, userId: me)
        }
    }
}

extension IssueService {
    /// CLI gets honest continuation metadata; UI requires a complete result.
    static func listPages(tracker: IssueTracker, connectionId: String? = nil, container: String? = nil,
                          filter: IssueFilter = IssueFilter(), directory: String? = nil,
                          cursor: String? = nil, limit: Int? = nil,
                          connectionOverride: TrackerConnection? = nil,
                          transport: (URLRequest?) async throws -> Data = IssueConnection.send) async throws -> IssueListPage {
        guard limit == nil || (1...1000).contains(limit!) else { throw IssueTrackerError.unreadable("Limit must be 1–1000.") }
        #if DEBUG && !OCTET_CLI
        if ServiceSample.shows("tickets") { return IssueListPage(issues: try ServiceSample.trackerIssues(tracker, filter: filter)) }
        #endif
        let resolved = tracker == .github ? nil : try (connectionOverride ?? connection(tracker, connectionId))
        let scope = [tracker.rawValue, resolved?.id ?? "", container ?? "", filter.scope, filter.who.rawValue,
                     filter.statuses.sorted().joined(separator: ","), filter.savedFilter ?? "", directory ?? ""]
        var position = try IssueListCursor.position(cursor, scope: scope)
        var result: [TrackerIssue] = []
        let deadline = Date().addingTimeInterval(20)
        for _ in 0..<100 {
            let count = min(100, (limit ?? 10_000) - result.count)
            var rows: [TrackerIssue], next: String?
            switch tracker {
            case .linear:
                guard let container, let resolved else { throw IssueTrackerError.unreadable("Choose a team.") }
                var variables = LinearAPI.issuesVariables(team: container, filter: filter)
                variables["first"] = count
                if let position { variables["after"] = position }
                let data = try await transport(LinearAPI.request(query: LinearAPI.issuesQuery(), variables: variables, token: resolved.credentials.token))
                rows = try LinearAPI.parseIssues(data)
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let payload = (root?["data"] as? [String: Any])?["issues"] as? [String: Any]
                let info = payload?["pageInfo"] as? [String: Any]
                if info?["hasNextPage"] as? Bool == true {
                    guard let token = info?["endCursor"] as? String, !token.isEmpty else { throw IssueTrackerError.unreadable("Missing Linear continuation.") }
                    next = token
                }
            case .jira:
                guard let container, let resolved, let site = JiraAPI.siteURL(resolved.credentials) else { throw IssueTrackerError.unreadable("Choose a project.") }
                var jql = JiraAPI.jql(project: container, scope: filter.scope, who: filter.who, statuses: filter.statuses)
                if let saved = filter.savedFilter, !saved.isEmpty, saved.allSatisfy(\.isNumber) { jql = "filter = " + saved + " AND " + jql }
                guard var request = JiraAPI.searchRequest(resolved.credentials, jql: jql), let url = request.url,
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw IssueTrackerError.badSite }
                var query = (components.queryItems ?? []).filter { $0.name != "maxResults" }
                query.append(URLQueryItem(name: "maxResults", value: String(count)))
                if let position { query.append(URLQueryItem(name: resolved.credentials.server ? "startAt" : "nextPageToken", value: position)) }
                components.queryItems = query; request.url = components.url
                let data = try await transport(request)
                rows = try JiraAPI.parseIssues(data, site: site)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if resolved.credentials.server {
                    let offset = (Int(position ?? "0") ?? 0) + rows.count
                    if offset < (payload?["total"] as? Int ?? offset) { next = String(offset) }
                } else {
                    next = payload?["nextPageToken"] as? String
                    if payload?["isLast"] as? Bool == false && next == nil { throw IssueTrackerError.unreadable("Missing Jira continuation.") }
                }
            case .github:
                let offset = Int(position ?? "0") ?? 0
                guard offset >= 0, offset <= 100_000 else { throw IssueTrackerError.unreadable("Invalid GitHub offset.") }
                var args = GitHubIssueCLI.listArguments(filter: filter)
                if let index = args.firstIndex(of: "--limit") { args[index + 1] = String(offset + count + 1) }
                let all = try GitHubIssueCLI.parseIssues(Data(try await gh(args, directory: directory).utf8))
                rows = Array(all.dropFirst(offset).prefix(count))
                if all.count > offset + count { next = String(offset + count) }
            }
            result += rows
            guard let next else { return IssueListPage(issues: result) }
            guard next != position, !rows.isEmpty else { throw IssueTrackerError.unreadable("Issue pagination did not advance.") }
            position = next
            if result.count >= (limit ?? 10_000) || Date() >= deadline { break }
        }
        return IssueListPage(issues: result, nextCursor: try position.map { try IssueListCursor(scope: scope, position: $0).encoded() })
    }
}
