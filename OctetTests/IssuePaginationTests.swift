import XCTest
@testable import Octet

final class IssuePaginationTests: XCTestCase {
    func testLinearWalksPagesAndCursorIsBoundToQuery() async throws {
        let connection = Octet.TrackerConnection(id: "work", tracker: .linear, credentials: .init(token: "fixture"))
        let transport: (URLRequest?) async throws -> Data = { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as! [String: Any]
            let variables = body["variables"] as! [String: Any]
            let second = variables["after"] as? String == "next"
            return Data((second
                ? #"{"data":{"issues":{"nodes":[{"id":"2","identifier":"ENG-2","title":"Two"}],"pageInfo":{"hasNextPage":false}}}}"#
                : #"{"data":{"issues":{"nodes":[{"id":"1","identifier":"ENG-1","title":"One"}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}"#).utf8)
        }
        let all = try await IssueService.listPages(tracker: .linear, container: "team", connectionOverride: connection, transport: transport)
        XCTAssertEqual(all.issues.map(\.key), ["ENG-1", "ENG-2"])
        XCTAssertFalse(all.truncated)
        let first = try await IssueService.listPages(tracker: .linear, container: "team", limit: 1, connectionOverride: connection, transport: transport)
        XCTAssertTrue(first.truncated)
        let second = try await IssueService.listPages(tracker: .linear, container: "team", cursor: first.nextCursor, connectionOverride: connection, transport: transport)
        XCTAssertEqual(second.issues.map(\.key), ["ENG-2"])
        do {
            _ = try await IssueService.listPages(tracker: .linear, container: "other-team", cursor: first.nextCursor, connectionOverride: connection, transport: transport)
            XCTFail("Cross-query cursor must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Cursor")) }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }

    func testJiraCloudUsesTokenAndServerUsesOffset() async throws {
        for server in [false, true] {
            let connection = Octet.TrackerConnection(id: "jira", tracker: .jira, credentials: .init(token: "fixture", site: "https://jira.example.test", server: server))
            var requests = 0
            let result = try await IssueService.listPages(tracker: .jira, container: "ENG", connectionOverride: connection) { request in
                let query = URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)!.queryItems!
                let second = query.contains { $0.name == (server ? "startAt" : "nextPageToken") && $0.value == (server ? "1" : "token") }
                requests += 1
                let node: [String: Any] = ["id": second ? "2" : "1", "key": second ? "ENG-2" : "ENG-1", "fields": ["summary": "Issue"]]
                var root: [String: Any] = ["issues": [node]]
                if server { root["total"] = 2 }
                else { root["isLast"] = second; if !second { root["nextPageToken"] = "token" } }
                return try JSONSerialization.data(withJSONObject: root)
            }
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(result.issues.count, 2)
            XCTAssertFalse(result.truncated)
        }
    }

    func testRepeatedContinuationFailsRatherThanLooping() async throws {
        let connection = Octet.TrackerConnection(id: "work", tracker: .linear, credentials: .init(token: "fixture"))
        do {
            _ = try await IssueService.listPages(tracker: .linear, container: "team", connectionOverride: connection) { _ in
                Data(#"{"data":{"issues":{"nodes":[{"id":"1","identifier":"ENG-1","title":"One"}],"pageInfo":{"hasNextPage":true,"endCursor":"same"}}}}"#.utf8)
            }
            XCTFail("Repeated cursor must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("advance")) }
    }
}
