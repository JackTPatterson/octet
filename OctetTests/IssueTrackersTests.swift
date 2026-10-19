import XCTest

final class IssueTrackersTests: XCTestCase {
    // MARK: Linear

    func testLinearRequestSendsTheKeyBareToTheGraphQLEndpoint() {
        let request = LinearAPI.request(query: "query { viewer { name } }", variables: ["team": "t1"], token: "lin_api_x")
        XCTAssertEqual(request.url?.absoluteString, "https://api.linear.app/graphql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "lin_api_x")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual((body?["variables"] as? [String: String])?["team"], "t1")
    }

    func testLinearStateTypesFollowTheScope() {
        XCTAssertEqual(LinearAPI.stateTypes(scope: "open"), ["triage", "backlog", "unstarted", "started"])
        XCTAssertEqual(LinearAPI.stateTypes(scope: "closed"), ["completed", "canceled"])
        XCTAssertEqual(LinearAPI.stateTypes(scope: "all").count, 6)
    }

    func testLinearTeamsAndIssuesParse() throws {
        let teams = #"{"data":{"viewer":{"name":"Ana"},"teams":{"nodes":[{"id":"t1","key":"ENG","name":"Engineering"}]}}}"#
        let parsed = try LinearAPI.parseTeams(Data(teams.utf8))
        XCTAssertEqual(parsed.viewer, "Ana")
        XCTAssertEqual(parsed.teams, [TrackerContainer(id: "t1", name: "Engineering")])

        let issues = #"""
        {"data":{"issues":{"nodes":[
          {"id":"i1","identifier":"ENG-12","title":"Fix login","description":"Steps\nto repro","url":"https://linear.app/x/issue/ENG-12",
           "updatedAt":"2026-10-19T09:00:00.000Z","state":{"name":"In Progress","type":"started"},
           "assignee":{"name":"Ana"},"creator":{"name":"Bo"},
           "labels":{"nodes":[{"name":"bug","color":"#eb5757"}]},"comments":{"nodes":[{"id":"c1"},{"id":"c2"}]}},
          {"id":"i2","identifier":"ENG-9","title":"Old","description":null,"url":"https://linear.app/x/issue/ENG-9",
           "updatedAt":"2026-10-01T09:00:00.000Z","state":{"name":"Done","type":"completed"},
           "assignee":null,"creator":{"name":"Bo"},"labels":{"nodes":[]},"comments":{"nodes":[]}}]}}}
        """#
        let list = try LinearAPI.parseIssues(Data(issues.utf8))
        XCTAssertEqual(list.map(\.key), ["ENG-12", "ENG-9"])
        XCTAssertEqual(list[0].person, "Ana")
        XCTAssertEqual(list[0].labels, [TrackerIssue.Label(name: "bug", color: "eb5757")])
        XCTAssertEqual(list[0].comments, 2)
        XCTAssertFalse(list[0].closed)
        XCTAssertTrue(list[1].closed)
        XCTAssertEqual(list[1].person, "Bo")
        XCTAssertEqual(list[1].preview, "No description provided.")
    }

    func testLinearAuthenticationErrorsBecomeUnauthorized() {
        let body = #"{"errors":[{"message":"Authentication required, not authenticated","extensions":{"type":"authentication error"}}]}"#
        XCTAssertThrowsError(try LinearAPI.parseTeams(Data(body.utf8))) {
            XCTAssertEqual($0 as? IssueTrackerError, .unauthorized)
        }
    }

    // MARK: Jira

    func testJiraSiteAddressesAreHTTPSOnlyAndCredentialFree() {
        XCTAssertEqual(JiraAPI.baseURL("acme")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraAPI.baseURL(" acme.atlassian.net ")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraAPI.baseURL("https://acme.atlassian.net/jira/software")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertNil(JiraAPI.baseURL("http://acme.atlassian.net"))
        XCTAssertNil(JiraAPI.baseURL("file:///etc/passwd"))
        XCTAssertNil(JiraAPI.baseURL("https://user:secret@acme.atlassian.net"))
        XCTAssertNil(JiraAPI.baseURL("   "))
    }

    func testJiraRequestUsesBasicAuthAndEncodesQuery() throws {
        let site = try XCTUnwrap(JiraAPI.baseURL("acme"))
        let request = try XCTUnwrap(JiraAPI.request(path: "rest/api/3/search/jql",
                                                    query: [URLQueryItem(name: "jql", value: JiraAPI.jql(project: "ENG", scope: "open"))],
                                                    site: site, email: "a@b.co", token: "tok"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("a@b.co:tok".utf8).base64EncodedString())
        XCTAssertEqual(request.url?.host, "acme.atlassian.net")
        XCTAssertTrue(request.url?.absoluteString.contains("statusCategory") == true)
    }

    func testJiraJQLFollowsTheScopeAndStripsQuotes() {
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "open"), #"project = "ENG" AND statusCategory != Done ORDER BY updated DESC"#)
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "closed"), #"project = "ENG" AND statusCategory = Done ORDER BY updated DESC"#)
        XCTAssertEqual(JiraAPI.jql(project: "ENG", scope: "all"), #"project = "ENG" ORDER BY updated DESC"#)
        XCTAssertEqual(JiraAPI.jql(project: #"E"NG"#, scope: "all"), #"project = "ENG" ORDER BY updated DESC"#)
    }

    func testJiraIssuesParseIncludingDocumentFormatDescriptions() throws {
        let site = try XCTUnwrap(JiraAPI.baseURL("acme"))
        let body = #"""
        {"issues":[{"id":"10001","key":"ENG-7","fields":{
          "summary":"Crash on save","labels":["backend"],"updated":"2026-10-19T09:00:00.000+0000",
          "status":{"name":"To Do","statusCategory":{"key":"new"}},
          "assignee":{"displayName":"Ana"},"reporter":{"displayName":"Bo"},"comment":{"total":3},
          "description":{"type":"doc","content":[
            {"type":"paragraph","content":[{"type":"text","text":"It crashes"},{"type":"text","text":" on save."}]},
            {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Open file"}]}]}]}]}}},
          {"id":"10002","key":"ENG-3","fields":{"summary":"Shipped","labels":[],"updated":"2026-10-01T09:00:00.000+0000",
          "status":{"name":"Done","statusCategory":{"key":"done"}},"assignee":null,"reporter":null,"comment":{"total":0},"description":null}}]}
        """#
        let list = try JiraAPI.parseIssues(Data(body.utf8), site: site)
        XCTAssertEqual(list.map(\.key), ["ENG-7", "ENG-3"])
        XCTAssertEqual(list[0].body, "It crashes on save.\nOpen file")
        XCTAssertEqual(list[0].url?.absoluteString, "https://acme.atlassian.net/browse/ENG-7")
        XCTAssertEqual(list[0].person, "Ana")
        XCTAssertEqual(list[0].comments, 3)
        XCTAssertEqual(list[0].labels.map(\.name), ["backend"])
        XCTAssertFalse(list[0].closed)
        XCTAssertTrue(list[1].closed)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: list[0].updatedAt), "Jira's +0000 stamps become ISO 8601 the list can read")
    }

    func testJiraProjectsParse() throws {
        let body = #"{"values":[{"key":"ENG","name":"Engineering"},{"key":"OPS","name":"Operations"}]}"#
        XCTAssertEqual(try JiraAPI.parseProjects(Data(body.utf8)).map(\.id), ["ENG", "OPS"])
    }
}
