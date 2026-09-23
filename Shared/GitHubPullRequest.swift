import Foundation

/// The small amount of GitHub state useful in a project header. `gh` owns
/// authentication and repository resolution; Octet only parses its JSON.
struct GitHubPullRequest: Equatable {
    enum Checks: Equatable { case passing, pending, failing, none }

    let number: Int
    let title: String
    let state: String
    let url: URL
    let isDraft: Bool
    let reviewDecision: String?
    let checks: Checks

    static func parse(_ data: Data) -> GitHubPullRequest? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = json["number"] as? Int,
              let title = json["title"] as? String,
              let rawURL = json["url"] as? String,
              let url = URL(string: rawURL) else { return nil }
        let rollup = json["statusCheckRollup"] as? [[String: Any]] ?? []
        return GitHubPullRequest(number: number, title: title,
                                 state: (json["state"] as? String ?? "OPEN").uppercased(),
                                 url: url, isDraft: json["isDraft"] as? Bool ?? false,
                                 reviewDecision: (json["reviewDecision"] as? String)?.uppercased(),
                                 checks: checkState(rollup))
    }

    private static func checkState(_ checks: [[String: Any]]) -> Checks {
        guard !checks.isEmpty else { return .none }
        let values = checks.flatMap { item in
            [item["conclusion"], item["state"], item["status"]]
                .compactMap { ($0 as? String)?.uppercased() }
        }
        let failures: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"]
        if values.contains(where: failures.contains) { return .failing }
        let pending: Set<String> = ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
        if values.contains(where: pending.contains) { return .pending }
        return .passing
    }

    var statusText: String {
        if isDraft { return "Draft" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if checks == .failing { return "Checks failing" }
        if checks == .pending { return "Checks running" }
        if reviewDecision == "APPROVED" { return "Approved" }
        return state == "MERGED" ? "Merged" : state.capitalized
    }
}
