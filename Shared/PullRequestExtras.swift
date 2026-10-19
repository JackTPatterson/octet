import Foundation

// The pull request plane's extras beyond the basics: who can be asked to
// review, reactions on comments, and stacked pull requests. Kept free of
// AppKit and SwiftUI so the tests can check every decision.

// MARK: - Reviewers

/// Someone, or a team, a review can be asked of.
struct PullRequestReviewTarget: Equatable, Identifiable, Hashable {
    let name: String
    let isTeam: Bool

    /// A user's login, or a team's slug.
    var id: String { (isTeam ? "team:" : "user:") + name.lowercased() }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    /// `repos/…/collaborators`: the people who can review.
    static func parseUsers(_ output: String) -> [PullRequestReviewTarget] {
        (PullRequestJSON.array(in: output) ?? []).compactMap {
            ($0["login"] as? String).map { PullRequestReviewTarget(name: $0, isTeam: false) }
        }
    }

    /// `orgs/…/teams`.
    static func parseTeams(_ output: String) -> [PullRequestReviewTarget] {
        (PullRequestJSON.array(in: output) ?? []).compactMap {
            ($0["slug"] as? String).map { PullRequestReviewTarget(name: $0, isTeam: true) }
        }
    }

    /// `reviewRequests` as gh gives them: a user has a login, a team a slug.
    static func parseRequests(_ items: [[String: Any]]) -> [PullRequestReviewTarget] {
        items.compactMap { item in
            if let login = item["login"] as? String { return PullRequestReviewTarget(name: login, isTeam: false) }
            guard let slug = (item["slug"] as? String) ?? (item["name"] as? String) else { return nil }
            return PullRequestReviewTarget(name: slug, isTeam: true)
        }
    }

    /// Asked for, or taken off, as the reviewers endpoint wants it.
    static func requestArguments(repository: String, number: Int, adding: Bool) -> [String] {
        ["gh", "api", "-X", adding ? "POST" : "DELETE", "repos/\(repository)/pulls/\(number)/requested_reviewers",
         "--input", "-"]
    }

    static func requestBody(_ target: PullRequestReviewTarget) -> Data {
        let key = target.isTeam ? "team_reviewers" : "reviewers"
        return (try? JSONSerialization.data(withJSONObject: [key: [target.name]])) ?? Data()
    }

    /// `requests` with `target` added or removed, for showing it at once.
    static func toggled(_ requests: [PullRequestReviewTarget], _ target: PullRequestReviewTarget) -> [PullRequestReviewTarget] {
        requests.contains(target) ? requests.filter { $0 != target } : requests + [target]
    }
}

// MARK: - Reactions

/// GitHub's eight reactions, by the name its API gives them.
enum PullRequestReaction: String, CaseIterable, Identifiable {
    case thumbsUp = "THUMBS_UP", thumbsDown = "THUMBS_DOWN", laugh = "LAUGH", hooray = "HOORAY"
    case confused = "CONFUSED", heart = "HEART", rocket = "ROCKET", eyes = "EYES"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .thumbsDown: "👎"
        case .laugh: "😄"
        case .hooray: "🎉"
        case .confused: "😕"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .eyes: "👀"
        }
    }

    var title: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .thumbsDown: "Thumbs down"
        case .laugh: "Laugh"
        case .hooray: "Hooray"
        case .confused: "Confused"
        case .heart: "Heart"
        case .rocket: "Rocket"
        case .eyes: "Eyes"
        }
    }
}

/// One reaction on a comment: how many, and whether one is yours.
struct PullRequestReactionCount: Equatable, Identifiable {
    let reaction: PullRequestReaction
    var count: Int
    var mine: Bool
    var id: String { reaction.rawValue }

    /// gh's `reactionGroups`; empty groups are left out.
    static func parse(_ value: Any?) -> [PullRequestReactionCount] {
        let groups = (value as? [[String: Any]] ?? []).compactMap { item -> PullRequestReactionCount? in
            guard let reaction = (item["content"] as? String).flatMap(PullRequestReaction.init(rawValue:)) else { return nil }
            let count = (item["users"] as? [String: Any])?["totalCount"] as? Int ?? 0
            return count > 0 ? PullRequestReactionCount(reaction: reaction, count: count, mine: item["viewerHasReacted"] as? Bool ?? false) : nil
        }
        return sorted(groups)
    }

