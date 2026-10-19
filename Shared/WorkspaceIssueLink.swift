import Foundation

/// Stored in this checkout's git directory, never in committed files or credentials.
struct WorkspaceIssueLink: Codable, Equatable {
    let tracker: String
    let connectionId: String?
    let issueId: String
    let key: String
    let title: String
    let url: URL?

    static func location(in directory: String) throws -> URL {
        let path = try Git().run(["rev-parse", "--path-format=absolute", "--git-path", "octet-issue.json"], in: directory)
        return URL(fileURLWithPath: path)
    }
    static func read(in directory: String) throws -> Self? {
        let file = try location(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    func save(in directory: String) throws {
        let file = try Self.location(in: directory)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
