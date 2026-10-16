import XCTest

final class PullRequestInboxTests: XCTestCase {
    /// `gh search prs --author=@me --state=open --json …` (gh 2.87), as it
    /// came back: lower-case state, the repository as an object, labels as
    /// objects. A gh update notice sits ahead, as LoginShell merges stderr.
    private let search = ##"""
    A new release of gh is available: 2.87.2 → 2.88.0
    [{"author":{"id":"MDQ6VXNlcjMwMTI0NTcw","is_bot":false,"login":"JackTPatterson","type":"User","url":"https://github.com/JackTPatterson"},
      "createdAt":"2026-10-16T13:40:26Z","isDraft":false,"labels":[],"number":1,
      "repository":{"name":"locklandia","nameWithOwner":"JackTPatterson/locklandia"},"state":"open",
      "title":"Shorter paths: group start, first block, unlock/partners","updatedAt":"2026-10-16T19:05:09Z",
      "url":"https://github.com/JackTPatterson/locklandia/pull/1"},
     {"author":{"id":"MDQ6VXNlcjMwMTI0NTcw","is_bot":false,"login":"JackTPatterson","type":"User","url":"https://github.com/JackTPatterson"},
      "createdAt":"2026-10-13T15:49:51Z","isDraft":true,
      "labels":[{"color":"d73a4a","description":"","id":"L1","name":"bug"},{"color":"ededed","description":"","id":"L2","name":"needs review"}],
      "number":3,"repository":{"name":"getfernapp","nameWithOwner":"JackTPatterson/getfernapp"},"state":"open",
      "title":"Blog: /blog with 50 sourced posts","updatedAt":"2026-10-13T15:51:28Z",
      "url":"https://github.com/JackTPatterson/getfernapp/pull/3"}]
    """##

    /// `gh search prs --state=closed`: merged ones say so.
    private let closedSearch = ##"""
    [{"author":{"login":"JackTPatterson"},"createdAt":"2026-10-16T16:12:14Z","isDraft":false,"labels":[],"number":37,
      "repository":{"name":"octet","nameWithOwner":"JackTPatterson/octet"},"state":"merged","title":"Release 0.1.0 beta 20",
      "updatedAt":"2026-10-16T16:12:36Z","url":"https://github.com/JackTPatterson/octet/pull/37"},
     {"author":{"login":"JackTPatterson"},"createdAt":"2026-10-16T19:00:18Z","isDraft":true,"labels":[],"number":38,
      "repository":{"name":"octet","nameWithOwner":"JackTPatterson/octet"},"state":"closed","title":"PR plane test",
      "updatedAt":"2026-10-16T19:12:50Z","url":"https://github.com/JackTPatterson/octet/pull/38"}]
    """##

    /// `gh pr view 9 -R JackTPatterson/fern --json additions,deletions,statusCheckRollup`.
    private let view = ##"""
    {"additions":839,"deletions":536,"statusCheckRollup":[
      {"__typename":"CheckRun","completedAt":"2026-10-02T17:36:35Z","conclusion":"SUCCESS","detailsUrl":"https://x/1","name":"core + server","startedAt":"2026-10-02T17:33:11Z","status":"COMPLETED","workflowName":"CI"},
      {"__typename":"CheckRun","completedAt":"2026-10-02T17:33:25Z","conclusion":"FAILURE","detailsUrl":"https://x/2","name":"edge functions","startedAt":"2026-10-02T17:33:11Z","status":"COMPLETED","workflowName":"CI"}]}
    """##

    /// `gh pr list --json …` in a project folder.
    private let list = ##"""
    [{"additions":3,"assignees":[],"author":{"is_bot":false,"login":"ana","name":"Ana"},"createdAt":"2026-10-16T19:00:18Z",
      "deletions":0,"isDraft":false,"labels":[],"number":40,"reviewRequests":[{"__typename":"User","login":"JackTPatterson"}],
      "state":"OPEN","statusCheckRollup":[],"title":"Needs Jack","updatedAt":"2026-10-16T19:12:50Z","url":"https://github.com/o/r/pull/40"},
     {"additions":2651,"assignees":[],"author":{"is_bot":false,"login":"JackTPatterson","name":"Jack"},"createdAt":"2026-10-16T16:12:14Z",
      "deletions":348,"isDraft":false,"labels":[],"number":37,"reviewRequests":[],"state":"OPEN",
      "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"Build","status":"COMPLETED","workflowName":"CI"}],
      "title":"Mine","updatedAt":"2026-10-16T16:12:36Z","url":"https://github.com/o/r/pull/37"},
     {"additions":1,"assignees":[{"login":"jacktpatterson"}],"author":{"login":"bo"},"createdAt":"2026-10-15T10:00:00Z",
      "deletions":1,"isDraft":true,"labels":[],"number":36,"reviewRequests":[],"state":"OPEN","statusCheckRollup":[],
      "title":"Assigned to Jack","updatedAt":"2026-10-15T10:00:00Z","url":"https://github.com/o/r/pull/36"},
     {"additions":1,"assignees":[],"author":{"login":"cy"},"createdAt":"2026-10-14T10:00:00Z","deletions":1,"isDraft":false,
      "labels":[],"number":35,"reviewRequests":[{"__typename":"Team","name":"core","slug":"core"}],"state":"OPEN",
      "statusCheckRollup":[],"title":"Someone else's","updatedAt":"2026-10-14T10:00:00Z","url":"https://github.com/o/r/pull/35"}]
    """##

    private func items() throws -> [PullRequestInboxItem] {
        try XCTUnwrap(PullRequestInbox.parseSearch(search))
    }

    private func item(_ number: Int, repo: String = "o/r", title: String = "T", author: String = "jack",
                      state: String = "OPEN", draft: Bool = false, labels: [String] = [],
                      updated: TimeInterval = 0, created: TimeInterval = 0) -> PullRequestInboxItem {
        PullRequestInboxItem(number: number, title: title, repository: repo, author: author, isDraft: draft, state: state,
                             createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated),
                             url: nil, labels: labels)
    }

    // MARK: - Parsing

    func testParsesSearchPastALeadingNotice() throws {
        let items = try items()
        XCTAssertEqual(items.count, 2)
        let first = items[0]
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.repository, "JackTPatterson/locklandia")
        XCTAssertEqual(first.author, "JackTPatterson")
        XCTAssertEqual(first.state, "OPEN")
        XCTAssertEqual(first.tone, .open)
        XCTAssertEqual(first.id, "JackTPatterson/locklandia#1")
        XCTAssertEqual(first.url?.absoluteString, "https://github.com/JackTPatterson/locklandia/pull/1")
        XCTAssertNotNil(first.updatedAt)
        XCTAssertEqual(items[1].tone, .draft)
        XCTAssertEqual(items[1].labels, ["bug", "needs review"])
    }

    func testClosedSearchKeepsMergedApart() throws {
        let items = try XCTUnwrap(PullRequestInbox.parseSearch(closedSearch))
        XCTAssertEqual(items.map(\.tone), [.merged, .closed])
    }

    func testUnreadableSearchIsNil() {
        XCTAssertNil(PullRequestInbox.parseSearch("HTTP 401: Bad credentials"))
        XCTAssertEqual(PullRequestInbox.parseSearch("[]"), [])
    }

    func testParsesStatsFromView() throws {
        let stats = try XCTUnwrap(PullRequestStats.parse(view))
        XCTAssertEqual(stats.additions, 839)
        XCTAssertEqual(stats.deletions, 536)
        XCTAssertEqual(stats.changes, 1375)
        XCTAssertEqual(stats.checks.tone, .failing)
        XCTAssertNil(PullRequestStats.parse("{\"message\":\"Not Found\"}"))
    }

    func testStatsArgumentsAreReadOnlyAndPointAtTheRepository() {
        let args = PullRequestStats.arguments(for: item(9, repo: "JackTPatterson/fern"))
        XCTAssertEqual(args, ["gh", "pr", "view", "9", "-R", "JackTPatterson/fern", "--json", "additions,deletions,statusCheckRollup"])
    }

    func testSearchArguments() {
        XCTAssertEqual(PullRequestInbox.searchArguments(.reviewRequested),
                       ["gh", "search", "prs", "--review-requested=@me", "--state=open", "--json",
                        PullRequestInbox.searchFields, "--limit", "100"])
        XCTAssertEqual(PullRequestInbox.searchArguments(.mentioned, closed: true)?[4], "--state=closed")
        XCTAssertNil(PullRequestInbox.searchArguments(.other))
        // Only reading verbs, whatever the section.
        for group in PullRequestInboxGroup.allCases {
            if let args = PullRequestInbox.searchArguments(group) { XCTAssertEqual(Array(args.prefix(3)), ["gh", "search", "prs"]) }
        }
        XCTAssertEqual(Array(PullRequestInbox.listArguments().prefix(3)), ["gh", "pr", "list"])
    }

    func testListGroupsByWhyItsYours() throws {
        let rows = try XCTUnwrap(PullRequestInbox.parseList(list, repository: "o/r", viewer: "JackTPatterson"))
        XCTAssertEqual(rows.map(\.item.number), [40, 37, 36, 35])
        XCTAssertEqual(rows.map(\.group), [.reviewRequested, .authored, .assigned, .other])
        XCTAssertEqual(rows.map(\.item.repository), ["o/r", "o/r", "o/r", "o/r"])
        XCTAssertEqual(rows[1].stats?.additions, 2651)
        XCTAssertEqual(rows[1].stats?.checks.tone, .passing)
        // Without knowing who you are, everything is "other".
        let anonymous = try XCTUnwrap(PullRequestInbox.parseList(list, repository: "o/r", viewer: nil))
        XCTAssertEqual(Set(anonymous.map(\.group)), [.other])
    }

    // MARK: - Grouping

    func testGroupedShowsEachPullRequestOnceInTheFirstSection() {
        let shared = item(1), own = item(2), mention = item(3, repo: "x/y")
        let grouped = PullRequestInbox.grouped([
            .mentioned: [shared, mention],
            .authored: [own, shared],
            .assigned: [],
        ])
        XCTAssertEqual(grouped.map(\.group), [.authored, .mentioned])
        XCTAssertEqual(grouped[0].items.map(\.id), ["o/r#2", "o/r#1"])
        XCTAssertEqual(grouped[1].items.map(\.id), ["x/y#3"])
    }

    func testRepositoriesMostFirst() {
        let found: [PullRequestInboxGroup: [PullRequestInboxItem]] = [
            .authored: [item(1, repo: "a/one"), item(2, repo: "b/two"), item(3, repo: "b/two")],
            .mentioned: [item(1, repo: "a/one")],
        ]
        XCTAssertEqual(PullRequestInbox.repositories(found), ["b/two", "a/one"])
    }

    // MARK: - Query

    func testQueryParsesQualifiersAndQuotes() {
        let query = PullRequestQuery(#"fix  label:bug label:"needs review" repo:o/r author:@Ana is:draft Typo"#)
        XCTAssertEqual(query.words, ["fix", "typo"])
        XCTAssertEqual(query.labels, ["bug", "needs review"])
        XCTAssertEqual(query.repositories, ["o/r"])
        XCTAssertEqual(query.authors, ["ana"])
        XCTAssertEqual(query.states, ["draft"])
        XCTAssertTrue(PullRequestQuery("   ").isEmpty)
        // Unknown qualifiers and links are just text; empty values drop.
        let loose = PullRequestQuery("https://x is:weird label:")
        XCTAssertEqual(loose.words, ["https://x", "is:weird"])
        XCTAssertTrue(loose.labels.isEmpty)
    }

    func testQueryMatchesTextNumberRepositoryAndAuthor() throws {
        let rows = try items()
        XCTAssertEqual(rows.filter(PullRequestQuery("blog").matches).map(\.number), [3])
        XCTAssertEqual(rows.filter(PullRequestQuery("#1").matches).map(\.number), [1])
        XCTAssertEqual(rows.filter(PullRequestQuery("LOCKLANDIA").matches).map(\.number), [1])
        XCTAssertEqual(rows.filter(PullRequestQuery("jacktpatterson").matches).count, 2)
        XCTAssertEqual(rows.filter(PullRequestQuery("blog nothing").matches), [])
    }

    func testQueryQualifiers() throws {
        let rows = try items()
        XCTAssertEqual(rows.filter(PullRequestQuery("label:bug").matches).map(\.number), [3])
        XCTAssertEqual(rows.filter(PullRequestQuery(#"label:"Needs Review""#).matches).map(\.number), [3])
        XCTAssertEqual(rows.filter(PullRequestQuery("repo:JackTPatterson/locklandia").matches).map(\.number), [1])
        // A bare repository name is enough.
        XCTAssertEqual(rows.filter(PullRequestQuery("repo:getfernapp").matches).map(\.number), [3])
        XCTAssertEqual(rows.filter(PullRequestQuery("author:someone").matches), [])
        XCTAssertEqual(rows.filter(PullRequestQuery("author:jacktpatterson").matches).count, 2)
        XCTAssertEqual(rows.filter(PullRequestQuery("is:draft").matches).map(\.number), [3])
        // is:open includes drafts, as on GitHub.
        XCTAssertEqual(rows.filter(PullRequestQuery("is:open").matches).map(\.number), [1, 3])
    }

    func testQueryStatesOnClosedResults() throws {
        let rows = try XCTUnwrap(PullRequestInbox.parseSearch(closedSearch))
        XCTAssertEqual(rows.filter(PullRequestQuery("is:merged").matches).map(\.number), [37])
        XCTAssertEqual(rows.filter(PullRequestQuery("is:closed").matches).map(\.number), [38])
        XCTAssertEqual(rows.filter(PullRequestQuery("is:open").matches), [])
        XCTAssertTrue(PullRequestQuery("is:merged").wantsClosed)
        XCTAssertFalse(PullRequestQuery("is:draft").wantsClosed)
    }

    // MARK: - Filters and sort

    func testFilters() {
        let open = item(1), draft = item(2, draft: true), merged = item(3, state: "MERGED")
        let failing = PullRequestStats(additions: 1, deletions: 1, checks: PullRequestChecksSummary([
            PullRequestCheck(name: "CI", workflow: "", state: .failed, url: nil, index: 0),
        ]))
        var filters = PullRequestFilters()
        XCTAssertTrue(filters.admits(open, in: .authored, stats: nil))
        XCTAssertTrue(filters.admits(draft, in: .authored, stats: nil))
        XCTAssertFalse(filters.admits(merged, in: .authored, stats: nil))
        XCTAssertFalse(filters.wantsClosed)
        filters.tones.insert(.merged)
        XCTAssertTrue(filters.wantsClosed)
        XCTAssertTrue(filters.admits(merged, in: .authored, stats: nil))

        filters = PullRequestFilters()
        filters.reviewRequested = true
        XCTAssertFalse(filters.admits(open, in: .authored, stats: nil))
        XCTAssertTrue(filters.admits(open, in: .reviewRequested, stats: nil))

        filters = PullRequestFilters()
        filters.checksFailing = true
        XCTAssertFalse(filters.admits(open, in: .authored, stats: nil), "unread checks hide")
        XCTAssertTrue(filters.admits(open, in: .authored, stats: failing))
        XCTAssertFalse(filters.isDefault)
    }

    func testSortOrders() {
        let a = item(1, updated: 300, created: 100), b = item(2, updated: 100, created: 300), c = item(3, updated: 200, created: 200)
        XCTAssertEqual(PullRequestSort.updated.sorted([a, b, c], stats: [:]).map(\.number), [1, 3, 2])
        XCTAssertEqual(PullRequestSort.created.sorted([a, b, c], stats: [:]).map(\.number), [2, 3, 1])
        let stats: [String: PullRequestStats] = [
            b.id: PullRequestStats(additions: 50, deletions: 50, checks: PullRequestChecksSummary([])),
            c.id: PullRequestStats(additions: 5, deletions: 0, checks: PullRequestChecksSummary([])),
        ]
        // Unsized rows go last, newest first among themselves.
        XCTAssertEqual(PullRequestSort.changes.sorted([a, b, c], stats: stats).map(\.number), [2, 3, 1])
    }

    func testScopeTitles() {
        XCTAssertEqual(PullRequestScope.all.title, "All")
        XCTAssertEqual(PullRequestScope.project.title, "This project")
        XCTAssertEqual(PullRequestScope.repository("JackTPatterson/fern").title, "fern")
    }
}
