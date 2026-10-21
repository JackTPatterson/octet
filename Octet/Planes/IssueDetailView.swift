import SwiftUI

/// Comments already fetched, so closing and reopening a row doesn't refetch.
/// The pane clears it on refresh.
@MainActor
enum IssueCommentCache {
    static var store: [String: [TrackerComment]] = [:]
}

/// The open row of the Issues pane: who and how urgent, the description,
/// sub-issues, the actions that write (status, assign to me, comment) and the
/// comments themselves. Writes show at once and roll back with a banner if the
/// tracker refuses them. All tracker access goes through `IssueService`.
struct IssueDetailView: View {
    @EnvironmentObject private var window: WindowContext
    let issue: TrackerIssue
    let tracker: IssueTracker
    let connectionId: String?
    let directory: String?
    /// The pane's copy of the issue changes with each write (and each rollback).
    let onChange: (TrackerIssue) -> Void

    private enum Comments: Equatable { case loading, loaded, failed(String) }
    @State private var comments: [TrackerComment] = []
    @State private var commentsState = Comments.loading
    @State private var draft = ""
    @State private var expandedComments: Set<String> = []
    @State private var sending = false
    @State private var statuses: [TrackerStatus]?
    @State private var changing = false
    @State private var viewer: String?
    @State private var failure: String?

