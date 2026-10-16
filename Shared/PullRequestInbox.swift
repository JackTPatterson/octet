import Foundation

// The Pull Requests page's model, after T3 Code's: every open pull request
// that involves you, across repositories, from `gh search prs`, grouped by
// why it's yours, then searched, filtered and sorted. Pure, so the parsing
// and the query language are tested without gh.

// MARK: - A row

/// One pull request on the page. `gh search prs` carries no size or checks,
/// so those are `PullRequestStats`, read separately per row.
struct PullRequestInboxItem: Equatable, Identifiable {
    let number: Int
    let title: String
    /// "owner/name".
    let repository: String
    let author: String
    let isDraft: Bool
    /// Upper-cased: search says "open"/"merged", `gh pr list` "OPEN"/"MERGED".
    let state: String
    let createdAt: Date?
    let updatedAt: Date?
    let url: URL?
    let labels: [String]

    /// Numbers repeat across repositories; the pair doesn't.
    var id: String { "\(repository)#\(number)" }
    var tone: PullRequestTone { PullRequestTone(state: state, isDraft: isDraft) }
    var isOpen: Bool { state == "OPEN" }

    static func parse(_ json: [String: Any], repository fallback: String? = nil) -> PullRequestInboxItem? {
        guard let number = json["number"] as? Int else { return nil }
        let repository = (json["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? fallback
        guard let repository, !repository.isEmpty else { return nil }
        return PullRequestInboxItem(
            number: number,
            title: json["title"] as? String ?? "",
            repository: repository,
            author: (json["author"] as? [String: Any])?["login"] as? String ?? "ghost",
            isDraft: json["isDraft"] as? Bool ?? false,
            state: (json["state"] as? String ?? "OPEN").uppercased(),
            createdAt: PullRequestJSON.date(json["createdAt"]),
            updatedAt: PullRequestJSON.date(json["updatedAt"]),
            url: (json["url"] as? String).flatMap(URL.init(string:)),
            labels: (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }
}

/// A row's size and checks, from `gh pr view N -R repo`.
struct PullRequestStats: Equatable {
    static let fields = "additions,deletions,statusCheckRollup"

    let additions: Int
    let deletions: Int
    let checks: PullRequestChecksSummary

    var changes: Int { additions + deletions }

    static func parse(_ output: String) -> PullRequestStats? {
        PullRequestJSON.object(in: output).flatMap(parse)
    }

    static func parse(_ json: [String: Any]) -> PullRequestStats? {
        guard json["additions"] != nil || json["statusCheckRollup"] != nil else { return nil }
        return PullRequestStats(additions: json["additions"] as? Int ?? 0,
                                deletions: json["deletions"] as? Int ?? 0,
                                checks: PullRequestChecksSummary(PullRequestCheck.parseRollup(json["statusCheckRollup"])))
    }

    /// Read-only: `gh pr view`, pointed at the row's repository.
    static func arguments(for item: PullRequestInboxItem) -> [String] {
        ["gh", "pr", "view", String(item.number), "-R", item.repository, "--json", fields]
    }
}

// MARK: - Groups

/// Why a pull request is on your page; the page's sections, in this order.
/// A PR in several (your own PR you're also assigned) shows in the first.
enum PullRequestInboxGroup: String, CaseIterable, Identifiable {
    case reviewRequested, authored, assigned, mentioned
    /// "This project": the repository's other open PRs.
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviewRequested: "Needs your review"
        case .authored: "Authored"
        case .assigned: "Assigned"
        case .mentioned: "Mentioned"
        case .other: "Everything else"
        }
    }

    var icon: String {
        switch self {
        case .reviewRequested: "eye"
        case .authored: "pull.request"
        case .assigned: "person.badge.plus"
        case .mentioned: "message"
        case .other: "list"
        }
    }

    /// The `gh search prs` qualifier that finds it; nil for `other`.
    var searchFlag: String? {
        switch self {
        case .reviewRequested: "--review-requested=@me"
        case .authored: "--author=@me"
        case .assigned: "--assignee=@me"
        case .mentioned: "--mentions=@me"
        case .other: nil
        }
    }
}

enum PullRequestInbox {
    static let searchFields = "number,title,repository,author,isDraft,state,updatedAt,createdAt,url,labels"
    /// `gh pr list` has size and checks too, so "This project" needs no
    /// per-row reads, and who's asked to review, to group by.
    static let listFields = "number,title,author,isDraft,state,updatedAt,createdAt,url,labels,"
        + "additions,deletions,statusCheckRollup,reviewRequests,assignees"
    static let limit = 100

    /// `gh search prs` for one section. `closed` also finds merged ones;
    /// search has no separate merged state to ask for.
    static func searchArguments(_ group: PullRequestInboxGroup, closed: Bool = false) -> [String]? {
        guard let flag = group.searchFlag else { return nil }
        return ["gh", "search", "prs", flag, "--state=\(closed ? "closed" : "open")",
                "--json", searchFields, "--limit", String(limit)]
    }

    /// `gh pr list` in the project's folder.
    static func listArguments(closed: Bool = false) -> [String] {
        ["gh", "pr", "list", "--state", closed ? "all" : "open", "--json", listFields, "--limit", String(limit)]
    }

    static func parseSearch(_ output: String) -> [PullRequestInboxItem]? {
        PullRequestJSON.array(in: output)?.compactMap { PullRequestInboxItem.parse($0) }
    }

    /// One project's PRs, each with its section (from you as `viewer`) and
    /// its stats, which `gh pr list` already has.
    static func parseList(_ output: String, repository: String, viewer: String?)
        -> [(item: PullRequestInboxItem, group: PullRequestInboxGroup, stats: PullRequestStats?)]? {
        guard let array = PullRequestJSON.array(in: output) else { return nil }
        let me = viewer?.lowercased()
        return array.compactMap { json in
            guard let item = PullRequestInboxItem.parse(json, repository: repository) else { return nil }
            let reviewers = (json["reviewRequests"] as? [[String: Any]] ?? []).compactMap { ($0["login"] as? String)?.lowercased() }
            let assignees = (json["assignees"] as? [[String: Any]] ?? []).compactMap { ($0["login"] as? String)?.lowercased() }
            let group: PullRequestInboxGroup
            if let me, reviewers.contains(me) { group = .reviewRequested }
            else if let me, item.author.lowercased() == me { group = .authored }
            else if let me, assignees.contains(me) { group = .assigned }
            else { group = .other }
            return (item, group, PullRequestStats.parse(json))
        }
    }

    /// Sections in order, each PR once (in the first section it's in),
    /// empty sections left out.
    static func grouped(_ found: [PullRequestInboxGroup: [PullRequestInboxItem]])
        -> [(group: PullRequestInboxGroup, items: [PullRequestInboxItem])] {
        var seen = Set<String>()
        return PullRequestInboxGroup.allCases.compactMap { group in
            let items = (found[group] ?? []).filter { seen.insert($0.id).inserted }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// Every repository in `found`, for the scope picker: most PRs first.
    static func repositories(_ found: [PullRequestInboxGroup: [PullRequestInboxItem]]) -> [String] {
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        for item in found.values.joined() where seen.insert(item.id).inserted {
            counts[item.repository, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lowercased() < $1.key.lowercased() }.map(\.key)
    }
}

// MARK: - Search

/// What's typed in the search field: free words plus GitHub's qualifiers
/// `label:`, `repo:`, `author:` and `is:` (open, draft, closed, merged).
/// Quotes keep a value with spaces together: `label:"needs review"`.
struct PullRequestQuery: Equatable {
    var words: [String] = []
    var labels: [String] = []
    var repositories: [String] = []
    var authors: [String] = []
    var states: Set<String> = []

    var isEmpty: Bool { self == PullRequestQuery() }

    init() {}

    init(_ text: String) {
        for token in Self.tokens(text) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                words.append(token.lowercased())
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...]).lowercased()
            guard !value.isEmpty else { continue }
            switch key {
            case "label": labels.append(value)
            case "repo": repositories.append(value)
            case "author": authors.append(value.hasPrefix("@") ? String(value.dropFirst()) : value)
            case "is" where ["open", "draft", "closed", "merged"].contains(value): states.insert(value)
            // An unknown qualifier ("foo:bar", a URL) is searched as text.
            default: words.append(token.lowercased())
            }
        }
    }

    /// Splits on spaces outside quotes; the quotes themselves drop.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Every part must hold: each word somewhere in the title, number,
    /// repository or author; each label present; the repository and author
    /// one of those named. `is:open` includes drafts, as on GitHub.
    func matches(_ item: PullRequestInboxItem) -> Bool {
        let haystack = "\(item.title) #\(item.number) \(item.repository) \(item.author)".lowercased()
        guard words.allSatisfy({ haystack.contains($0) }) else { return false }
        let itemLabels = item.labels.map { $0.lowercased() }
        guard labels.allSatisfy({ itemLabels.contains($0) }) else { return false }
        if !repositories.isEmpty {
            let repository = item.repository.lowercased()
            let name = repository.split(separator: "/").last.map(String.init) ?? repository
            guard repositories.contains(where: { $0 == repository || $0 == name }) else { return false }
        }
        if !authors.isEmpty, !authors.contains(item.author.lowercased()) { return false }
        if !states.isEmpty {
            let state: Bool = states.contains { state in
                switch state {
                case "open": item.isOpen
                case "draft": item.isOpen && item.isDraft
                case "closed": item.tone == .closed
                case "merged": item.tone == .merged
                default: false
                }
            }
            if !state { return false }
        }
        return true
    }

    /// Asks for closed or merged PRs, which the default open-only read lacks.
    var wantsClosed: Bool { states.contains("closed") || states.contains("merged") }
}

// MARK: - Filters and sort

/// The Filters menu: which states show, and two narrowing switches.
struct PullRequestFilters: Equatable {
    var tones: Set<PullRequestTone> = [.open, .draft]
    /// Only PRs waiting on your review.
    var reviewRequested = false
    /// Only PRs whose checks fail; rows whose checks aren't read yet hide.
    var checksFailing = false

    var wantsClosed: Bool { tones.contains(.closed) || tones.contains(.merged) }
    var isDefault: Bool { self == PullRequestFilters() }

    func admits(_ item: PullRequestInboxItem, in group: PullRequestInboxGroup, stats: PullRequestStats?) -> Bool {
        guard tones.contains(item.tone) else { return false }
        if reviewRequested, group != .reviewRequested { return false }
        if checksFailing, stats?.checks.tone != .failing { return false }
        return true
    }
}

enum PullRequestSort: String, CaseIterable, Identifiable {
    case updated, created, changes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updated: "Recently updated"
        case .created: "Newest"
        case .changes: "Most changes"
        }
    }

    /// Newest or biggest first. Rows not yet sized sort last, by update, so
    /// the list settles as sizes arrive rather than jumping at random.
    func sorted(_ items: [PullRequestInboxItem], stats: [String: PullRequestStats]) -> [PullRequestInboxItem] {
        let distantPast = Date.distantPast
        return items.sorted { a, b in
            switch self {
            case .updated:
                return (a.updatedAt ?? distantPast) > (b.updatedAt ?? distantPast)
            case .created:
                return (a.createdAt ?? distantPast) > (b.createdAt ?? distantPast)
            case .changes:
                let x = stats[a.id]?.changes ?? -1, y = stats[b.id]?.changes ?? -1
                if x != y { return x > y }
                return (a.updatedAt ?? distantPast) > (b.updatedAt ?? distantPast)
            }
        }
    }
}

/// Where the page looks: everything involving you, the focused folder's
/// repository, or one repository from the results.
enum PullRequestScope: Hashable {
    case all
    case project
    case repository(String)

    var title: String {
        switch self {
        case .all: "All"
        case .project: "This project"
        case .repository(let name): name.split(separator: "/").last.map(String.init) ?? name
        }
    }
}
