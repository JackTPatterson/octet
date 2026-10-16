import Foundation

// The pull request Code tab's review layer, after T3 Code's: which files
// you've marked viewed, the review comments already on the diff, and the
// line comments you're writing. gh has no command for any of it, so it goes
// through `gh api`: GraphQL for viewed marks (REST has none) and REST for
// review comments. Every command and parser here is pure, so the tests can
// check the exact argv and JSON without touching GitHub.

// MARK: - Where a comment sits

/// One line of the diff as GitHub addresses it: a path, a line number, and
/// which side of the diff that number counts on.
struct PullRequestLineAnchor: Hashable {
    enum Side: String, Hashable {
        /// The base: a removed line, numbered in the old file.
        case left = "LEFT"
        /// The head: an added or unchanged line, numbered in the new file.
        case right = "RIGHT"
    }

    let path: String
    let line: Int
    let side: Side

    /// A removed line only exists in the old file, so it's LEFT by its old
    /// number; added and context lines are RIGHT by their new number, which
    /// is what GitHub's own "comment on this line" does in the unified view.
    init?(path: String, line: ReviewDiff.Line) {
        switch line.kind {
        case .removed:
            guard let number = line.oldNumber else { return nil }
            self.init(path: path, line: number, side: .left)
        case .added, .context:
            guard let number = line.newNumber else { return nil }
            self.init(path: path, line: number, side: .right)
        }
    }

    init(path: String, line: Int, side: Side) {
        self.path = path
        self.line = line
        self.side = side
    }
}

// MARK: - Existing review comments

/// A review comment already on the PR, from
/// `gh api repos/{o}/{r}/pulls/{n}/comments` (REST). Shown read-only under
/// its line.
struct PullRequestReviewComment: Equatable, Identifiable {
    let id: Int
    /// The comment this one answers; replies carry their thread's anchor.
    let inReplyTo: Int?
    let path: String
    /// nil once the line has gone from the diff (an outdated comment), or
    /// for a comment on the whole file.
    let line: Int?
    let side: PullRequestLineAnchor.Side
    let author: String
    let body: String
    let createdAt: Date?
    let url: URL?

    var anchor: PullRequestLineAnchor? {
        line.map { PullRequestLineAnchor(path: path, line: $0, side: side) }
    }

    static func arguments(repository: String, number: Int) -> [String] {
        // --paginate: a long review runs past one page.
        ["gh", "api", "repos/\(repository)/pulls/\(number)/comments?per_page=100", "--paginate"]
    }

    /// The REST list. gh 2.87 joins `--paginate`'s pages into one array;
    /// older versions print one array per page back to back, so every
    /// top-level array is read. A `[` in a warning ahead of them is skipped.
    static func parseList(_ output: String) -> [PullRequestReviewComment]? {
        var items: [[String: Any]] = []
        var found = false
        var rest = Substring(output)
        while let open = rest.firstIndex(of: "[") {
            if let close = matchingBracket(in: rest, from: open),
               let page = try? JSONSerialization.jsonObject(with: Data(rest[open...close].utf8)) as? [[String: Any]] {
                found = true
                items += page
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[rest.index(after: open)...]
            }
        }
        guard found else { return nil }
        return items.compactMap(parse)
    }