    private var cacheKey: String { "\(tracker.rawValue):\(connectionId ?? ""):\(directory ?? ""):\(issue.id)" }
    private var mine: Bool { viewer != nil && issue.assigneeId == viewer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            facts
            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels, id: \.name) { ServiceTag(text: $0.name, color: $0.color.map { Color(hex: $0) }) }
                }
            }
            Text(issue.body.isEmpty ? "No description provided." : issue.body).font(Theme.captionFont).foregroundStyle(issue.body.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !issue.subIssues.isEmpty { subIssues }
            actions
            if let failure { ServiceBanner(text: failure).padding(.horizontal, -8) }
            commentList
            composer
        }
        .task(id: issue.id) {
            viewer = await IssueService.viewerId(tracker: tracker, connectionId: connectionId, directory: directory)
            await loadComments()
        }
    }

    // MARK: Facts

    private var facts: some View {
        HStack(spacing: 6) {
            Avatar(name: issue.assignee)
            Text(issue.assignee ?? "Unassigned").font(Theme.captionFont)
                .foregroundStyle(issue.assignee == nil ? Theme.textTertiary : Theme.textSecondary).lineLimit(1)
            if let priority = issue.priority {
                OctetIcon(issue.priorityRank == 1 ? "exclamationmark" : "flag", size: 12)
                ServiceTag(text: priority, color: issue.priorityRank == 1 ? Theme.danger : issue.priorityRank == 2 ? PullRequestStyle.amber : Theme.textTertiary)
            }
            if let type = issue.issueType { ServiceTag(text: type) }
            Spacer(minLength: 0)
        }
    }

    private var subIssues: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sub-issues").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            ForEach(issue.subIssues, id: \.key) { sub in
                HStack(spacing: 6) {
                    OctetIcon(sub.closed ? "circle.check" : "circle.dot", size: 11)
                        .foregroundStyle(sub.closed ? ServiceTone.merged.color : ServiceTone.good.color)
                    Text(sub.key).font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    Text(sub.title).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { actionButtons }
            VStack(alignment: .leading, spacing: 6) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if let directory, !directory.isEmpty {
            OctetButton(title: "Start workspace", icon: "plus", kind: .primary, compact: true) {
                IssueWorkspaceStarter.start(issue: issue, tracker: tracker, connectionId: connectionId, projectDirectory: directory, window: window)
            }
        }
        OctetButton(title: changing ? "Updating…" : (issue.stateName.isEmpty ? "Status" : issue.stateName), icon: "chevron.down",
                    kind: .secondary, compact: true) { chooseStatus() }.disabled(changing || sending)
        if !mine {
            OctetButton(title: "Assign to me", icon: "person.badge.plus", kind: .secondary, compact: true) { assignToMe() }.disabled(changing || sending)
        }
        if let url = issue.url {
            OctetButton(title: "View on \(tracker.rawValue)", icon: "arrow.up.right", kind: .ghost, compact: true) { NSWorkspace.shared.open(url) }
        }
        OctetCopyText(text: issue.key, help: "Copy issue key")
    }

    private func chooseStatus() {
        Task { @MainActor in
            if statuses == nil || tracker == .jira {
                changing = true
                defer { changing = false }
                do { statuses = try await IssueService.statuses(tracker: tracker, issue: issue, connectionId: connectionId) }
                catch { failure = error.localizedDescription; return }
            }
            failure = nil
            OctetContextMenu.present((statuses ?? []).map { status in
                .action(status.menuTitle, icon: status.name == issue.stateName ? "check" : nil) { setStatus(status) }
            })
        }
    }

    private func setStatus(_ status: TrackerStatus) {
        let before = issue
        var after = issue
        after.stateName = status.name
        after.closed = status.closed
        onChange(after)
        failure = nil
        changing = true
        Task { @MainActor in
            defer { changing = false }
            do {
                try await IssueService.setStatus(tracker: tracker, issue: before, to: status, connectionId: connectionId, directory: directory)
                // The transitions open on a Jira issue depend on where it is now.
                if tracker == .jira { statuses = nil }
            } catch {
                onChange(before)
                failure = "Couldn't change the status. \(error.localizedDescription)"
            }
        }
    }

    private func assignToMe() {
        let before = issue
        var after = issue
        after.assignee = "You"
        after.assigneeId = viewer
        after.person = "You"
        onChange(after)
        failure = nil
        changing = true
        Task { @MainActor in
            defer { changing = false }
            do {
                try await IssueService.assignToMe(tracker: tracker, issue: before, connectionId: connectionId, directory: directory)
            } catch {
                onChange(before)
                failure = "Couldn't assign this issue. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Comments

    @ViewBuilder private var commentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(comments.isEmpty ? "Comments" : "Comments · \(comments.count)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            switch commentsState {
            case .loading:
                VStack(alignment: .leading, spacing: 4) {
                    PlaneSkeletonRow(width: 130, height: 26, detail: true)
                    PlaneSkeletonRow(width: 100, height: 26, detail: true)
                }.accessibilityLabel("Loading comments")
            case .failed(let why):
                ServiceBanner(text: why).padding(.horizontal, -8)
                OctetButton(title: "Retry", kind: .secondary, compact: true) {
                    Task { await loadComments() }
                }
            case .loaded:
                if comments.isEmpty {
                    Text("No comments yet.").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Avatar(name: comment.author)
                        Text(comment.author).font(Theme.captionFont).foregroundStyle(Theme.textPrimary)
                        Text(ServiceTime.ago(comment.createdAt)).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    Text(comment.body.count > 1_500 && !expandedComments.contains(comment.id) ? String(comment.body.prefix(1_500)) + "…" : comment.body)
                        .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 22)
                    if comment.body.count > 1_500 {
                        Button(expandedComments.contains(comment.id) ? "Show less" : "Show full comment") {
                            if !expandedComments.insert(comment.id).inserted { expandedComments.remove(comment.id) }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            OctetTextEditor(placeholder: "Write a comment…", text: $draft, minHeight: 52, maxHeight: 140, font: Theme.captionFont)
            HStack {
                Spacer(minLength: 0)
                OctetButton(title: sending ? "Sending…" : "Send", kind: .primary, compact: true) { send() }
                    .disabled(changing || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @MainActor private func loadComments() async {
        if let cached = IssueCommentCache.store[cacheKey] {
            comments = cached
            commentsState = .loaded
            return
        }
        guard issue.comments > 0 else {
            // The list already said there's nothing to fetch.
            commentsState = .loaded
            return
        }
        commentsState = .loading
        do {
            comments = try await IssueService.comments(tracker: tracker, issue: issue, connectionId: connectionId, directory: directory)
            IssueCommentCache.store[cacheKey] = comments
            commentsState = .loaded
        } catch {
            commentsState = .failed("Couldn't load comments. \(error.localizedDescription)")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let pending = TrackerComment(id: "pending-\(UUID().uuidString)", author: "You", body: text,
                                     createdAt: ISO8601DateFormatter().string(from: Date()))
        let before = issue
        comments.append(pending)
        commentsState = .loaded
        draft = ""
        sending = true
        failure = nil
        var after = issue
        after.comments += 1
        onChange(after)
        Task { @MainActor in
            defer { sending = false }
            do {
                let saved = try await IssueService.addComment(tracker: tracker, issue: before, body: text, connectionId: connectionId, directory: directory)
                if let saved, let index = comments.firstIndex(where: { $0.id == pending.id }) { comments[index] = saved }
                IssueCommentCache.store[cacheKey] = comments
            } catch {
                comments.removeAll { $0.id == pending.id }
                draft = text
                onChange(before)
                failure = "Couldn't send the comment. \(error.localizedDescription)"
            }
        }
    }
}

/// A person's initials on a quiet disc.
private struct Avatar: View {
    let name: String?
    private var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "" : String(parts).uppercased()
    }
    var body: some View {
        Text(initials.isEmpty ? "–" : initials)
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            .frame(width: 16, height: 16).background(Circle().fill(Theme.card))
            .accessibilityHidden(true)
    }
}
