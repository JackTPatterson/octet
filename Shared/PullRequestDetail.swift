import Foundation

// The pull request plane's model: one pull request in full, as `gh pr view
// --json` gives it, and the decisions the plane makes from it (what the
// primary button is, how the checks read, which merge method to offer).
// Kept free of AppKit and SwiftUI so the tests can check every decision.

/// The tone a PR's state is drawn in (tab icon colour).
enum PullRequestTone: Equatable {
    case open, draft, closed, merged

    init(state: String, isDraft: Bool) {
        switch state.uppercased() {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default: self = isDraft ? .draft : .open
        }
    }
}

/// How a pull request's commits land on its base.
enum PullRequestMergeMethod: String, CaseIterable, Equatable {
    case merge, squash, rebase

    /// GitHub's own name for it, as `autoMergeRequest.mergeMethod` says.
    init?(github: String) {
        self.init(rawValue: github.lowercased())
    }

    var title: String {
        switch self {
        case .merge: "Merge"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    /// The short form for a badge: "Auto-merge (squash)".
    var noun: String { rawValue }

    /// `gh pr merge`'s flag for it.
    var flag: String { "--" + rawValue }

    /// Remembered across pull requests, so the method you used last is the
    /// one offered next.
    static let defaultsKey = "octet.pr.mergeMethod"

    /// The method to offer: this PR's own choice, else the last one picked,
    /// else the first the repository allows (merge, squash, rebase). A
    /// choice the repository doesn't allow is passed over; gh would refuse it.
    static func resolve(chosen: PullRequestMergeMethod?, last: PullRequestMergeMethod?,
                        allowed: [PullRequestMergeMethod]) -> PullRequestMergeMethod? {
        if let chosen, allowed.contains(chosen) { return chosen }
        if let last, allowed.contains(last) { return last }
        return allowed.first
    }
}

// MARK: - Checks

/// One status check on the head commit: a GitHub Actions job (a CheckRun)
/// or a commit status from elsewhere (a StatusContext).
struct PullRequestCheck: Equatable, Identifiable {
    enum State: Equatable {
        case running, passed, failed, cancelled, skipped, neutral

        var title: String {
            switch self {
            case .running: "Running"
            case .passed: "Passed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .skipped: "Skipped"
            case .neutral: "Neutral"
            }
        }

        /// Counts against the PR, as GitHub's own "not successful" does.
        var isFailing: Bool { self == .failed || self == .cancelled }
        var isCompleted: Bool { self != .running }
    }

    let name: String
    /// The workflow a job belongs to; empty for commit statuses.
    let workflow: String
    let state: State
    let url: URL?
    /// Position in gh's list, so two checks with one name stay apart.
    let index: Int

    var id: Int { index }

    static func parse(_ item: [String: Any], index: Int) -> PullRequestCheck? {
        let type = item["__typename"] as? String ?? ""
        if type == "StatusContext" || (item["context"] != nil && item["name"] == nil) {
            guard let context = item["context"] as? String else { return nil }
            let state: State
            switch (item["state"] as? String ?? "").uppercased() {
            case "SUCCESS": state = .passed
            case "FAILURE", "ERROR": state = .failed
            default: state = .running   // PENDING, EXPECTED
            }
            return PullRequestCheck(name: context, workflow: "", state: state,
                                    url: (item["targetUrl"] as? String).flatMap(URL.init(string:)), index: index)
        }
        guard let name = item["name"] as? String else { return nil }
        let status = (item["status"] as? String ?? "").uppercased()
        let state: State
        if status != "COMPLETED" {
            state = .running
        } else {
            switch (item["conclusion"] as? String ?? "").uppercased() {
            case "SUCCESS": state = .passed
            case "CANCELLED": state = .cancelled
            case "SKIPPED": state = .skipped
            case "NEUTRAL", "STALE": state = .neutral
            default: state = .failed   // FAILURE, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE
            }
        }
        return PullRequestCheck(name: name, workflow: item["workflowName"] as? String ?? "", state: state,
                                url: (item["detailsUrl"] as? String).flatMap(URL.init(string:)), index: index)
    }

    static func parseRollup(_ value: Any?) -> [PullRequestCheck] {
        let items = value as? [[String: Any]] ?? []
        return items.enumerated().compactMap { parse($1, index: $0) }
    }
}

/// How a pull request's checks read at a glance, and in the list.
struct PullRequestChecksSummary: Equatable {
    enum Tone: Equatable { case passing, failing, pending, none, mixed }

    let total: Int
    let failing: Int
    let running: Int
    let passing: Int

    init(_ checks: [PullRequestCheck]) {
        total = checks.count
        failing = checks.filter { $0.state.isFailing }.count
        running = checks.filter { $0.state == .running }.count
        passing = checks.filter { [.passed, .skipped, .neutral].contains($0.state) }.count
    }

    var tone: Tone {
        if total == 0 { return .none }
        if failing > 0 { return .failing }
        if running > 0 { return .pending }
        if passing == total { return .passing }
        return .mixed
    }

    /// The status line beside the tabs: "2 of 5 failing".
    var text: String {
        switch tone {
        case .passing: "All checks passed"
        case .failing: "\(failing) of \(total) failing"
        case .pending: "\(running) of \(total) running"
        case .none: "No checks reported"
        case .mixed: "\(passing) of \(total) passing"
        }
    }

    /// The heading over the checks list.
    var heading: String {
        switch tone {
        case .passing: "All checks have passed"
        case .failing: "Some checks were not successful"
        case .pending, .mixed: "Some checks haven't completed yet"
        case .none: "No checks reported"
        }
    }

    /// Checks in the order they're worth reading: failing, then running,
    /// then the rest, each group in gh's order.
    static func ordered(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        func rank(_ check: PullRequestCheck) -> Int {
            check.state.isFailing ? 0 : check.state == .running ? 1 : 2
        }
        return checks.sorted { (rank($0), $0.index) < (rank($1), $1.index) }
    }
}

// MARK: - Repository

/// What the repository allows, from `gh repo view`.
struct PullRequestRepository: Equatable {
    static let fields = "nameWithOwner,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,viewerPermission,url"

    let nameWithOwner: String
    let url: URL?
    let allowedMethods: [PullRequestMergeMethod]
    /// ADMIN, MAINTAIN, WRITE, TRIAGE, READ.
    let viewerPermission: String

    static func parse(_ output: String) -> PullRequestRepository? {
        guard let json = PullRequestJSON.object(in: output),
              let name = json["nameWithOwner"] as? String else { return nil }
        var allowed: [PullRequestMergeMethod] = []
        if json["mergeCommitAllowed"] as? Bool ?? false { allowed.append(.merge) }
        if json["squashMergeAllowed"] as? Bool ?? false { allowed.append(.squash) }
        if json["rebaseMergeAllowed"] as? Bool ?? false { allowed.append(.rebase) }
        return PullRequestRepository(nameWithOwner: name, url: (json["url"] as? String).flatMap(URL.init(string:)),
                                     allowedMethods: allowed.isEmpty ? PullRequestMergeMethod.allCases : allowed,
                                     viewerPermission: (json["viewerPermission"] as? String ?? "").uppercased())
    }
}

/// A repository label, for the label picker.
struct PullRequestLabel: Equatable, Identifiable {
    let name: String
    /// Six hex digits, no "#".
    let color: String
    var id: String { name }

    static func parseList(_ output: String) -> [PullRequestLabel] {
        (PullRequestJSON.array(in: output) ?? []).compactMap(parse)
    }

    static func parse(_ json: [String: Any]) -> PullRequestLabel? {
        guard let name = json["name"] as? String else { return nil }
        return PullRequestLabel(name: name, color: json["color"] as? String ?? "888888")
    }
}

// MARK: - The pull request

struct PullRequestDetail: Equatable {
    /// The fields asked of `gh pr view`; all exist in gh 2.87.
    static let fields = [
        "number", "title", "url", "body", "state", "isDraft", "mergeable", "mergeStateStatus", "reviewDecision",
        "additions", "deletions", "changedFiles", "createdAt", "updatedAt", "mergedAt", "closedAt",
        "headRefName", "baseRefName", "author", "labels", "reviewRequests", "latestReviews", "statusCheckRollup",
        "comments", "reviews", "commits", "files", "autoMergeRequest", "headRepositoryOwner", "isCrossRepository",
    ].joined(separator: ",")

    enum Verdict: Equatable {
        case approved, changesRequested, commented, dismissed, pending

        init(_ state: String) {
            switch state.uppercased() {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "DISMISSED": self = .dismissed
            case "PENDING": self = .pending
            default: self = .commented
            }
        }

        var title: String {
            switch self {
            case .approved: "Approved"
            case .changesRequested: "Changes Requested"
            case .commented: "Commented"
            case .dismissed: "Dismissed"
            case .pending: "Pending"
            }
        }
    }

    struct Review: Equatable {
        let author: String
        let verdict: Verdict
        let body: String
        let submittedAt: Date?
    }

    struct Comment: Equatable {
        let author: String
        let body: String
        let createdAt: Date?
        let url: URL?
    }

    struct Commit: Equatable {
        let oid: String
        let headline: String
        let author: String
        let date: Date?
        var shortSha: String { String(oid.prefix(7)) }
    }

    struct File: Equatable {
        let path: String
        let additions: Int
        let deletions: Int
    }

    var number: Int
    var title: String
    var url: URL?
    var body: String
    /// OPEN, CLOSED or MERGED.
    var state: String
    var isDraft: Bool
    /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub hasn't worked it out yet).
    var mergeable: String
    /// BEHIND, BLOCKED, CLEAN, DIRTY, DRAFT, HAS_HOOKS, UNKNOWN, UNSTABLE.
    var mergeStateStatus: String
    var reviewDecision: String
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var createdAt: Date?
    var updatedAt: Date?
    var mergedAt: Date?
    var closedAt: Date?
    var headRefName: String
    var baseRefName: String
    var author: String
    var labels: [PullRequestLabel]
    /// Logins of people asked to review, and team names.
    var reviewRequests: [String]
    var latestReviews: [Review]
    var checks: [PullRequestCheck]
    var comments: [Comment]
    var reviews: [Review]
    var commits: [Commit]
    var files: [File]
    /// The method auto-merge will use, when it's armed.
    var autoMerge: PullRequestMergeMethod?
    var headOwner: String
    var isCrossRepository: Bool

    var tone: PullRequestTone { PullRequestTone(state: state, isDraft: isDraft) }
    var isOpen: Bool { state.uppercased() == "OPEN" }
    var checksSummary: PullRequestChecksSummary { PullRequestChecksSummary(checks) }
    var isBehind: Bool { mergeStateStatus.uppercased() == "BEHIND" }

    // MARK: Parsing

    /// `gh pr view --json …` output. LoginShell folds stderr into the same
    /// text, so the object is found wherever it starts.
    static func parse(_ output: String) -> PullRequestDetail? {
        guard let json = PullRequestJSON.object(in: output) else { return nil }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> PullRequestDetail? {
        guard let number = json["number"] as? Int else { return nil }
        let date = PullRequestJSON.date
        func login(_ value: Any?) -> String { (value as? [String: Any])?["login"] as? String ?? "ghost" }
        func reviews(_ value: Any?) -> [Review] {
            (value as? [[String: Any]] ?? []).map { item in
                Review(author: login(item["author"]), verdict: Verdict(item["state"] as? String ?? ""),
                       body: item["body"] as? String ?? "", submittedAt: date(item["submittedAt"]))
            }
        }
        let requests = (json["reviewRequests"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            // A user has a login; a team has a name (and a slug).
            (item["login"] as? String) ?? (item["name"] as? String) ?? (item["slug"] as? String)
        }
        let comments = (json["comments"] as? [[String: Any]] ?? []).map { item in
            Comment(author: login(item["author"]), body: item["body"] as? String ?? "",
                    createdAt: date(item["createdAt"]), url: (item["url"] as? String).flatMap(URL.init(string:)))
        }
        let commits = (json["commits"] as? [[String: Any]] ?? []).map { item in
            let authors = item["authors"] as? [[String: Any]] ?? []
            let who = authors.first.map { ($0["login"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0["name"] as? String ?? "" } ?? ""
            return Commit(oid: item["oid"] as? String ?? "", headline: item["messageHeadline"] as? String ?? "",
                          author: who, date: date(item["committedDate"]) ?? date(item["authoredDate"]))
        }
        let files = (json["files"] as? [[String: Any]] ?? []).map { item in
            File(path: item["path"] as? String ?? "", additions: item["additions"] as? Int ?? 0,
                 deletions: item["deletions"] as? Int ?? 0)
        }
        let autoMerge = (json["autoMergeRequest"] as? [String: Any]).map { request in
            PullRequestMergeMethod(github: request["mergeMethod"] as? String ?? "") ?? .merge
        }
        return PullRequestDetail(
            number: number,
            title: json["title"] as? String ?? "",
            url: (json["url"] as? String).flatMap(URL.init(string:)),
            body: json["body"] as? String ?? "",
            state: (json["state"] as? String ?? "OPEN").uppercased(),
            isDraft: json["isDraft"] as? Bool ?? false,
            mergeable: (json["mergeable"] as? String ?? "UNKNOWN").uppercased(),
            mergeStateStatus: (json["mergeStateStatus"] as? String ?? "UNKNOWN").uppercased(),
            reviewDecision: (json["reviewDecision"] as? String ?? "").uppercased(),
            additions: json["additions"] as? Int ?? 0,
            deletions: json["deletions"] as? Int ?? 0,
            changedFiles: json["changedFiles"] as? Int ?? files.count,
            createdAt: date(json["createdAt"]),
            updatedAt: date(json["updatedAt"]),
            mergedAt: date(json["mergedAt"]),
            closedAt: date(json["closedAt"]),
            headRefName: json["headRefName"] as? String ?? "",
            baseRefName: json["baseRefName"] as? String ?? "",
            author: login(json["author"]),
            labels: (json["labels"] as? [[String: Any]] ?? []).compactMap(PullRequestLabel.parse),
            reviewRequests: requests,
            latestReviews: reviews(json["latestReviews"]),
            checks: PullRequestCheck.parseRollup(json["statusCheckRollup"]),
            comments: comments,
            reviews: reviews(json["reviews"]),
            commits: commits,
            files: files,
            autoMerge: autoMerge,
            headOwner: login(json["headRepositoryOwner"]),
            isCrossRepository: json["isCrossRepository"] as? Bool ?? false)
    }

    // MARK: Reviewers

    /// One person on the Reviewers row: asked and waiting, or their latest
    /// verdict. Someone asked again after reviewing reads as asked.
    struct Reviewer: Equatable, Identifiable {
        let login: String
        /// nil while the review is requested and not yet given.
        let verdict: Verdict?
        var id: String { login }
    }

    var reviewers: [Reviewer] {
        var result = reviewRequests.map { Reviewer(login: $0, verdict: nil) }
        let asked = Set(reviewRequests.map { $0.lowercased() })
        for review in latestReviews where !asked.contains(review.author.lowercased()) && review.author != author {
            result.append(Reviewer(login: review.author, verdict: review.verdict))
        }
        return result
    }

    // MARK: Conversation

    /// What's said on the PR, oldest first: conversation comments and
    /// reviews with something written in them.
    var conversation: [TimelineItem] {
        timeline(newestFirst: false).filter {
            switch $0.kind {
            case .comment: true
            case .review: !$0.body.isEmpty
            default: false
            }
        }
    }

    // MARK: Timeline

    struct TimelineItem: Equatable, Identifiable {
        enum Kind: Equatable {
            case opened, commit(sha: String), comment, review(Verdict), merged, closed
        }
        let kind: Kind
        let author: String
        let text: String
        let body: String
        let date: Date?
        /// Order among events at the same moment, so Opened stays first.
        let sequence: Int
        var id: Int { sequence }
    }

    /// Everything that happened, in time order. A merged PR is also closed;
    /// only the merge is shown for it. A review that's only a container for
    /// inline comments (commented, nothing written) is left out: it says
    /// nothing on its own.
    func timeline(newestFirst: Bool) -> [TimelineItem] {
        var items: [TimelineItem] = []
        func add(_ kind: TimelineItem.Kind, _ author: String, _ text: String, _ body: String = "", _ date: Date?) {
            items.append(TimelineItem(kind: kind, author: author, text: text, body: body, date: date, sequence: items.count))
        }
        add(.opened, author, "Opened", "", createdAt)
        for commit in commits {
            add(.commit(sha: commit.oid), commit.author, commit.headline, "", commit.date)
        }
        for review in reviews where !(review.verdict == .commented && review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            add(.review(review.verdict), review.author, review.verdict.title, review.body, review.submittedAt)
        }
        for comment in comments {
            add(.comment, comment.author, Self.firstLines(comment.body), comment.body, comment.createdAt)
        }
        if state == "MERGED" {
            add(.merged, "", "Merged", "", mergedAt ?? closedAt)
        } else if state == "CLOSED" {
            add(.closed, "", "Closed", "", closedAt)
        }
        let sorted = items.sorted { a, b in
            let (x, y) = (a.date ?? .distantPast, b.date ?? .distantPast)
            return x == y ? a.sequence < b.sequence : x < y
        }
        return newestFirst ? sorted.reversed() : sorted
    }

    /// The first couple of lines of a comment, for a timeline row.
    static func firstLines(_ text: String, lines: Int = 2, limit: Int = 160) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .joined(separator: " ")
        return kept.count > limit ? String(kept.prefix(limit - 1)) + "…" : kept
    }

    // MARK: Primary control

    /// The one button (or badge) at the top right, after T3 Code's.
    enum Primary: Equatable {
        case merged
        case closed
        case resolveConflicts
        case readyForReview
        /// Auto-merge is armed and will use this method.
        case autoMergeArmed(PullRequestMergeMethod)
        /// Checks haven't passed: offer to merge when they do.
        case autoMerge(PullRequestMergeMethod)
        case merge(PullRequestMergeMethod)
    }

    func primary(method: PullRequestMergeMethod) -> Primary {
        switch state {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: break
        }
        if mergeable == "CONFLICTING" { return .resolveConflicts }
        if isDraft { return .readyForReview }
        if let autoMerge { return .autoMergeArmed(autoMerge) }
        switch checksSummary.tone {
        case .passing, .none: return .merge(method)
        case .failing, .pending, .mixed: return .autoMerge(method)
        }
    }

    // MARK: Prompts for the agent

    func resolveConflictsPrompt() -> String {
        "Resolve the merge conflicts in PR #\(number) (\(headRefName)) against \(baseRefName). "
            + "Merge or rebase \(baseRefName) into the branch as this repository usually does, fix each conflict "
            + "keeping both sides' intent, run the tests, and tell me what you changed. Don't push unless I ask."
    }

    func askPrompt() -> String {
        "I'm looking at PR #\(number) \"\(title)\" (\(headRefName) into \(baseRefName)). "
            + "Read it with gh pr view \(number) and gh pr diff \(number), then I'll ask you about it."
    }

    func explainPrompt() -> String {
        "Explain PR #\(number) \"\(title)\". Read it with gh pr view \(number) and gh pr diff \(number), "
            + "then walk me through the diff: what it changes and why, in a sensible reading order, "
            + "and which parts deserve a close read."
    }

    static func createPrompt(branch: String?) -> String {
        let on = branch.map { " (\($0))" } ?? ""
        return "Open a pull request for this branch\(on). Push it if it isn't pushed yet, write a clear title "
            + "and a description of what changed and why, and create it with gh pr create. Tell me the link."
    }
}

// MARK: - The list

/// One row of the Pull requests plane, from `gh pr list`.
struct PullRequestSummary: Equatable, Identifiable {
    static let fields = "number,title,author,isDraft,state,headRefName,updatedAt,additions,deletions,statusCheckRollup,reviewDecision"

    let number: Int
    let title: String
    let author: String
    let isDraft: Bool
    let state: String
    let headRefName: String
    let updatedAt: Date?
    let additions: Int
    let deletions: Int
    let checks: PullRequestChecksSummary
    let reviewDecision: String

    var id: Int { number }
    var tone: PullRequestTone { PullRequestTone(state: state, isDraft: isDraft) }

    static func parseList(_ output: String) -> [PullRequestSummary]? {
        guard let items = PullRequestJSON.array(in: output) else { return nil }
        return items.compactMap { json in
            guard let number = json["number"] as? Int else { return nil }
            return PullRequestSummary(
                number: number,
                title: json["title"] as? String ?? "",
                author: (json["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                isDraft: json["isDraft"] as? Bool ?? false,
                state: (json["state"] as? String ?? "OPEN").uppercased(),
                headRefName: json["headRefName"] as? String ?? "",
                updatedAt: PullRequestJSON.date(json["updatedAt"]),
                additions: json["additions"] as? Int ?? 0,
                deletions: json["deletions"] as? Int ?? 0,
                checks: PullRequestChecksSummary(PullRequestCheck.parseRollup(json["statusCheckRollup"])),
                reviewDecision: (json["reviewDecision"] as? String ?? "").uppercased())
        }
    }
}

// MARK: - Why gh failed

/// What went wrong running gh, and what to do about it.
enum PullRequestLoadFailure: Equatable {
    /// The branch has no pull request: an empty state, not an error.
    case noPullRequest
    case ghMissing
    case signedOut
    case notRepository
    case other(String)

    static func classify(status: Int32, output: String) -> PullRequestLoadFailure {
        let text = output.lowercased()
        if text.contains("no pull requests found") { return .noPullRequest }
        if status == 127 || text.contains("command not found: gh") || text.contains("gh: command not found")
            || text.contains("no such file or directory: gh") {
            return .ghMissing
        }
        if text.contains("gh auth login") || text.contains("not logged in") || text.contains("authentication required") {
            return .signedOut
        }
        if text.contains("not a git repository") || text.contains("no git remotes")
            || text.contains("none of the git remotes") || text.contains("could not determine base repo") {
            return .notRepository
        }
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return .other(line ?? "gh exited with status \(status)")
    }

    var title: String {
        switch self {
        case .noPullRequest: "This branch has no pull request yet."
        case .ghMissing: "The GitHub CLI isn't installed."
        case .signedOut: "The GitHub CLI isn't signed in."
        case .notRepository: "This folder isn't a GitHub repository."
        case .other: "Couldn't read the pull request."
        }
    }

    /// The exact thing to do next.
    var remedy: String {
        switch self {
        case .noPullRequest: "Open one to see its checks, reviews and diff here."
        case .ghMissing: "Install the GitHub CLI: brew install gh"
        case .signedOut: "Sign in with gh auth login"
        case .notRepository: "Pull requests show for folders cloned from GitHub."
        case .other(let detail): detail
        }
    }

    /// The command in the remedy, to copy.
    var command: String? {
        switch self {
        case .ghMissing: "brew install gh"
        case .signedOut: "gh auth login"
        default: nil
        }
    }
}

// MARK: - JSON in gh's output

enum PullRequestJSON {
    /// The first JSON object in `output`. Warnings gh prints to stderr land
    /// before it (LoginShell merges the two), so each `{` is tried in turn.
    static func object(in output: String) -> [String: Any]? {
        value(in: output, opening: "{") as? [String: Any]
    }

    static func array(in output: String) -> [[String: Any]]? {
        value(in: output, opening: "[") as? [[String: Any]]
    }

    private static func value(in output: String, opening: Character) -> Any? {
        // Anything after the value (a trailing warning) is cut at its last
        // closing bracket.
        guard let end = output.lastIndex(of: opening == "{" ? "}" : "]") else { return nil }
        var start = output.startIndex
        for _ in 0..<8 {
            guard let index = output[start..<end].firstIndex(of: opening) else { return nil }
            if let value = try? JSONSerialization.jsonObject(with: Data(output[index...end].utf8)) { return value }
            start = output.index(after: index)
        }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// "1h ago", "just now".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard date != nil else { return "" }
        let age = WorkspaceActivity.ageLabel(since: date, now: now)
        return age == "now" ? "just now" : age + " ago"
    }
}
