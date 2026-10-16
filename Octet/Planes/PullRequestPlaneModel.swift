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

    /// What's in the review composer's verdict picker.
    enum ReviewVerdict: Hashable { case comment, approve, requestChanges }

    let directory: String
    /// The PR asked for; nil follows whatever branch is checked out.
    private(set) var requestedNumber: Int?

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var repository: PullRequestRepository?
    /// The repository's labels, read when the label picker first opens.
    @Published private(set) var repositoryLabels: [PullRequestLabel]?
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

    private var generation = 0
    private var timer: Timer?
    /// The diff's freshness: when the PR changes, it's read again.
    private var diffStamp: String?
    private var diffWanted = false

    static let pollInterval: TimeInterval = 60

    init(directory: String, number: Int?) {
        self.directory = directory
        self.requestedNumber = number
    }

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
        phase = .loading
        refresh()
    }

    func refresh(quietly: Bool = false) {
        generation += 1
        let generation = self.generation, directory = self.directory
        let number = requestedNumber.map(String.init)
        let needsRepository = repository == nil || !quietly
        if !quietly { refreshing = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let view = LoginShell.run(["gh", "pr", "view"] + (number.map { [$0] } ?? [])
                                      + ["--json", PullRequestDetail.fields], in: directory)
            let branch = LoginShell.run(["git", "branch", "--show-current"], in: directory)
            let repo = needsRepository
                ? LoginShell.run(["gh", "repo", "view", "--json", PullRequestRepository.fields], in: directory) : nil
            let parsed = view.status == 0 ? PullRequestDetail.parse(view.output) : nil
            let repository = repo.flatMap { $0.status == 0 ? PullRequestRepository.parse($0.output) : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == generation else { return }
                    self.refreshing = false
                    self.currentBranch = branch.status == 0 && !branch.output.isEmpty ? branch.output : nil
                    if let repository, repository != self.repository { self.repository = repository }
                    if let parsed {
                        self.apply(parsed)
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
        }
        if parsed != detail { detail = parsed }
        if phase != .loaded { phase = .loaded }
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
        let directory = self.directory
        let stamp = "\(detail.number)·\(detail.updatedAt?.timeIntervalSince1970 ?? 0)·\(detail.additions)·\(detail.deletions)"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "pr", "diff", number, "--color=never"], in: directory)
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
    private func perform(_ key: String, _ arguments: [String], success: String?, failure: String,
                         then: ((Bool) -> Void)? = nil) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        let directory = self.directory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(arguments, in: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy.remove(key)
                    if result.status == 0 {
                        if let success { ToastCenter.shared.succeed(nil, success) }
                    } else {
                        ToastCenter.shared.fail(nil, failure, detail: Self.lastLines(result.output))
                    }
                    then?(result.status == 0)
                    self.refresh(quietly: true)
                }
            }
        }
    }

    /// gh's last few lines: where it says what went wrong.
    private static func lastLines(_ output: String) -> String {
        output.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    private func pr(_ verb: String, _ extra: [String] = []) -> [String]? {
        target.map { ["gh", "pr", verb, $0] + extra }
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

    func addReviewer(_ login: String) {
        let login = login.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !login.isEmpty, let arguments = pr("edit", ["--add-reviewer", login]) else { return }
        perform("reviewer", arguments, success: "Asked \(login) to review", failure: "Couldn't add \(login) as a reviewer")
    }

    func toggleLabel(_ label: PullRequestLabel) {
        guard let detail else { return }
        let has = detail.labels.contains { $0.name == label.name }
        guard let arguments = pr("edit", [has ? "--remove-label" : "--add-label", label.name]) else { return }
        // Shown at once; the refresh after confirms it.
        if has { self.detail?.labels.removeAll { $0.name == label.name } } else { self.detail?.labels.append(label) }
        perform("label:" + label.name, arguments, success: nil, failure: has ? "Couldn't remove \(label.name)" : "Couldn't add \(label.name)")
    }

    func loadLabels() {
        guard repositoryLabels == nil else { return }
        let directory = self.directory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "label", "list", "--json", "name,color", "--limit", "200"], in: directory)
            let labels = PullRequestLabel.parseList(result.output)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.repositoryLabels = labels }
            }
        }
    }

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

    /// Changes requested need a reason; the other verdicts don't.
    var canSubmitReview: Bool {
        let body = reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return reviewVerdict == .approve || !body.isEmpty
    }

    func submitReview() {
        guard canSubmitReview else { return }
        let body = reviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let (flag, success): (String, String) = switch reviewVerdict {
        case .approve: ("--approve", "Pull request approved")
        case .requestChanges: ("--request-changes", "Changes requested")
        case .comment: ("--comment", "Review submitted")
        }
        guard let arguments = pr("review", [flag] + (body.isEmpty ? [] : ["--body", body])) else { return }
        perform("review", arguments, success: success, failure: "Couldn't submit the review") { ok in
            if ok {
                self.reviewDraft = ""
                self.reviewVerdict = .comment
            }
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
