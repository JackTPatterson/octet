import AppKit
import Foundation

/// The pull request plane's data and actions. Everything goes through the
/// GitHub CLI (`gh` owns sign-in and which repository a folder is), run off
/// the main thread through the login shell so it finds the same `gh` a
/// terminal would.
@MainActor
final class PullRequestPlaneModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(PullRequestLoadFailure)
    }

    /// What's in the review composer's verdict picker; the REST event too,
    /// for a review that carries line comments.
    typealias ReviewVerdict = PullRequestReviewEvent

    /// The line comment being written under a diff line.
    struct LineDraft: Equatable {
        let anchor: PullRequestLineAnchor
        /// The line's code, for the agent's prompt.
        let code: String
        var text = ""
    }

    let directory: String
    /// "owner/name" when the PR lives in another repository than
    /// `directory`'s (the Pull Requests page): every gh call then names it
    /// with `-R`. Nil keeps the folder's own repository, as before.
    let repo: String?
    /// The PR asked for; nil follows whatever branch is checked out.
    private(set) var requestedNumber: Int?

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var repository: PullRequestRepository?
    /// The repository's labels, read when the label picker first opens.
    @Published private(set) var repositoryLabels: [PullRequestLabel]?
    /// Who a review can be asked of, read when the reviewer picker first opens.
    @Published private(set) var reviewCandidates: [PullRequestReviewTarget]?
    /// The chain of open pull requests this one is part of; nil when alone.
    @Published private(set) var stack: PullRequestStack?
    /// What the last label, reviewer or reaction change got wrong, shown
    /// inline over the Summary tab until the next change or it's dismissed.
    @Published private(set) var actionError: String?
    /// The branch checked out in `directory`.
    @Published private(set) var currentBranch: String?
    /// `gh pr diff`, parsed; read the first time the Code tab is wanted.
    @Published private(set) var diffFiles: [ReviewDiff.File]?
    @Published private(set) var diffLoading = false
    @Published private(set) var refreshing = false
    /// Actions running now, by key ("merge", "ready", …), so their buttons
    /// can say so and not run twice.
    @Published private(set) var busy: Set<String> = []
    /// This PR's merge method, picked from the menu; in memory only.
    @Published private(set) var chosenMethod: PullRequestMergeMethod?

    // Drafts for the comment button's popover; they survive it closing.
    @Published var commentDraft = ""
    @Published var reviewDraft = ""
    @Published var reviewVerdict: ReviewVerdict = .comment

    // The Code tab's review layer, read with the diff.
    /// Your viewed marks and the PR's node id; nil until read, or when the
    /// read failed (the checkboxes then don't show).
    @Published private(set) var viewedState: PullRequestViewedState?
    /// Review comments already on the PR, by the line they sit on.
    @Published private(set) var reviewComments: [PullRequestLineAnchor: [PullRequestReviewComment]] = [:]
    /// Line comments held for the next review ("Add to Review").
    @Published private(set) var pendingComments: [PullRequestPendingComment] = []
    /// The line comment open under a line; one at a time, as in T3 Code.
    @Published var lineDraft: LineDraft?

    private var generation = 0
    /// Bumped when the PR changes, so a late answer for the old one is dropped.
    private var reviewLayerGeneration = 0
    private var timer: Timer?
    /// The diff's freshness: when the PR changes, it's read again.
    private var diffStamp: String?
    private var diffWanted = false
    /// What the stack was read for; it's read again when this changes.
    private var stackKey: String?

    static let pollInterval: TimeInterval = 60

    init(directory: String, number: Int?, repo: String? = nil) {
        self.directory = directory
        self.requestedNumber = number
        self.repo = repo
    }

    /// `-R owner/name` for gh's pr and label commands, when `repo` is set.
    private var repoFlag: [String] { repo.map { ["-R", $0] } ?? [] }

    /// Checking out switches `directory`'s branch, which only makes sense
    /// for a PR of that folder's own repository.
    var canCheckOut: Bool { repo == nil }

    /// The PR's number for gh: the one asked for, else the one found.
    private var target: String? { (requestedNumber ?? detail?.number).map(String.init) }

    // MARK: - Polling

    /// While the plane is on screen: read now, then every minute.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quietly: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Points the plane at another PR (the host reused it).
    func retarget(_ number: Int?) {
        guard number != requestedNumber else { return }
        requestedNumber = number
        detail = nil
        diffFiles = nil
        diffStamp = nil
        chosenMethod = nil
        stack = nil
        stackKey = nil
        actionError = nil
        resetReviewLayer()
        phase = .loading
        refresh()
    }

    func refresh(quietly: Bool = false) {
        #if DEBUG
        if Self.debugSample { applySample(); return }
        #endif
        generation += 1
        let generation = self.generation, directory = self.directory
        let number = requestedNumber.map(String.init)
        let needsRepository = repository == nil || !quietly
        let repoFlag = self.repoFlag, otherRepository = self.repo
        if !quietly { refreshing = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let view = LoginShell.run(["gh", "pr", "view"] + (number.map { [$0] } ?? []) + repoFlag
                                      + ["--json", PullRequestDetail.fields], in: directory)
            // Another repository's PR is never the branch checked out here.
            let branch = otherRepository == nil
                ? LoginShell.run(["git", "branch", "--show-current"], in: directory)
                : LoginShell.Result(status: 1, output: "")
            let repo = needsRepository
                ? LoginShell.run(["gh", "repo", "view"] + (otherRepository.map { [$0] } ?? [])
                                 + ["--json", PullRequestRepository.fields], in: directory) : nil
            let parsed = view.status == 0 ? PullRequestDetail.parse(view.output) : nil
            let repository = repo.flatMap { $0.status == 0 ? PullRequestRepository.parse($0.output) : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == generation else { return }
                    self.refreshing = false
                    self.currentBranch = branch.status == 0 && !branch.output.isEmpty ? branch.output : nil
                    if let repository, repository != self.repository {
                        self.repository = repository
                        // The Code tab opened before the repository was known.
                        if self.diffWanted, self.viewedState == nil { self.loadReviewLayer() }
                    }
                    if let parsed {
                        self.apply(parsed)
                        self.loadStack(force: !quietly)
                    } else {
                        let failure = view.status == 0
                            ? PullRequestLoadFailure.other("gh's answer couldn't be read.")
                            : PullRequestLoadFailure.classify(status: view.status, output: view.output)
                        // A hiccup (offline, rate limit) keeps what's shown;
                        // only a real answer replaces it.
                        if self.detail != nil, case .other = failure {
                            if !quietly { ToastCenter.shared.fail(nil, "Couldn't refresh the pull request", detail: failure.remedy) }
                            return
                        }
                        self.detail = nil
                        self.diffFiles = nil
                        self.phase = .failed(failure)
                    }
                }
            }
        }
    }

    private func apply(_ parsed: PullRequestDetail) {
        if detail?.number != parsed.number {
            diffFiles = nil
            diffStamp = nil
            chosenMethod = nil
            // Another PR (the branch moved): its comments and marks aren't these.
            if detail != nil { resetReviewLayer() }
        }
        if parsed != detail { detail = parsed }
        if phase != .loaded { phase = .loaded }
        #if DEBUG
        runDebugActions()
        #endif
        let stamp = "\(parsed.number)·\(parsed.updatedAt?.timeIntervalSince1970 ?? 0)·\(parsed.additions)·\(parsed.deletions)"
        if diffStamp != nil, diffStamp != stamp {
            diffFiles = nil
            if diffWanted { loadDiff() }
        }
    }

    // MARK: - Diff

    /// Reads the diff once it's wanted (the Code tab hovered or shown).
    func loadDiff() {
        diffWanted = true
        guard diffFiles == nil, !diffLoading, let number = target, let detail else { return }
        diffLoading = true
        loadReviewLayer()
        let directory = self.directory, repoFlag = self.repoFlag
        let stamp = "\(detail.number)·\(detail.updatedAt?.timeIntervalSince1970 ?? 0)·\(detail.additions)·\(detail.deletions)"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "pr", "diff", number, "--color=never"] + repoFlag, in: directory)
            let files = result.status == 0 ? ReviewDiff.parse(result.output) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.diffLoading = false
                    if let files {
                        self.diffFiles = files
                        self.diffStamp = stamp
                    } else {
                        self.diffFiles = []
                        self.diffStamp = stamp
                        ToastCenter.shared.fail(nil, "Couldn't read the diff", detail: result.output)
                    }
                }
            }
        }
    }

    // MARK: - Viewed marks and review comments

    private func resetReviewLayer() {
        reviewLayerGeneration += 1
        viewedState = nil
        reviewComments = [:]
        pendingComments = []
        lineDraft = nil
    }

    /// Reads your viewed marks (GraphQL) and the review comments (REST)
    /// beside the diff. Both are read-only; a failure leaves the Code tab
    /// as it was without them, since the diff still reads fine.
    func loadReviewLayer() {
        guard let repository = repository?.nameWithOwner, let number = detail?.number else { return }
        let directory = self.directory, generation = reviewLayerGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let viewed = PullRequestViewedState.arguments(repository: repository, number: number)
                .map { LoginShell.run($0, in: directory) }
            let comments = LoginShell.run(PullRequestReviewComment.arguments(repository: repository, number: number), in: directory)
            let viewedState = viewed.flatMap { $0.status == 0 ? PullRequestViewedState.parse($0.output) : nil }
            let parsed = comments.status == 0 ? PullRequestReviewComment.parseList(comments.output) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.reviewLayerGeneration == generation else { return }
                    if let viewedState, viewedState != self.viewedState { self.viewedState = viewedState }
                    if let parsed {
                        let threads = PullRequestReviewComment.byAnchor(parsed)
                        if threads != self.reviewComments { self.reviewComments = threads }
                    }
                    #if DEBUG
                    self.runDebugCodeActions()
                    #endif
                }
            }
        }
    }

    func isViewed(_ path: String) -> Bool { viewedState?.isViewed(path) ?? false }

    /// Marks a file viewed on GitHub, or not. Shown at once; put back if
    /// GitHub refuses.
    func setViewed(_ path: String, _ viewed: Bool) {
        guard let state = viewedState, state.isViewed(path) != viewed else { return }
        let arguments = PullRequestViewedState.markArguments(pullRequestId: state.pullRequestId, path: path, viewed: viewed)
        viewedState?.viewed[path] = viewed
        perform("viewed:" + path, arguments, success: nil,
                failure: viewed ? "Couldn't mark \(path) viewed" : "Couldn't mark \(path) unviewed",
                refresh: false) { ok in
            if !ok { self.viewedState?.viewed[path] = !viewed }
        }
    }

    // MARK: - Line comments

    func beginLineComment(on line: ReviewDiff.Line, in path: String) {
        guard let anchor = PullRequestLineAnchor(path: path, line: line) else { return }
        if lineDraft?.anchor == anchor { return }
        lineDraft = LineDraft(anchor: anchor, code: line.text)
    }

    /// "Add to Review": held until the review is submitted.
    func addDraftToReview() {
        guard let draft = lineDraft, !Self.isBlank(draft.text) else { return }
        pendingComments.append(PullRequestPendingComment(anchor: draft.anchor, body: draft.text))
        lineDraft = nil
    }

    /// "Add to Agent": the prompt for the agent; the draft is done with.
    func takeDraftForAgent() -> String? {
        guard let draft = lineDraft, !Self.isBlank(draft.text), let number = detail?.number else { return nil }
        lineDraft = nil
        return PullRequestPendingComment.agentPrompt(number: number, anchor: draft.anchor, code: draft.code, text: draft.text)
    }

    func removePending(_ comment: PullRequestPendingComment) {
        pendingComments.removeAll { $0.id == comment.id }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Merge method

    var allowedMethods: [PullRequestMergeMethod] { repository?.allowedMethods ?? PullRequestMergeMethod.allCases }

    var mergeMethod: PullRequestMergeMethod {
        let last = UserDefaults.standard.string(forKey: PullRequestMergeMethod.defaultsKey).flatMap(PullRequestMergeMethod.init(rawValue:))
        return PullRequestMergeMethod.resolve(chosen: chosenMethod, last: last, allowed: allowedMethods) ?? .merge
    }

    func choose(_ method: PullRequestMergeMethod) {
        chosenMethod = method
        UserDefaults.standard.set(method.rawValue, forKey: PullRequestMergeMethod.defaultsKey)
    }

    var isCheckedOut: Bool {
        guard let detail, let currentBranch else { return false }
        return currentBranch == detail.headRefName
    }

    // MARK: - Actions

    /// Runs one gh command for the PR, says how it went, and reads the PR
    /// again so the plane shows the result.
    /// `input` is the command's stdin (a REST body). `refresh: false` skips
    /// reading the PR again, for actions it doesn't show (viewed marks).
    private func perform(_ key: String, _ arguments: [String], input: Data? = nil, success: String?, failure: String,
                         refresh: Bool = true, inline: Bool = false, then: ((Bool) -> Void)? = nil) {
        guard !busy.contains(key) else { return }
        if inline { actionError = nil }
        #if DEBUG
        if Self.debugSample {
            // The sample has no GitHub behind it: every change works, or
            // every one fails with OCTET_PR_SAMPLE_FAIL=1.
            let fails = ProcessInfo.processInfo.environment["OCTET_PR_SAMPLE_FAIL"] == "1"
            if fails { report(failure, "GitHub said no (sample).", inline: inline) } else if let success { ToastCenter.shared.succeed(nil, success) }
            then?(!fails)
            return
        }
        // Verification: write the command instead of running it, so every
        // action's real code path can be checked without touching GitHub.
        if let log = Self.dryRunLog {
            var line = arguments.map { $0.contains(" ") || $0.isEmpty ? "'\($0)'" : $0 }.joined(separator: " ")
            if let input { line += " <<< " + String(decoding: input, as: UTF8.self) }
            if let handle = FileHandle(forWritingAtPath: log) ?? {
                FileManager.default.createFile(atPath: log, contents: nil)
                return FileHandle(forWritingAtPath: log)
            }() {
                handle.seekToEndOfFile()
                handle.write(Data((key + "\t" + line + "\n").utf8))
                try? handle.close()
            }
            if let success { ToastCenter.shared.succeed(nil, success) }
            then?(true)
            return
        }
        #endif
        busy.insert(key)
        let directory = self.directory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(arguments, in: directory, input: input)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy.remove(key)
                    if result.status == 0 {
                        if let success { ToastCenter.shared.succeed(nil, success) }
                    } else {
                        self.report(failure, Self.lastLines(result.output), inline: inline)
                    }
                    then?(result.status == 0)
                    if refresh { self.refresh(quietly: true) }
                }
            }
        }
    }

    #if DEBUG
    /// "planes:pr:sample": a made-up stacked pull request with reactions,
    /// reviewers and labels, so the plane can be seen without a repository.
    static var debugSample = false

    private func applySample() {
        let sample = PullRequestSample.make(number: requestedNumber)
        repository = sample.repository
        repositoryLabels = sample.labels
        reviewCandidates = sample.candidates
        stack = sample.stack
        if detail != sample.detail { detail = sample.detail }
        phase = .loaded
        refreshing = false
    }

    /// OCTET_GH_DRY_RUN: a file that gh commands are written to instead of run.
    static let dryRunLog = ProcessInfo.processInfo.environment["OCTET_GH_DRY_RUN"]
    private static var debugActionsRan = false

    /// OCTET_GH_LIVE=1 with OCTET_PR_ACTIONS=<number>: on that PR only, the
    /// actions safe on a throwaway draft, for real, one after another.
    /// Merging is never among them, nor approving or requesting changes
    /// (GitHub refuses both from a PR's author).
    private func runLiveDebugActions(_ detail: PullRequestDetail) {
        Self.debugActionsRan = true
        let steps: [() -> Void] = [
            { self.markReady() },
            { self.convertToDraft() },
            { self.editTitle(detail.title + " (edited in Octet)") },
            { self.editBody("Edited from Octet's pull request plane.") },
            { self.commentDraft = "A comment from Octet's pull request plane."; self.postComment(closing: false) },
            { self.reviewVerdict = .comment; self.reviewDraft = "A review comment from Octet."; self.submitReview() },
            { self.close() },
            { self.reopen() },
            { self.checkOut() },
            { self.commentDraft = "Closing: this was a test."; self.postComment(closing: true) },
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 6) { step() }
        }
    }

    /// OCTET_PR_ACTIONS=<number> (dry run): every action, once, after
    /// the first read of that one pull request. Never without the dry run,
    /// and never on any other PR a restored plane happens to load first.
    private func runDebugActions() {
        guard !Self.debugActionsRan, let detail,
              ProcessInfo.processInfo.environment["OCTET_PR_ACTIONS"] == String(detail.number) else { return }
        if Self.dryRunLog == nil {
            if ProcessInfo.processInfo.environment["OCTET_GH_LIVE"] == "1" { runLiveDebugActions(detail) }
            return
        }
        Self.debugActionsRan = true
        for method in PullRequestMergeMethod.allCases {
            choose(method)
            merge()
        }
        enableAutoMerge()
        disableAutoMerge()
        markReady()
        convertToDraft()
        close()
        reopen()
        checkOut()
        updateBranch()
        editTitle(detail.title + " (edited)")
        editBody("A new description, with spaces.")
        addReviewer("@octocat")
        toggleLabel(PullRequestLabel(name: "needs review", color: "ededed"))
        commentDraft = "Looks good to me"
        postComment(closing: false)
        commentDraft = "Closing: superseded"
        postComment(closing: true)
        for verdict in [ReviewVerdict.approve, .requestChanges, .comment] {
            reviewVerdict = verdict
            reviewDraft = verdict == .approve ? "" : "Please rename this"
            submitReview()
        }
        createInBrowser()
        // The Code tab's actions need the viewed marks first.
        loadReviewLayer()
    }

    private static var debugCodeActionsRan = false

    /// The Code tab's writes, once its review layer has been read: each
    /// file's viewed mark flipped and flipped back, then a review carrying
    /// a comment on an added line and one on a removed line.
    private func runDebugCodeActions() {
        guard Self.dryRunLog != nil, !Self.debugCodeActionsRan,
              ProcessInfo.processInfo.environment["OCTET_PR_ACTIONS"] == "all",
              let state = viewedState, let path = state.viewed.keys.sorted().first else { return }
        Self.debugCodeActionsRan = true
        let was = state.isViewed(path)
        setViewed(path, !was)
        setViewed(path, was)
        beginLineComment(on: ReviewDiff.Line(kind: .added, oldNumber: nil, newNumber: 3, text: "added", index: 0), in: path)
        lineDraft?.text = "Why this line?"
        addDraftToReview()
        beginLineComment(on: ReviewDiff.Line(kind: .removed, oldNumber: 2, newNumber: nil, text: "removed", index: 1), in: path)
        lineDraft?.text = "Keep \"this\" one"
        addDraftToReview()
        reviewVerdict = .requestChanges
        reviewDraft = "Two line comments"
        submitReview()
    }
    #endif

    /// Says an action failed: inline over the Summary tab for the quick
    /// edits made in place, a toast for the rest.
    private func report(_ failure: String, _ detail: String, inline: Bool) {
        if inline {
            actionError = detail.isEmpty ? failure : failure + ": " + detail
        } else {
            ToastCenter.shared.fail(nil, failure, detail: detail)
        }
    }

    func dismissActionError() { actionError = nil }

    /// gh's last few lines: where it says what went wrong.
    private static func lastLines(_ output: String) -> String {
        output.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    private func pr(_ verb: String, _ extra: [String] = []) -> [String]? {
        target.map { ["gh", "pr", verb, $0] + repoFlag + extra }
    }

    func merge() {
        let method = mergeMethod
        guard let arguments = pr("merge", [method.flag]), let number = detail?.number else { return }
        perform("merge", arguments, success: "Merged #\(number)", failure: "Couldn't merge #\(number)")
    }

    func enableAutoMerge() {
        let method = mergeMethod
        guard let arguments = pr("merge", ["--auto", method.flag]) else { return }
        perform("auto", arguments, success: "Auto-merge enabled", failure: "Couldn't enable auto-merge")
    }

    func disableAutoMerge() {
        guard let arguments = pr("merge", ["--disable-auto"]) else { return }
        perform("auto", arguments, success: "Auto-merge disabled", failure: "Couldn't disable auto-merge")
    }

    func markReady() {
        guard let arguments = pr("ready") else { return }
        perform("ready", arguments, success: "Ready for review", failure: "Couldn't mark it ready for review")
    }

    func convertToDraft() {
        guard let arguments = pr("ready", ["--undo"]) else { return }
        perform("ready", arguments, success: "Converted to draft", failure: "Couldn't convert it to a draft")
    }

    func close() {
        guard let arguments = pr("close") else { return }
        perform("state", arguments, success: "Pull request closed", failure: "Couldn't close the pull request")
    }

    func reopen() {
        guard let arguments = pr("reopen") else { return }
        perform("state", arguments, success: "Pull request reopened", failure: "Couldn't reopen the pull request")
    }

    func checkOut() {
        guard let arguments = pr("checkout"), let detail else { return }
        perform("checkout", arguments, success: "Checked out \(detail.headRefName)", failure: "Couldn't check out the branch")
    }

    func updateBranch() {
        guard let arguments = pr("update-branch"), let detail else { return }
        perform("update", arguments, success: "Updated with \(detail.baseRefName)", failure: "Couldn't update the branch")
    }

    func editTitle(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != detail?.title, let arguments = pr("edit", ["--title", title]) else { return }
        detail?.title = title
        perform("title", arguments, success: nil, failure: "Couldn't rename the pull request")
    }

    func editBody(_ body: String) {
        guard body != detail?.body, let arguments = pr("edit", ["--body", body]) else { return }
        detail?.body = body
        perform("body", arguments, success: "Description saved", failure: "Couldn't save the description")
    }

    /// Asks for a review from a name typed in, when the picker's list doesn't have it.
    func addReviewer(_ login: String) {
        let login = login.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let target = PullRequestReviewTarget(name: login, isTeam: false)
        guard !login.isEmpty, !hasRequested(target) else { return }
        toggleReviewer(target)
    }

    func hasRequested(_ target: PullRequestReviewTarget) -> Bool {
        detail?.reviewTargets.contains { $0.id == target.id } ?? false
    }

    /// Asks for a review, or takes the request back. Shown at once; put
    /// back, with the reason, if GitHub refuses.
    func toggleReviewer(_ target: PullRequestReviewTarget) {
        guard let detail, let repository = repository?.nameWithOwner else { return }
        let adding = !hasRequested(target)
        let before = detail.reviewTargets
        let arguments = PullRequestReviewTarget.requestArguments(repository: repository, number: detail.number, adding: adding)
        setReviewTargets(PullRequestReviewTarget.toggled(before, target))
        perform("reviewer:" + target.id, arguments, input: PullRequestReviewTarget.requestBody(target),
                success: nil, failure: adding ? "Couldn't ask \(target.name) to review" : "Couldn't remove \(target.name)",
                inline: true) { ok in
            if !ok { self.setReviewTargets(before) }
        }
    }

    private func setReviewTargets(_ targets: [PullRequestReviewTarget]) {
        detail?.reviewTargets = targets
        detail?.reviewRequests = targets.map(\.name)
    }

    /// The people and teams a review can be asked of: collaborators, and
    /// the owner's teams when the owner is an organisation (that read
    /// fails for a person's repository, which just has no teams).
    func loadReviewCandidates() {
        guard reviewCandidates == nil, let repository = repository?.nameWithOwner else { return }
        let directory = self.directory
        let owner = repository.split(separator: "/").first.map(String.init) ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let users = LoginShell.run(["gh", "api", "repos/\(repository)/collaborators?per_page=100"], in: directory)
            let teams = LoginShell.run(["gh", "api", "orgs/\(owner)/teams?per_page=100"], in: directory)
            let found = (users.status == 0 ? PullRequestReviewTarget.parseUsers(users.output) : [])
                + (teams.status == 0 ? PullRequestReviewTarget.parseTeams(teams.output) : [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reviewCandidates = found
                    if users.status != 0 {
                        self.actionError = "Couldn't read who can review: " + Self.lastLines(users.output)
                    }
                }
            }
        }
    }

    func toggleLabel(_ label: PullRequestLabel) {
        guard let detail else { return }
        let has = detail.labels.contains { $0.name == label.name }
        guard let arguments = pr("edit", [has ? "--remove-label" : "--add-label", label.name]) else { return }
        let before = detail.labels
        // Shown at once; the refresh after confirms it, and a refusal puts it back.
        if has { self.detail?.labels.removeAll { $0.name == label.name } } else { self.detail?.labels.append(label) }
        perform("label:" + label.name, arguments, success: nil, failure: has ? "Couldn't remove \(label.name)" : "Couldn't add \(label.name)",
                inline: true) { ok in
            if !ok { self.detail?.labels = before }
        }
    }

    func loadLabels() {
        guard repositoryLabels == nil else { return }
        let directory = self.directory, repoFlag = self.repoFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "label", "list"] + repoFlag + ["--json", "name,color", "--limit", "200"], in: directory)
            let labels = PullRequestLabel.parseList(result.output)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.repositoryLabels = labels
                    if result.status != 0 { self.actionError = "Couldn't read the labels: " + Self.lastLines(result.output) }
                }
            }
        }
    }

    // MARK: - Reactions

    /// Adds your reaction to a comment or review, or takes it back. Shown
    /// at once; put back, with the reason, if GitHub refuses.
    func toggleReaction(_ reaction: PullRequestReaction, on subjectId: String) {
        guard let current = reactions(of: subjectId) else { return }
        let adding = !(current.first { $0.reaction == reaction }?.mine ?? false)
        setReactions(PullRequestReactionCount.toggled(current, reaction), of: subjectId)
        perform("reaction:" + subjectId + reaction.rawValue,
                PullRequestReactionCount.arguments(subjectId: subjectId, reaction: reaction, adding: adding),
                success: nil, failure: adding ? "Couldn't react \(reaction.emoji)" : "Couldn't take back \(reaction.emoji)",
                refresh: false, inline: true) { ok in
            if !ok { self.setReactions(current, of: subjectId) }
        }
    }

    private func reactions(of subjectId: String) -> [PullRequestReactionCount]? {
        if let comment = detail?.comments.first(where: { $0.nodeId == subjectId }) { return comment.reactions }
        return detail?.reviews.first { $0.nodeId == subjectId }?.reactions
    }

    private func setReactions(_ reactions: [PullRequestReactionCount], of subjectId: String) {
        if let index = detail?.comments.firstIndex(where: { $0.nodeId == subjectId }) {
            detail?.comments[index].reactions = reactions
        } else if let index = detail?.reviews.firstIndex(where: { $0.nodeId == subjectId }) {
            detail?.reviews[index].reactions = reactions
        }
    }

    // MARK: - Stack

    /// Reads the open pull requests to see whether this one is stacked on
    /// another. Read when the PR or its branches change, and on a manual refresh.
    func loadStack(force: Bool = false) {
        guard let detail else { return }
        let key = "\(detail.number)·\(detail.headRefName)·\(detail.baseRefName)"
        guard force || key != stackKey else { return }
        stackKey = key
        let directory = self.directory, repoFlag = self.repoFlag
        let current = PullRequestStackLayer(number: detail.number, title: detail.title, headRefName: detail.headRefName,
                                            baseRefName: detail.baseRefName, isDraft: detail.isDraft, state: detail.state)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "pr", "list", "--state", "open", "--limit", "100"] + repoFlag
                                        + ["--json", PullRequestStackLayer.fields], in: directory)
            let layers = result.status == 0 ? PullRequestStackLayer.parseList(result.output) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.stackKey == key else { return }
                    // A failed read keeps the stack shown; the header is a convenience.
                    guard let layers else { return }
                    let stack = PullRequestStack.build(current: current, among: layers)
                    if stack != self.stack { self.stack = stack }
                }
            }
        }
    }

    /// Opens another pull request of the stack in this plane.
    func show(_ layer: PullRequestStackLayer) { retarget(layer.number) }

    /// Posts the comment draft; with `closing`, closes the PR with it.
    func postComment(closing: Bool) {
        let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let arguments = closing ? pr("close", ["--comment", body]) : pr("comment", ["--body", body])
        guard let arguments else { return }
        perform("comment", arguments, success: closing ? "Pull request closed" : "Comment posted",
                failure: closing ? "Couldn't close the pull request" : "Couldn't post the comment") { ok in
            if ok { self.commentDraft = "" }
        }
    }

    /// Changes requested need a reason; a comment needs a body or a line
    /// comment; approving needs neither.
    var canSubmitReview: Bool {
        PullRequestReviewEvent.canSubmit(reviewVerdict, body: reviewDraft, lineComments: pendingComments.count)
    }

    /// With no line comments, `gh pr review`. With them, the REST reviews
    /// endpoint, which gh's review command can't feed line comments to.
    func submitReview() {
        guard canSubmitReview else { return }
        let body = reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let (flag, success): (String, String) = switch reviewVerdict {
        case .approve: ("--approve", "Pull request approved")
        case .requestChanges: ("--request-changes", "Changes requested")
        case .comment: ("--comment", "Review submitted")
        }
        let pending = pendingComments
        let done: (Bool) -> Void = { ok in
            guard ok else { return }
            self.reviewDraft = ""
            self.reviewVerdict = .comment
            // Only the ones sent: any added while it was on its way stay.
            let sent = Set(pending.map(\.id))
            self.pendingComments.removeAll { sent.contains($0.id) }
            if !pending.isEmpty { self.loadReviewLayer() }
        }
        if pending.isEmpty {
            guard let arguments = pr("review", [flag] + (body.isEmpty ? [] : ["--body", body])) else { return }
            perform("review", arguments, success: success, failure: "Couldn't submit the review", then: done)
        } else {
            guard let repository = repository?.nameWithOwner, let number = detail?.number else { return }
            perform("review", PullRequestReviewSubmission.arguments(repository: repository, number: number),
                    input: PullRequestReviewSubmission.body(event: reviewVerdict, body: body, comments: pending),
                    success: success, failure: "Couldn't submit the review", then: done)
        }
    }

    /// `gh pr create --web`: GitHub's own form, in the browser.
    func createInBrowser() {
        perform("create", ["gh", "pr", "create", "--web"], success: nil, failure: "Couldn't open GitHub")
    }

    // MARK: - Opening and copying

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.info("Copied \(what)")
    }
}
