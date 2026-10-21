import SwiftUI

/// The pieces CI, Issues and Containers share, so the three read like the
/// Pull Requests list: a 36pt header with a count, one filter row, flat
/// icon-led rows that open in place, and key/value details on a quiet card.
enum ServiceTone {
    case good, bad, pending, merged, idle

    var color: Color {
        switch self {
        case .good: Theme.success
        case .bad: Theme.danger
        case .pending: PullRequestStyle.amber
        case .merged: PullRequestStyle.violet
        case .idle: Theme.textTertiary
        }
    }
}

struct ServiceHeader<Actions: View>: View {
    let title: String
    var count: String?
    var loading = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if let count {
                Text(count).font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small).scaleEffect(0.8) }
            actions()
        }
        .padding(.horizontal, PullRequestStyle.horizontalPadding)
        .frame(height: 36)
    }
}

/// A single row. Tapping opens `detail` beneath it; the chevron is implied
/// by the hover fill and the open row keeping its fill.
struct ServiceRow<Detail: View, Trailing: View>: View {
    let icon: String
    let tone: ServiceTone
    let title: String
    let subtitle: String
    @Binding var open: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var detail: () -> Detail
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                MotionPreferences.shared.perform(.sidebar) { open.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    OctetIcon(icon, size: 14).foregroundStyle(tone.color).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.tail)
                        Text(subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    trailing().padding(.top, 1)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered || open ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("\(title), \(subtitle)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                detail()
                    .padding(.leading, 30).padding(.trailing, 8).padding(.top, 4).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension ServiceRow where Trailing == EmptyView {
    init(icon: String, tone: ServiceTone, title: String, subtitle: String, open: Binding<Bool>,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.init(icon: icon, tone: tone, title: title, subtitle: subtitle, open: open, trailing: { EmptyView() }, detail: detail)
    }
}

/// The filter field with a segmented scope beside it, or beneath it when
/// the panel is narrow.
struct ServiceFilterBar<Value: Hashable>: View {
    let placeholder: String
    @Binding var query: String
    @Binding var scope: Value
    let scopes: [(value: Value, title: String)]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                OctetTextField(placeholder: placeholder, text: $query).frame(minWidth: 140)
                OctetSegmented(selection: $scope, items: scopes)
            }
            VStack(alignment: .leading, spacing: 8) {
                OctetTextField(placeholder: placeholder, text: $query)
                OctetSegmented(selection: $scope, items: scopes)
            }
        }
        .padding(.horizontal, PullRequestStyle.horizontalPadding).padding(.bottom, 8)
    }
}

/// A small status word at a row's right edge.
struct ServiceStatusLabel: View {
    let text: String
    let tone: ServiceTone
    var body: some View {
        Text(text).font(Theme.captionFont).foregroundStyle(tone == .idle ? Theme.textTertiary : tone.color).lineLimit(1)
    }
}

/// Facts about the open row, label left and value right, on the card tone.
struct ServiceFacts: View {
    let rows: [(String, String)]
    var mono = false
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 8)
                    Text(row.1).font(mono ? Theme.monoFont : Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }.font(Theme.captionFont)
            }
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
    }
}

/// A short, bordered tag, e.g. an issue label.
struct ServiceTag: View {
    let text: String
    var color: Color?
    var body: some View {
        HStack(spacing: 4) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
    }
}

/// An error line that keeps a stale list on screen instead of replacing it.
struct ServiceBanner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            OctetIcon("circle.x", size: 12).foregroundStyle(Theme.danger).padding(.top, 1)
            Text(text).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.danger.opacity(0.10)))
        .padding(.horizontal, 8).padding(.bottom, 4)
    }
}

struct ServiceListSkeleton: View {
    var rows = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<rows, id: \.self) { row in
                PlaneSkeletonRow(width: CGFloat(160 + row % 3 * 24), height: 44, detail: true).padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Loading")
    }
}

