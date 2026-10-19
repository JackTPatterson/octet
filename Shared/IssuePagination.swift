import Foundation

struct IssueListPage: Codable {
    var issues: [TrackerIssue]
    var nextCursor: String?
    var truncated: Bool { nextCursor != nil }
    enum CodingKeys: String, CodingKey { case issues, nextCursor, truncated }
    init(issues: [TrackerIssue], nextCursor: String? = nil) { self.issues = issues; self.nextCursor = nextCursor }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = try c.decode([TrackerIssue].self, forKey: .issues)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(issues, forKey: .issues); try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try c.encode(truncated, forKey: .truncated)
    }
}

struct IssueListCursor: Codable {
    let scope: [String]
    let position: String
    func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
    static func position(_ token: String?, scope: [String]) throws -> String? {
        guard let token else { return nil }
        guard token.count < 16_384, let data = Data(base64Encoded: token),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.scope == scope else {
            throw IssueTrackerError.unreadable("Cursor does not match this tracker, connection or filter. Start a new list.")
        }
        return cursor.position
    }
}
