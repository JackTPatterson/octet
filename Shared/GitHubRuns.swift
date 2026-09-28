import Foundation

/// A GitHub Actions run, as `gh run list --json` describes it.
struct CIRun: Equatable, Identifiable {
    enum State: Equatable { case queued, running, passed, failed, cancelled, skipped }

    let id: Int
    let workflow: String
    let title: String
    let status: String
    let conclusion: String
    let headSha: String
    let event: String
    let url: URL?
    let createdAt: Date?
    let updatedAt: Date?
    /// The jobs that failed, "job › step" where the step is known; read
    /// separately, and only for failed runs.
    var failedJobs: [String] = []

    var state: State {
        switch status.lowercased() {
        case "queued", "waiting", "requested", "pending": return .queued
        case "in_progress": return .running
        default: break
        }
        switch conclusion.lowercased() {
        case "success", "neutral": return .passed
        case "skipped": return .skipped
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    var isFinished: Bool { state != .queued && state != .running }
}

/// Where the runs for one commit stand, for the status bar's CI chip.
struct CIStatus: Equatable {
    enum Overall: Equatable { case running, passed, failed, cancelled }

    /// One run per workflow: the newest.
    var runs: [CIRun]
    /// The commit the runs are for.
    let sha: String
    /// False when HEAD has no runs yet (not pushed, or not started) and
    /// these are the branch's latest.
    let isHead: Bool

    var overall: Overall {
        let states = runs.map(\.state)
        if states.contains(where: { $0 == .queued || $0 == .running }) { return .running }
        if states.contains(.failed) { return .failed }
        if states.contains(.cancelled) { return .cancelled }
        return .passed
    }

    var finished: Int { runs.filter(\.isFinished).count }
    var failed: [CIRun] { runs.filter { $0.state == .failed } }
    var shortSha: String { String(sha.prefix(7)) }
}

enum GitHubRuns {
    /// The fields asked of `gh run list`.
    static let listFields = "databaseId,workflowName,displayTitle,status,conclusion,headSha,event,url,createdAt,updatedAt"

    static func parseRuns(_ data: Data) -> [CIRun] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { json in
            guard let id = json["databaseId"] as? Int, let sha = json["headSha"] as? String else { return nil }
            return CIRun(id: id,
                         workflow: json["workflowName"] as? String ?? "Workflow",
                         title: json["displayTitle"] as? String ?? "",
                         status: json["status"] as? String ?? "",
                         conclusion: json["conclusion"] as? String ?? "",
                         headSha: sha,
                         event: json["event"] as? String ?? "",
                         url: (json["url"] as? String).flatMap(URL.init(string:)),
                         createdAt: date(json["createdAt"]),
                         updatedAt: date(json["updatedAt"]))
        }
    }

    /// The runs worth showing for `head`: its own, else the newest commit's
    /// that has any, one per workflow. `runs` is newest first, as gh lists.
    static func status(runs: [CIRun], head: String?) -> CIStatus? {
        guard !runs.isEmpty else { return nil }
        let isHead = head.map { head in runs.contains { $0.headSha == head } } ?? false
        guard let sha = isHead ? head : runs.first?.headSha else { return nil }
        var seen = Set<String>()
        let latest = runs.filter { $0.headSha == sha && seen.insert($0.workflow).inserted }
        return CIStatus(runs: latest, sha: sha, isHead: isHead)
    }

    /// `gh run view <id> --json jobs`: the failed jobs, each with the step
    /// that failed when there is one.
    static func parseFailedJobs(_ data: Data) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let jobs = json["jobs"] as? [[String: Any]] else { return [] }
        let failures: Set<String> = ["failure", "timed_out", "startup_failure", "action_required"]
        return jobs.compactMap { job in
            guard let name = job["name"] as? String,
                  failures.contains((job["conclusion"] as? String ?? "").lowercased()) else { return nil }
            let step = (job["steps"] as? [[String: Any]])?
                .first { failures.contains(($0["conclusion"] as? String ?? "").lowercased()) }?["name"] as? String
            return step.map { "\(name) › \($0)" } ?? name
        }
    }

    /// What the agent is asked when CI fails: where to look, and to fix the
    /// cause rather than the symptom.
    static func fixPrompt(_ status: CIStatus, branch: String?) -> String {
        let failures = status.failed.map { run in
            run.failedJobs.isEmpty ? run.workflow : "\(run.workflow) (\(run.failedJobs.joined(separator: "; ")))"
        }
        let logs = status.failed.map { "gh run view \($0.id) --log-failed" }.joined(separator: " and ")
        let on = branch.map { " on \($0)" } ?? ""
        return "CI failed\(on) at \(status.shortSha): \(failures.joined(separator: ", ")). "
            + "Read the failure with \(logs), find the root cause and fix it, run the same checks locally, "
            + "and tell me what it was. Don't push unless I ask."
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