/// "3 minutes ago", terse and stable for a list.
enum ServiceTime {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ value: String) -> Date? { iso.date(from: value) ?? isoFraction.date(from: value) }

    static func ago(_ value: String) -> String {
        guard let d = date(value) else { return value }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        if s < 86_400 * 30 { return "\(s / 86_400)d ago" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func duration(from start: String, to end: String) -> String? {
        guard let a = date(start), let b = date(end), b >= a else { return nil }
        let s = Int(b.timeIntervalSince(a))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    static func full(_ value: String) -> String { date(value)?.formatted(date: .abbreviated, time: .shortened) ?? value }
}

/// DEBUG: `OCTET_OPEN_WINDOW=planes:<ci|tickets|containers>:sample` fills a
/// plane with made-up data and opens one row. Nothing runs gh or docker.
enum ServiceSample {
    static func shows(_ kind: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"] == "planes:\(kind):sample"
        #else
        return false
        #endif
    }

    #if DEBUG
    private static func ago(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
    }

    static var runs: String {
        func run(_ id: Int, _ title: String, _ wf: String, _ branch: String, _ status: String, _ conclusion: String, _ age: Double, _ took: Double) -> String {
            #"{"databaseId":\#(id),"displayTitle":"\#(title)","workflowName":"\#(wf)","headBranch":"\#(branch)","status":"\#(status)","conclusion":"\#(conclusion)","url":"https://github.com/example/app/actions/runs/\#(id)","event":"push","createdAt":"\#(ago(age))","updatedAt":"\#(ago(age - took))","attempt":1}"#
        }
        return "[" + [
            run(9021, "Add workspace-scoped panels", "CI", "feat/t3-parity", "in_progress", "", 140, 0),
            run(9020, "Fix notary credentials", "Release", "main", "completed", "failure", 3_600, 412),
            run(9019, "Revamp the Overview tab", "CI", "feat/t3-parity", "completed", "success", 7_200, 288),
            run(9018, "Bump Sparkle", "CI", "main", "completed", "success", 90_000, 301),
            run(9017, "Notch: queued peeks", "CI", "codex/notch-opt", "completed", "cancelled", 200_000, 40),
        ].joined(separator: ",") + "]"
    }

    static var issues: String {
        func issue(_ n: Int, _ title: String, _ state: String, _ body: String, _ labels: String, _ comments: Int, _ age: Double) -> String {
            #"{"number":\#(n),"title":"\#(title)","body":"\#(body)","state":"\#(state)","url":"https://github.com/example/app/issues/\#(n)","author":{"login":"jackpatterson"},"labels":[\#(labels)],"updatedAt":"\#(ago(age))","comments":[\#(Array(repeating: "{}", count: comments).joined(separator: ","))]}"#
        }
        let bug = #"{"name":"bug","color":"d73a4a"}"#, ui = #"{"name":"ui","color":"a371f7"}"#, docs = #"{"name":"docs","color":"0075ca"}"#
        return "[" + [
            issue(142, "Containers tab flickers on every refresh", "OPEN", "The list clears on each 5s poll.\\nExpected: keep the rows and update in place.", bug + "," + ui, 3, 1_800),
            issue(139, "Show CI duration for finished runs", "OPEN", "", ui, 0, 20_000),
            issue(131, "Document the Device plane setup", "OPEN", "Walk through simctl and AXe install.", docs, 1, 150_000),
            issue(120, "Sidebar logo overlap for multi-agent workspaces", "CLOSED", "Shipped.", ui, 5, 400_000),
        ].joined(separator: ",") + "]"
    }

    static var containers: String {
        func c(_ id: String, _ name: String, _ image: String, _ state: String, _ status: String, _ ports: String, _ svc: String, _ project: String) -> String {
            let labels = project.isEmpty ? "" : "com.docker.compose.project=\(project),com.docker.compose.service=\(svc)"
            return #"{"ID":"\#(id)","Names":"\#(name)","Image":"\#(image)","State":"\#(state)","Status":"\#(status)","Ports":"\#(ports)","Labels":"\#(labels)"}"#
        }
        return [
            c("a1b2c3d4e5f6a1", "shop-web-1", "node:22-alpine", "running", "Up 2 hours", "0.0.0.0:3000->3000/tcp", "web", "shop"),
            c("b2c3d4e5f6a1b2", "shop-db-1", "postgres:17-alpine", "running", "Up 2 hours (healthy)", "0.0.0.0:55432->5432/tcp", "db", "shop"),
            c("c3d4e5f6a1b2c3", "shop-worker-1", "node:22-alpine", "exited", "Exited (1) 12 minutes ago", "", "worker", "shop"),
            c("d4e5f6a1b2c3d4", "mailpit", "axllent/mailpit", "running", "Up 3 days", "0.0.0.0:8025->8025/tcp", "", ""),
            c("e5f6a1b2c3d4e5", "redis-cache", "redis:7", "paused", "Up 1 day (Paused)", "", "", ""),
        ].joined(separator: "\n")
    }
    #else
    // Release builds carry none of the made-up rows; `shows` is always false there.
    static var runs: String { "[]" }
    static var containers: String { "" }
    #endif
}

#if DEBUG
/// Made-up Linear and Jira data, comments and write results for the same hook
/// (`planes:tickets:sample`, with OCTET_TICKETS_PROVIDER=Linear or Jira).
/// Moving an issue to a state named "Canceled" fails, to show the rollback.
extension ServiceSample {
    static let viewerId = "me"

    static func connections(_ tracker: IssueTracker) -> [TrackerConnection] {
        switch tracker {
        case .github: []
        case .linear:
            [TrackerConnection(id: "sample-a", tracker: .linear, credentials: TrackerCredentials(token: "-", name: "Acme")),
             TrackerConnection(id: "sample-b", tracker: .linear, credentials: TrackerCredentials(token: "-", name: "Studio"))]
        case .jira:
            [TrackerConnection(id: "sample-a", tracker: .jira, credentials: TrackerCredentials(token: "-", site: "acme.atlassian.net", email: "a@acme.co")),
             TrackerConnection(id: "sample-b", tracker: .jira, credentials: TrackerCredentials(token: "-", site: "jira.corp.example", server: true, name: "jira.corp.example"))]
        }
    }

    static func containers(_ tracker: IssueTracker) -> [TrackerContainer] {
        tracker == .linear ? [TrackerContainer(id: "eng", name: "Engineering"), TrackerContainer(id: "design", name: "Design")]
                           : [TrackerContainer(id: "ENG", name: "Engineering (ENG)"), TrackerContainer(id: "OPS", name: "Operations (OPS)")]
    }

    private static func make(_ key: String, _ title: String, _ state: String, closed: Bool = false, body: String = "", assignee: String? = nil,
                             priority: String? = nil, rank: Int = 0, type: String? = nil, labels: [TrackerIssue.Label] = [],
                             comments: Int = 0, age: Double, subs: [TrackerIssue.SubIssue] = []) -> TrackerIssue {
        TrackerIssue(id: key, key: key, title: title, body: body, stateName: state, closed: closed, url: URL(string: "https://example.com/\(key)"),
                     person: assignee ?? "Bo Reyes", labels: labels, updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age)),
                     comments: comments, assignee: assignee, assigneeId: assignee == nil ? nil : (assignee == "Ana Silva" ? viewerId : "other"),
                     priority: priority, priorityRank: rank, issueType: type, subIssues: subs)
    }

    static func trackerIssues(_ tracker: IssueTracker, filter: IssueFilter) throws -> [TrackerIssue] {
        let bug = TrackerIssue.Label(name: "bug", color: "eb5757"), ui = TrackerIssue.Label(name: "ui", color: "a371f7")
        var list: [TrackerIssue]
        switch tracker {
        case .github:
            list = try GitHubIssueCLI.parseIssues(Data(Self.issues.utf8))
        case .linear:
            list = [
                make("ENG-42", "Sync drops edits made while offline", "In Progress", body: "Edits made offline are lost when the socket reconnects.\nRepro: airplane mode, edit, reconnect.",
                     assignee: "Ana Silva", priority: "Urgent", rank: 1, labels: [bug], comments: 3, age: 1_200, subs: [
                        .init(key: "ENG-43", title: "Queue edits locally", stateName: "Done", closed: true),
                        .init(key: "ENG-44", title: "Replay queue on reconnect", stateName: "In Progress", closed: false)]),
                make("ENG-40", "Settings sheet clips on small windows", "Todo", assignee: nil, priority: "Medium", rank: 3, labels: [ui], comments: 0, age: 40_000),
                make("ENG-31", "Export CSV for the activity log", "Backlog", body: "Customers ask for it weekly.", assignee: "Cy Dalton", priority: "Low", rank: 4, comments: 1, age: 300_000),
                make("ENG-12", "Retire the legacy importer", "Done", closed: true, assignee: "Ana Silva", comments: 2, age: 900_000),
            ]
        case .jira:
            list = [
                make("ENG-118", "Crash when saving a draft with attachments", "In Progress", body: "Stack trace points at the upload queue.", assignee: "Ana Silva",
                     priority: "High", rank: 2, type: "Bug", labels: [bug], comments: 4, age: 3_000),
                make("ENG-117", "Add SSO audit events", "To Do", assignee: nil, priority: "Medium", rank: 3, type: "Story", comments: 0, age: 60_000),
                make("OPS-9", "Rotate staging credentials", "To Do", assignee: "Cy Dalton", priority: "Highest", rank: 1, type: "Task", comments: 1, age: 200_000),
                make("ENG-90", "Upgrade the build image", "Done", closed: true, assignee: "Ana Silva", priority: "Low", rank: 4, type: "Task", comments: 2, age: 800_000),
            ]
        }
        if tracker != .github {
            switch filter.scope {
            case "closed": list = list.filter(\.closed)
            case "all": break
            default: list = list.filter { !$0.closed }
            }
        }
        switch filter.who {
        case .anyone: break
        case .assigned: list = list.filter { $0.assigneeId == viewerId }
        case .reported: list = list.filter { $0.person == "Bo Reyes" && $0.assigneeId == nil }
        }
        return list
    }

    static func comments(_ issue: TrackerIssue) -> [TrackerComment] {
        func stamp(_ age: Double) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age)) }
        guard issue.comments > 0 else { return [] }
        return [
            TrackerComment(id: "1", author: "Cy Dalton", body: "Reproduced on 2.4.1. It only happens after the second reconnect.", createdAt: stamp(7_200)),
            TrackerComment(id: "2", author: "Ana Silva", body: "Thanks. I have a fix on a branch and am testing it now.", createdAt: stamp(1_500)),
        ]
    }

    static func statuses(_ tracker: IssueTracker) -> [TrackerStatus] {
        switch tracker {
        case .github: GitHubIssueCLI.statuses
        case .linear: ["Backlog", "Todo", "In Progress", "In Review", "Done", "Canceled"].map {
            TrackerStatus(id: $0, name: $0, closed: $0 == "Done" || $0 == "Canceled") }
        case .jira: ["To Do", "In Progress", "Done"].map { TrackerStatus(id: $0, name: $0, closed: $0 == "Done") }
        }
    }

    struct SampleWriteError: LocalizedError { var errorDescription: String? { "Sample: the tracker refused that change." } }

    static func write(status: TrackerStatus) throws { if status.name == "Canceled" { throw SampleWriteError() } }
    static func write(comment: String) throws { if comment.localizedCaseInsensitiveContains("fail") { throw SampleWriteError() } }
}
#endif