    /// In GitHub's order, not the order they arrived in.
    private static func sorted(_ groups: [PullRequestReactionCount]) -> [PullRequestReactionCount] {
        let order = PullRequestReaction.allCases
        return groups.sorted { (order.firstIndex(of: $0.reaction) ?? 0) < (order.firstIndex(of: $1.reaction) ?? 0) }
    }

    /// Your reaction added, or taken back: the counts as they'd read after.
    static func toggled(_ groups: [PullRequestReactionCount], _ reaction: PullRequestReaction) -> [PullRequestReactionCount] {
        var result = groups
        if let index = result.firstIndex(where: { $0.reaction == reaction }) {
            if result[index].mine {
                result[index].count -= 1
                result[index].mine = false
                if result[index].count <= 0 { result.remove(at: index) }
            } else {
                result[index].count += 1
                result[index].mine = true
            }
        } else {
            result.append(PullRequestReactionCount(reaction: reaction, count: 1, mine: true))
        }
        return sorted(result)
    }

    /// GraphQL's add/remove mutations take the comment's node id, which
    /// covers conversation comments and reviews alike.
    static func arguments(subjectId: String, reaction: PullRequestReaction, adding: Bool) -> [String] {
        let verb = adding ? "addReaction" : "removeReaction"
        let query = "mutation($id:ID!,$content:ReactionContent!){\(verb)(input:{subjectId:$id,content:$content}){reaction{content}}}"
        return ["gh", "api", "graphql", "-f", "query=" + query, "-f", "id=" + subjectId, "-f", "content=" + reaction.rawValue]
    }
}

// MARK: - Stacks

/// One pull request in a stack.
struct PullRequestStackLayer: Equatable, Identifiable {
    let number: Int
    let title: String
    let headRefName: String
    let baseRefName: String
    let isDraft: Bool
    let state: String
    var id: Int { number }
    var tone: PullRequestTone { PullRequestTone(state: state, isDraft: isDraft) }

    static let fields = "number,title,headRefName,baseRefName,isDraft,state"

    static func parseList(_ output: String) -> [PullRequestStackLayer]? {
        guard let items = PullRequestJSON.array(in: output) else { return nil }
        return items.compactMap { json in
            guard let number = json["number"] as? Int else { return nil }
            return PullRequestStackLayer(
                number: number, title: json["title"] as? String ?? "",
                headRefName: json["headRefName"] as? String ?? "", baseRefName: json["baseRefName"] as? String ?? "",
                isDraft: json["isDraft"] as? Bool ?? false, state: (json["state"] as? String ?? "OPEN").uppercased())
        }
    }
}

/// A chain of open pull requests, each based on the one before's branch.
struct PullRequestStack: Equatable {
    /// Nearest the trunk first.
    let layers: [PullRequestStackLayer]
    /// Where the pull request being looked at sits in `layers`.
    let index: Int

    var size: Int { layers.count }
    var position: Int { index + 1 }
    var current: PullRequestStackLayer { layers[index] }
    var below: PullRequestStackLayer? { index > 0 ? layers[index - 1] : nil }
    var above: PullRequestStackLayer? { index + 1 < layers.count ? layers[index + 1] : nil }
    /// The branch the bottom layer lands on.
    var trunk: String { layers[0].baseRefName }

    /// The stack `current` is part of, among the repository's open pull
    /// requests: walked down through whichever PR's head is its base, and up
    /// through the PRs based on its head (the oldest when several are).
    /// Nil when it stands alone.
    static func build(current: PullRequestStackLayer, among others: [PullRequestStackLayer]) -> PullRequestStack? {
        let open = others.filter { $0.state == "OPEN" && $0.number != current.number }
        var chain = [current]
        var seen: Set<Int> = [current.number]
        var bottom = current
        while let parent = open.filter({ $0.headRefName == bottom.baseRefName && !seen.contains($0.number) })
            .min(by: { $0.number < $1.number }) {
            chain.insert(parent, at: 0)
            seen.insert(parent.number)
            bottom = parent
        }
        var top = current
        while let child = open.filter({ $0.baseRefName == top.headRefName && !seen.contains($0.number) })
            .min(by: { $0.number < $1.number }) {
            chain.append(child)
            seen.insert(child.number)
            top = child
        }
        guard chain.count > 1, let index = chain.firstIndex(where: { $0.number == current.number }) else { return nil }
        return PullRequestStack(layers: chain, index: index)
    }
}