    static func parse(_ json: [String: Any]) -> PullRequestReviewComment? {
        guard let id = json["id"] as? Int, let path = json["path"] as? String else { return nil }
        return PullRequestReviewComment(
            id: id,
            inReplyTo: json["in_reply_to_id"] as? Int,
            path: path,
            line: json["line"] as? Int,
            side: PullRequestLineAnchor.Side(rawValue: (json["side"] as? String ?? "").uppercased()) ?? .right,
            author: (json["user"] as? [String: Any])?["login"] as? String ?? "ghost",
            body: json["body"] as? String ?? "",
            createdAt: PullRequestJSON.date(json["created_at"]),
            url: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Comments by where they sit, each line's oldest first, so a thread
    /// reads top to bottom. Outdated and file-level comments have no line
    /// in this diff and are left out.
    static func byAnchor(_ comments: [PullRequestReviewComment]) -> [PullRequestLineAnchor: [PullRequestReviewComment]] {
        var result: [PullRequestLineAnchor: [PullRequestReviewComment]] = [:]
        for comment in comments {
            guard let anchor = comment.anchor else { continue }
            result[anchor, default: []].append(comment)
        }
        return result.mapValues { list in
            list.sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        }
    }

    /// The end of the JSON array opening at `open`, skipping brackets inside
    /// strings (a comment body can hold "]").
    private static func matchingBracket(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0, inString = false, escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Viewed marks

/// Which of a PR's files you've marked viewed, and the PR's node id the
/// marking mutations need. GitHub keeps this per viewer and only GraphQL
/// reads or writes it.
struct PullRequestViewedState: Equatable {
    let pullRequestId: String
    /// Path to viewed. Only files GitHub listed are here; a path missing
    /// from it reads as unviewed.
    var viewed: [String: Bool]

    func isViewed(_ path: String) -> Bool { viewed[path] ?? false }

    /// "2 of 5 viewed", counted over the files the diff shows.
    static func summary(viewed: Int, of total: Int) -> String { "\(viewed) of \(total) viewed" }

    func count(in paths: [String]) -> Int { paths.filter(isViewed).count }

    static let query = """
        query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id files(first:100){nodes{path viewerViewedState}}}}}
        """

    /// Reads the node id and every file's state in one query. `-F` makes
    /// the number an Int, as the query's `$number:Int!` wants.
    static func arguments(repository: String, number: Int) -> [String]? {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return ["gh", "api", "graphql", "-f", "query=" + query,
                "-f", "owner=" + parts[0], "-f", "name=" + parts[1], "-F", "number=\(number)"]
    }

    static func mutation(viewed: Bool) -> String {
        let field = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        return "mutation($id:ID!,$path:String!){\(field)(input:{pullRequestId:$id,path:$path}){clientMutationId}}"
    }

    /// Marks (or unmarks) one file. `-f` keeps a path that looks like a
    /// number or "true" a string.
    static func markArguments(pullRequestId: String, path: String, viewed: Bool) -> [String] {
        ["gh", "api", "graphql", "-f", "query=" + mutation(viewed: viewed),
         "-f", "id=" + pullRequestId, "-f", "path=" + path]
    }

    /// The query's answer. VIEWED is viewed; UNVIEWED and DISMISSED (viewed,
    /// then changed since) are not, as on GitHub.
    static func parse(_ output: String) -> PullRequestViewedState? {
        guard let json = PullRequestJSON.object(in: output),
              let pull = ((json["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let id = pull["id"] as? String else { return nil }
        let nodes = (pull["files"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        var viewed: [String: Bool] = [:]
        for node in nodes {
            guard let path = node["path"] as? String else { continue }
            viewed[path] = (node["viewerViewedState"] as? String ?? "").uppercased() == "VIEWED"
        }
        return PullRequestViewedState(pullRequestId: id, viewed: viewed)
    }
}

// MARK: - Line comments you're writing

/// A line comment held for the next review, as "Add to Review" keeps it.
struct PullRequestPendingComment: Equatable, Identifiable {
    let id: UUID
    let anchor: PullRequestLineAnchor
    var body: String

    init(anchor: PullRequestLineAnchor, body: String, id: UUID = UUID()) {
        self.id = id
        self.anchor = anchor
        self.body = body
    }

    /// "Add to Agent": the comment as a request to the agent, with the
    /// line's code so it needn't go looking.
    static func agentPrompt(number: Int, anchor: PullRequestLineAnchor, code: String, text: String) -> String {
        let location = "\(anchor.path):\(anchor.line)" + (anchor.side == .left ? " (removed line)" : "")
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        var prompt = "On PR #\(number), about \(location)"
        if !trimmed.isEmpty { prompt += " `\(trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed)`" }
        prompt += ":\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt
    }
}

/// A review's verdict, as the REST API names it.
enum PullRequestReviewEvent: String, Hashable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    /// Changes requested need a reason. A plain comment needs a body or at
    /// least one line comment; approving needs neither.
    static func canSubmit(_ event: PullRequestReviewEvent, body: String, lineComments: Int) -> Bool {
        let written = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch event {
        case .approve: return true
        case .requestChanges: return written
        case .comment: return written || lineComments > 0
        }
    }
}

/// A review with line comments, which `gh pr review` can't send: it goes to
/// `POST repos/{o}/{r}/pulls/{n}/reviews` with the JSON on stdin.
enum PullRequestReviewSubmission {
    static func arguments(repository: String, number: Int) -> [String] {
        ["gh", "api", "repos/\(repository)/pulls/\(number)/reviews", "--method", "POST", "--input", "-"]
    }

    /// The request body. Comments go in file and line order; keys are
    /// sorted so the same review is always the same bytes.
    static func body(event: PullRequestReviewEvent, body: String,
                     comments: [PullRequestPendingComment]) -> Data {
        let sorted = comments.sorted {
            ($0.anchor.path, $0.anchor.line, $0.anchor.side.rawValue) < ($1.anchor.path, $1.anchor.line, $1.anchor.side.rawValue)
        }
        let object: [String: Any] = [
            "event": event.rawValue,
            "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
            "comments": sorted.map { comment -> [String: Any] in
                ["path": comment.anchor.path, "line": comment.anchor.line, "side": comment.anchor.side.rawValue,
                 "body": comment.body.trimmingCharacters(in: .whitespacesAndNewlines)]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
