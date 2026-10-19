#if DEBUG
import Foundation

/// Made-up pull requests for "planes:pr:sample", to see the plane's extras
/// (labels, reviewers, reactions, the stack) without a repository or gh.
enum PullRequestSample {
    struct Result {
        let detail: PullRequestDetail
        let repository: PullRequestRepository
        let labels: [PullRequestLabel]
        let candidates: [PullRequestReviewTarget]
        let stack: PullRequestStack?
    }

    static let layers = [
        PullRequestStackLayer(number: 41, title: "Add the sync engine", headRefName: "sync-engine", baseRefName: "main",
                              isDraft: false, state: "OPEN"),
        PullRequestStackLayer(number: 42, title: "Retry failed pushes", headRefName: "sync-retry", baseRefName: "sync-engine",
                              isDraft: false, state: "OPEN"),
        PullRequestStackLayer(number: 43, title: "Show sync status in the toolbar", headRefName: "sync-status",
                              baseRefName: "sync-retry", isDraft: true, state: "OPEN"),
    ]

    static func make(number: Int?) -> Result {
        let layer = layers.first { $0.number == number } ?? layers[1]
        let json = """
        {"number":\(layer.number),"title":"\(layer.title)","url":"https://github.com/acme/app/pull/\(layer.number)",
         "body":"Part of the sync stack.","state":"OPEN","isDraft":\(layer.isDraft),"mergeable":"MERGEABLE",
         "mergeStateStatus":"CLEAN","reviewDecision":"","additions":120,"deletions":14,"changedFiles":4,
         "createdAt":"2026-10-15T10:00:00Z","updatedAt":"2026-10-18T09:00:00Z",
         "headRefName":"\(layer.headRefName)","baseRefName":"\(layer.baseRefName)","author":{"login":"jack"},
         "labels":[{"name":"sync","color":"1d76db"}],
         "reviewRequests":[{"__typename":"User","login":"octocat"},{"__typename":"Team","name":"Core","slug":"core"}],
         "latestReviews":[],"statusCheckRollup":[],"commits":[],"files":[],
         "comments":[
          {"id":"IC_1","author":{"login":"octocat"},"body":"Nice, the backoff reads well.","createdAt":"2026-10-16T12:00:00Z",
           "reactionGroups":[{"content":"THUMBS_UP","users":{"totalCount":3},"viewerHasReacted":true},
                             {"content":"ROCKET","users":{"totalCount":1},"viewerHasReacted":false},
                             {"content":"EYES","users":{"totalCount":0},"viewerHasReacted":false}]},
          {"id":"IC_2","author":{"login":"hubot"},"body":"Can we cap the retries?","createdAt":"2026-10-17T12:00:00Z",
           "reactionGroups":[]}],
         "reviews":[],"headRepositoryOwner":{"login":"acme"},"isCrossRepository":false}
        """
        let repository = PullRequestRepository.parse(#"{"nameWithOwner":"acme/app","url":"https://github.com/acme/app","mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":false,"viewerPermission":"WRITE"}"#)!
        let labels = PullRequestLabel.parseList(#"[{"name":"bug","color":"d73a4a"},{"name":"sync","color":"1d76db"},{"name":"documentation","color":"0075ca"},{"name":"good first issue","color":"7057ff"},{"name":"wontfix","color":"ffffff"}]"#)
        let candidates = [("octocat", false), ("hubot", false), ("monalisa", false), ("core", true), ("design", true)]
            .map { PullRequestReviewTarget(name: $0.0, isTeam: $0.1) }
        let detail = PullRequestDetail.parse(json)!
        let stack = PullRequestStack.build(current: layer, among: layers)
        return Result(detail: detail, repository: repository, labels: labels, candidates: candidates, stack: stack)
    }
}
#endif
