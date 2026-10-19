import XCTest

/// Filters, writes, comments, connections and self-hosted Jira: request
/// building and parsing against canned JSON. Nothing here touches a network.
final class IssueTrackerWritesTests: XCTestCase {
    private func json(_ data: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]) ?? [:]
    }

    // MARK: Filters

    func testGitHubWhoFlags() {
        XCTAssertFalse(GitHubIssueCLI.listArguments(filter: IssueFilter()).contains("--assignee"))
        XCTAssertEqual(Array(GitHubIssueCLI.listArguments(filter: IssueFilter(scope: "closed", who: .assigned)).suffix(2)), ["--assignee", "@me"])
        let reported = GitHubIssueCLI.listArguments(filter: IssueFilter(who: .reported))
        XCTAssertEqual(Array(reported.suffix(2)), ["--author", "@me"])
        XCTAssertTrue(reported.contains("open"))
    }

    func testLinearFilterVariables() throws {
        let anyone = LinearAPI.issuesVariables(team: "t1", filter: IssueFilter())["filter"] as? [String: Any]
        XCTAssertNil(anyone?["assignee"]); XCTAssertNil(anyone?["creator"])
        let mine = LinearAPI.issuesVariables(team: "t1", filter: IssueFilter(scope: "all", who: .assigned))["filter"] as? [String: Any]
        XCTAssertEqual(((mine?["assignee"] as? [String: Any])?["isMe"] as? [String: Bool])?["eq"], true)
        let reported = LinearAPI.issuesVariables(team: "t1", filter: IssueFilter(who: .reported))["filter"] as? [String: Any]
        XCTAssertEqual(((reported?["creator"] as? [String: Any])?["isMe"] as? [String: Bool])?["eq"], true)
        XCTAssertNil(reported?["assignee"])
        XCTAssertEqual((((reported?["team"] as? [String: Any])?["id"]) as? [String: String])?["eq"], "t1")
    }

    func testJiraJQLWhoAndStatuses() {
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "open", who: .assigned),
                       #"project = "ENG" AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"#)
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "all", who: .reported),
                       #"project = "ENG" AND reporter = currentUser() ORDER BY updated DESC"#)
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "all", statuses: [#"In "Review""#, "Done"]),
                       #"project = "ENG" AND status in ("In \"Review\"", "Done") ORDER BY updated DESC"#)
    }

    // MARK: Linear writes and detail

    func testLinearMutationsAndVariables() {
        let state = LinearAPI.stateVariables(issue: "i1", stateId: "s9")
        XCTAssertEqual(state["id"] as? String, "i1")
        XCTAssertEqual((state["input"] as? [String: String])?["stateId"], "s9")
        XCTAssertEqual((LinearAPI.assignVariables(issue: "i1", userId: "u1")["input"] as? [String: String])?["assigneeId"], "u1")
        XCTAssertTrue(LinearAPI.commentMutation.contains("commentCreate"))
        XCTAssertTrue(LinearAPI.updateMutation.contains("issueUpdate"))
    }

    func testLinearParsesStatesCommentsAndResults() throws {
        let states = #"{"data":{"issue":{"team":{"states":{"nodes":[{"id":"b","name":"Done","type":"completed","position":3},{"id":"a","name":"Todo","type":"unstarted","position":1}]}}}}}"#
        let parsed = try LinearAPI.parseStates(Data(states.utf8))
        XCTAssertEqual(parsed, [TrackerStatus(id: "a", name: "Todo", closed: false), TrackerStatus(id: "b", name: "Done", closed: true)])

        let comments = #"{"data":{"issue":{"comments":{"nodes":[{"id":"c2","body":"Later","createdAt":"2026-10-19T10:00:00.000Z","user":{"name":"Bo"}},{"id":"c1","body":"First","createdAt":"2026-10-19T09:00:00.000Z","user":null}]}}}}"#
        let list = try LinearAPI.parseComments(Data(comments.utf8))
        XCTAssertEqual(list.map(\.id), ["c1", "c2"])
        XCTAssertEqual(list[0].author, "Unknown")

        let created = #"{"data":{"commentCreate":{"success":true,"comment":{"id":"c3","body":"Hi","createdAt":"2026-10-19T11:00:00.000Z","user":{"name":"Ana"}}}}}"#
        XCTAssertEqual(try LinearAPI.parseCreatedComment(Data(created.utf8)).author, "Ana")
        XCTAssertThrowsError(try LinearAPI.parseCreatedComment(Data(#"{"data":{"commentCreate":{"success":false}}}"#.utf8)))
        XCTAssertNoThrow(try LinearAPI.checkUpdate(Data(#"{"data":{"issueUpdate":{"success":true}}}"#.utf8)))
        XCTAssertThrowsError(try LinearAPI.checkUpdate(Data(#"{"data":{"issueUpdate":{"success":false}}}"#.utf8)))
    }

    func testLinearIssueCarriesPrioritySubIssuesAndAssignee() throws {
        let body = #"""
        {"data":{"issue":{"id":"i1","identifier":"ENG-1","title":"T","description":"d","url":"https://linear.app/x","updatedAt":"2026-10-19T09:00:00.000Z",
         "priority":2,"priorityLabel":"High","team":{"id":"t1"},"state":{"name":"Todo","type":"unstarted"},
         "assignee":{"id":"u1","name":"Ana"},"creator":{"name":"Bo"},"labels":{"nodes":[]},"comments":{"nodes":[]},
         "children":{"nodes":[{"identifier":"ENG-2","title":"Sub","state":{"name":"Done","type":"completed"}}]}}}}
        """#
        let issue = try LinearAPI.parseIssue(Data(body.utf8))
        XCTAssertEqual(issue.priority, "High"); XCTAssertEqual(issue.priorityRank, 2)
        XCTAssertEqual(issue.assignee, "Ana"); XCTAssertEqual(issue.assigneeId, "u1"); XCTAssertEqual(issue.teamId, "t1")
        XCTAssertEqual(issue.subIssues, [TrackerIssue.SubIssue(key: "ENG-2", title: "Sub", stateName: "Done", closed: true)])
        let none = #"{"data":{"issue":{"id":"i2","identifier":"ENG-3","title":"T","priority":0,"priorityLabel":"No priority"}}}"#
        XCTAssertNil(try LinearAPI.parseIssue(Data(none.utf8)).priority)
    }

    func testLinearTeamsNowReportViewerAndWorkspace() throws {
        let teams = #"{"data":{"viewer":{"id":"u1","name":"Ana"},"organization":{"name":"Acme"},"teams":{"nodes":[{"id":"t1","key":"ENG","name":"Engineering"}]}}}"#
        let parsed = try LinearAPI.parseTeams(Data(teams.utf8))
        XCTAssertEqual(parsed.viewerId, "u1"); XCTAssertEqual(parsed.workspace, "Acme")
    }

    // MARK: Jira writes and detail

    private func cloud(gateway: String = "") -> TrackerCredentials {
        TrackerCredentials(token: "tok", site: "acme.atlassian.net", email: "a@b.co", gateway: gateway)
    }

    func testJiraWritesCarryANonBrowserUserAgent() throws {
        let c = cloud()
        let requests = [
            try XCTUnwrap(JiraAPI.addCommentRequest(c, key: "ENG-1", text: "hi")),
            try XCTUnwrap(JiraAPI.transitionRequest(c, key: "ENG-1", transitionId: "31")),
            try XCTUnwrap(JiraAPI.assignRequest(c, key: "ENG-1", userId: "acc1")),
            try XCTUnwrap(JiraAPI.transitionsRequest(c, key: "ENG-1")),
        ]
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Octet")
            XCTAssertEqual(request.url?.host, "acme.atlassian.net")
            XCTAssertTrue(request.url?.path.hasPrefix("/rest/api/3/issue/ENG-1") == true)
        }
        XCTAssertEqual(requests[0].httpMethod, "POST"); XCTAssertEqual(requests[2].httpMethod, "PUT"); XCTAssertEqual(requests[3].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(((json(requests[1].httpBody)["transition"]) as? [String: String])?["id"], "31")
        XCTAssertEqual(json(requests[2].httpBody)["accountId"] as? String, "acc1")
    }

    func testJiraCommentBodyIsADFOnCloudAndTextOnServer() throws {
        let adf = json(try XCTUnwrap(JiraAPI.addCommentRequest(cloud(), key: "ENG-1", text: "one\n\ntwo")).httpBody)["body"] as? [String: Any]
        XCTAssertEqual(adf?["type"] as? String, "doc"); XCTAssertEqual(adf?["version"] as? Int, 1)
        XCTAssertEqual(JiraAPI.plainText(adf), "one\ntwo")
        let server = TrackerCredentials(token: "pat", site: "jira.example.com/jira", server: true)
        let request = try XCTUnwrap(JiraAPI.addCommentRequest(server, key: "OPS-2", text: "plain"))
        XCTAssertEqual(json(request.httpBody)["body"] as? String, "plain")
        XCTAssertEqual(request.url?.absoluteString, "https://jira.example.com/jira/rest/api/2/issue/OPS-2/comment")
        XCTAssertEqual(json(try XCTUnwrap(JiraAPI.assignRequest(server, key: "OPS-2", userId: "jdoe")).httpBody)["name"] as? String, "jdoe")
    }

    func testJiraKeysAreEscapedInPaths() throws {
        let request = try XCTUnwrap(JiraAPI.issueRequest(cloud(), key: "A/B ?x"))
        XCTAssertFalse(request.url?.path.contains("A/B") == true)
    }

    func testJiraParsesTransitionsCommentsAndPriority() throws {
        let transitions = #"{"transitions":[{"id":"21","name":"Start","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Finish","to":{"name":"Done","statusCategory":{"key":"done"}}}]}"#
        XCTAssertEqual(try JiraAPI.parseTransitions(Data(transitions.utf8)), [
            TrackerStatus(id: "21", name: "In Progress", closed: false, actionName: "Start"), TrackerStatus(id: "31", name: "Done", closed: true, actionName: "Finish")])

        let comments = #"{"comments":[{"id":"2","author":{"displayName":"Bo"},"created":"2026-10-19T10:00:00.000+0000","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Later"}]}]}},{"id":"1","author":{"displayName":"Ana"},"created":"2026-10-19T09:00:00.000+0000","body":"Wiki text"}]}"#
        let list = try JiraAPI.parseComments(Data(comments.utf8))
        XCTAssertEqual(list.map(\.body), ["Wiki text", "Later"])
        XCTAssertEqual(list.map(\.author), ["Ana", "Bo"])

        let site = try XCTUnwrap(JiraAPI.baseURL("acme"))
        let issue = #"{"id":"1","key":"ENG-1","fields":{"summary":"S","labels":[],"updated":"2026-10-19T09:00:00.000+0000","status":{"name":"To Do","statusCategory":{"key":"new"}},"assignee":{"displayName":"Ana Silva","accountId":"acc1"},"priority":{"name":"Highest"},"issuetype":{"name":"Bug"},"comment":{"total":0},"description":null}}"#
        let parsed = try JiraAPI.parseIssue(Data(issue.utf8), site: site)
        XCTAssertEqual(parsed.priority, "Highest"); XCTAssertEqual(parsed.priorityRank, 1)
        XCTAssertEqual(parsed.issueType, "Bug"); XCTAssertEqual(parsed.assigneeId, "acc1")
        XCTAssertEqual(try JiraAPI.parseMyself(Data(#"{"accountId":"acc1","displayName":"Ana"}"#.utf8)).id, "acc1")
        XCTAssertEqual(try JiraAPI.parseMyself(Data(#"{"name":"jdoe","key":"jdoe","displayName":"J Doe"}"#.utf8)).id, "jdoe")
    }

    func testJiraSubtasksAndAgentJSON() throws {
        let data = Data(#"{"id":"1","key":"A-1","fields":{"summary":"Parent","subtasks":[{"key":"A-2","fields":{"summary":"Child","status":{"name":"Done","statusCategory":{"key":"done"}}}}]}}"#.utf8)
        let issue = try JiraAPI.parseIssue(data, site: URL(string: "https://example.atlassian.net")!)
        XCTAssertEqual(issue.subIssues, [.init(key: "A-2", title: "Child", stateName: "Done", closed: true)])
        XCTAssertEqual(try JSONDecoder().decode(TrackerIssue.self, from: JSONEncoder().encode(issue)), issue)
        XCTAssertTrue(JiraAPI.issueFields.contains("subtasks"))
    }

    // MARK: Gateway and self-hosted

    func testGatewayCloudIDsAreValidatedBeforeUse() {
        XCTAssertEqual(JiraAPI.gatewayURL(cloudId: "0a1b-22cc")?.absoluteString, "https://api.atlassian.com/ex/jira/0a1b-22cc")
        XCTAssertNil(JiraAPI.gatewayURL(cloudId: "x/../evil"))
        XCTAssertNil(JiraAPI.gatewayURL(cloudId: ""))
        XCTAssertNil(JiraAPI.gatewayURL(stored: "https://evil.example/ex/jira/abc"))
        XCTAssertNil(JiraAPI.gatewayURL(stored: "http://api.atlassian.com/ex/jira/abc"))
        XCTAssertEqual(JiraAPI.parseCloudId(Data(#"{"cloudId":"abc-123"}"#.utf8)), "abc-123")
        XCTAssertNil(JiraAPI.parseCloudId(Data("nope".utf8)))
        XCTAssertEqual(JiraAPI.tenantInfoURL(site: URL(string: "https://acme.atlassian.net")!)?.absoluteString, "https://acme.atlassian.net/_edge/tenant_info")
    }

    func testScopedTokensGoThroughTheGateway() throws {
        let c = cloud(gateway: "https://api.atlassian.com/ex/jira/abc-123")
        let request = try XCTUnwrap(JiraAPI.searchRequest(c, jql: "project = X"))
        XCTAssertEqual(request.url?.host, "api.atlassian.com")
        XCTAssertEqual(request.url?.path, "/ex/jira/abc-123/rest/api/3/search/jql")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("a@b.co:tok".utf8).base64EncodedString())
        // A tampered stored gateway falls back to the site, never to another host.
        var bad = c; bad.gateway = "https://evil.example/ex/jira/abc"
        XCTAssertEqual(JiraAPI.apiRoot(bad)?.host, "acme.atlassian.net")
    }

    func testSelfHostedUsesV2BearerOrBasicAndKeepsHTTPSOnly() throws {
        var c = TrackerCredentials(token: "pat", site: "https://jira.example.com/jira/", server: true)
        let request = try XCTUnwrap(JiraAPI.searchRequest(c, jql: "project = X"))
        XCTAssertEqual(request.url?.path, "/jira/rest/api/2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pat")
        c.email = "jdoe"
        XCTAssertEqual(try XCTUnwrap(JiraAPI.myselfRequest(c)).value(forHTTPHeaderField: "Authorization"), "Basic " + Data("jdoe:pat".utf8).base64EncodedString())
        XCTAssertNil(JiraAPI.baseURL("http://jira.example.com", keepPath: true))
        XCTAssertEqual(JiraAPI.baseURL("jira.example.com/jira", keepPath: true)?.absoluteString, "https://jira.example.com/jira")
        XCTAssertEqual(JiraAPI.baseURL("https://jira.example.com:8443/jira/", keepPath: true)?.absoluteString, "https://jira.example.com:8443/jira")
        XCTAssertEqual(JiraAPI.baseURL("https://acme.atlassian.net/jira/x")?.absoluteString, "https://acme.atlassian.net")
        let projects = try JiraAPI.parseProjectList(Data(#"[{"key":"OPS","name":"Ops"}]"#.utf8))
        XCTAssertEqual(projects, [TrackerContainer(id: "OPS", name: "Ops (OPS)")])
    }

    // MARK: Credentials and connections

    func testOldCredentialBlobsStillDecode() throws {
        let old = #"{"token":"t","site":"acme.atlassian.net","email":"a@b.co"}"#
        let c = try JSONDecoder().decode(TrackerCredentials.self, from: Data(old.utf8))
        XCTAssertEqual(c, TrackerCredentials(token: "t", site: "acme.atlassian.net", email: "a@b.co"))
        XCTAssertFalse(c.server); XCTAssertEqual(c.gateway, ""); XCTAssertEqual(c.name, "")
        let roundTrip = try JSONDecoder().decode(TrackerCredentials.self, from: JSONEncoder().encode(TrackerCredentials(token: "t", server: true, gateway: "g", name: "n")))
        XCTAssertTrue(roundTrip.server); XCTAssertEqual(roundTrip.name, "n")
    }

    func testConnectionDisplayNames() {
        XCTAssertEqual(TrackerConnection(id: "x", tracker: .linear, credentials: TrackerCredentials(token: "t", name: "Acme")).displayName, "Acme")
        XCTAssertEqual(TrackerConnection(id: TrackerConnection.legacyId, tracker: .linear, credentials: TrackerCredentials(token: "t")).displayName, "Linear")
        XCTAssertEqual(TrackerConnection(id: "x", tracker: .jira, credentials: TrackerCredentials(token: "t", site: "acme")).displayName, "acme.atlassian.net")
    }

    // MARK: GitHub

    func testGitHubNumbersAndArguments() {
        XCTAssertEqual(GitHubIssueCLI.number("#142"), "142")
        XCTAssertEqual(GitHubIssueCLI.number("7"), "7")
        XCTAssertNil(GitHubIssueCLI.number("--repo=x")); XCTAssertNil(GitHubIssueCLI.number("#"))
        XCTAssertEqual(GitHubIssueCLI.closeArguments(number: "7"), ["gh", "issue", "close", "7"])
        XCTAssertEqual(GitHubIssueCLI.reopenArguments(number: "7"), ["gh", "issue", "reopen", "7"])
        XCTAssertEqual(GitHubIssueCLI.assignArguments(number: "7"), ["gh", "issue", "edit", "7", "--add-assignee", "@me"])
        // The comment text goes to stdin, so it is never an argument.
        XCTAssertEqual(GitHubIssueCLI.commentArguments(number: "7"), ["gh", "issue", "comment", "7", "--body-file", "-"])
    }

    func testGitHubIssuesAndCommentsParse() throws {
        let list = #"[{"number":5,"title":"T","body":null,"state":"OPEN","url":"https://github.com/o/r/issues/5","author":{"login":"ana"},"assignees":[{"login":"bo"}],"labels":[],"updatedAt":"2026-10-19T09:00:00Z","comments":[{},{}]}]"#
        let issue = try XCTUnwrap(GitHubIssueCLI.parseIssues(Data(list.utf8)).first)
        XCTAssertEqual(issue.key, "#5"); XCTAssertEqual(issue.assignee, "bo"); XCTAssertEqual(issue.comments, 2); XCTAssertEqual(issue.body, "")
        let noAssignees = #"[{"number":6,"title":"T","body":"","state":"CLOSED","url":"https://x","author":null,"labels":[],"updatedAt":"2026-10-19T09:00:00Z","comments":[]}]"#
        XCTAssertNil(try GitHubIssueCLI.parseIssues(Data(noAssignees.utf8))[0].assignee)

        let comments = #"{"comments":[{"id":"IC_1","author":{"login":"ana"},"body":"Hi","createdAt":"2026-10-19T09:00:00Z"},{"author":null,"body":"Bye","createdAt":"2026-10-19T10:00:00Z"}]}"#
        let parsed = try GitHubIssueCLI.parseComments(Data(comments.utf8))
        XCTAssertEqual(parsed.map(\.author), ["ana", "ghost"])
        XCTAssertThrowsError(try GitHubIssueCLI.parseComments(Data("nope".utf8)))
    }
}
