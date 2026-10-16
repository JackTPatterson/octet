import AppKit
import SwiftUI

// The pull request plane's Summary and Timeline tabs, and the checks list
// the Summary tab and the status line share. The Code tab is in
// PullRequestPlaneCode.swift.

// MARK: - Checks

/// The checks status line beside the tabs; opens the list in a popover.
struct PullRequestChecksStatus: View {
    let detail: PullRequestDetail
    @ObservedObject var model: PullRequestPlaneModel
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let summary = detail.checksSummary
        Button { open.toggle() } label: {
            // Narrow planes keep the mark and drop the words.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    icon(summary)
                    Text(summary.text)
                        .font(Theme.captionFont)
                        .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                icon(summary)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered || open ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(summary.total == 0)
        .help(summary.text)
        .accessibilityLabel(summary.text)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.heading)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                PullRequestChecksList(checks: detail.checks, model: model)
            }
            .padding(12)
            .frame(width: 340)
            .background(Theme.card)
        }
    }

    private func icon(_ summary: PullRequestChecksSummary) -> some View {
        OctetIcon(PullRequestStyle.checksIcon(summary.tone), size: 12)
            .foregroundStyle(PullRequestStyle.checksColor(summary.tone))
    }
}

/// Failing first, then running; completed ones behind Show All.
struct PullRequestChecksList: View {
    let checks: [PullRequestCheck]
    @ObservedObject var model: PullRequestPlaneModel
    @State private var showAll = false

    var body: some View {
        let ordered = PullRequestChecksSummary.ordered(checks)
        let urgent = ordered.filter { !$0.state.isCompleted || $0.state.isFailing }
        let rest = ordered.filter { $0.state.isCompleted && !$0.state.isFailing }
        // With nothing urgent, the completed ones are the list.
        let shown = urgent.isEmpty || showAll ? ordered : urgent
        VStack(alignment: .leading, spacing: 0) {
            if checks.isEmpty {
                Text("No checks reported.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 4)
            }
            ForEach(shown) { check in
                PullRequestCheckRow(check: check, model: model)
            }
            if !urgent.isEmpty, !rest.isEmpty {
                Button {
                    MotionPreferences.shared.perform(.sidebar) { showAll.toggle() }
                } label: {
                    Text(showAll ? "Show Less" : "Show All (\(rest.count) more)")
                        .font(Theme.captionFont.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PullRequestCheckRow: View {
    let check: PullRequestCheck
    @ObservedObject var model: PullRequestPlaneModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            OctetIcon(PullRequestStyle.checkIcon(check.state), size: 12)
                .foregroundStyle(PullRequestStyle.checkColor(check.state))
            HStack(spacing: 4) {
                Text(check.name)
                    .foregroundStyle(Theme.textPrimary)
                if !check.workflow.isEmpty {
                    Text(check.workflow)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.uiFont)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(check.workflow.isEmpty ? check.name : "\(check.workflow) › \(check.name)")
            Spacer(minLength: 6)
            Text(check.state.title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            if let url = check.url {
                Button("Details") { model.open(url) }
                    .buttonStyle(.plain)
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.accent)
                    .onHover { hovered = $0 }
                    .help(url.absoluteString)
                    .fixedSize()
            }
        }
        .frame(minHeight: 24)
    }
}

// MARK: - Summary

struct PullRequestSummaryTab: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    @State private var descriptionOpen = true
    @State private var checksOpen = false
    @State private var commentsOpen = true
    @State private var editingBody = false
    @State private var bodyDraft = ""
    @State private var bodyHovered = false
    @State private var addingReviewer = false
    @State private var reviewerDraft = ""
    @State private var pickingLabels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaRow("Reviewers", icon: "person.2") {
                let reviewers = detail.reviewers
                if reviewers.isEmpty {
                    none
                } else {
                    SplashFlow(spacing: 4) {
                        ForEach(reviewers) { reviewer in PullRequestReviewerChip(reviewer: reviewer) }
                    }
                }
            } trailing: {
                OctetIconButton(icon: "person.badge.plus", help: "Ask someone to review") { addingReviewer = true }
                    .disabled(!detail.isOpen)
                    .popover(isPresented: $addingReviewer, arrowEdge: .bottom) { reviewerPopover }
            }
            metaRow("Labels", icon: "tag") {
                if detail.labels.isEmpty {
                    none
                } else {
                    SplashFlow(spacing: 4) {
                        ForEach(detail.labels) { label in PullRequestLabelCapsule(label: label) }
                    }
                }
            } trailing: {
                OctetIconButton(icon: "tag", help: "Add or remove labels") {
                    model.loadLabels()
                    pickingLabels = true
                }
                .popover(isPresented: $pickingLabels, arrowEdge: .bottom) {
                    PullRequestLabelPicker(model: model, detail: detail)
                }
            }

            OctetCollapsible(title: "Description", open: $descriptionOpen) {
                if detail.isOpen, !editingBody {
                    OctetIconButton(icon: "pencil", help: "Edit the description") {
                        bodyDraft = detail.body
                        editingBody = true
                        descriptionOpen = true
                    }
                    .opacity(bodyHovered ? 1 : 0)
                }
            } content: {
                description
            }
            .onHover { bodyHovered = $0 }

            OctetCollapsible(title: "Checks", open: $checksOpen) {
                Text(detail.checksSummary.text)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            } content: {
                PullRequestChecksList(checks: detail.checks, model: model)
                    .padding(.bottom, 8)
            }

            let conversation = detail.conversation
            OctetCollapsible(title: "Comments (\(conversation.count))", open: $commentsOpen) {
                if conversation.isEmpty {
                    Text("No comments yet.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.bottom, 8)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(conversation) { item in PullRequestCommentCard(item: item) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var none: some View {
        Text("None").font(Theme.uiFont).foregroundStyle(Theme.textMuted)
    }

    /// A label column and its value, after T3 Code's meta grid.
    private func metaRow<Value: View, Trailing: View>(_ title: String, icon: String,
                                                      @ViewBuilder value: () -> Value,
                                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 6) {
                OctetIcon(icon, size: 12)
                Text(title).font(Theme.uiFont)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 96, height: 24, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var description: some View {
        if editingBody {
            VStack(alignment: .trailing, spacing: 6) {
                OctetTextEditor(placeholder: "Description", text: $bodyDraft, minHeight: 160, maxHeight: nil,
                                font: Theme.monoFont)
                HStack(spacing: 6) {
                    OctetButton(title: "Cancel", kind: .ghost, compact: true) { editingBody = false }
                        .keyboardShortcut(.cancelAction)
                    OctetButton(title: "Save", kind: .primary, compact: true) {
                        model.editBody(bodyDraft)
                        editingBody = false
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save (⌘↩)")
                }
            }
            .padding(.bottom, 8)
        } else if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description provided.")
                .font(Theme.uiFont.italic())
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 8)
        } else {
            MarkdownView(text: detail.body)
                .padding(.bottom, 8)
        }
    }

    private var reviewerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Request a Review").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            OctetTextField(placeholder: "GitHub username", text: $reviewerDraft) { addReviewer() }
            HStack {
                Spacer()
                OctetButton(title: "Request", kind: .primary, compact: true) { addReviewer() }
                    .disabled(reviewerDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(Theme.card)
    }

    private func addReviewer() {
        model.addReviewer(reviewerDraft)
        reviewerDraft = ""
        addingReviewer = false
    }
}

private struct PullRequestReviewerChip: View {
    let reviewer: PullRequestDetail.Reviewer

    var body: some View {
        HStack(spacing: 5) {
            GitHubAvatar(login: reviewer.login, size: 14)
            Text(reviewer.login)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Circle()
                .fill(PullRequestStyle.verdictColor(reviewer.verdict))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Capsule().fill(Theme.card))
        .help(reviewer.verdict?.title ?? "Review requested")
    }
}

/// A label in its own colour, as GitHub draws them.
struct PullRequestLabelCapsule: View {
    let label: PullRequestLabel

    var body: some View {
        let color = Color(hex: label.color)
        Text(label.name)
            .font(Theme.captionFont.weight(.medium))
            .foregroundStyle(Self.readable(label.color))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.2)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    }

    /// The label's colour, nudged until it reads on the panel: GitHub's
    /// pale labels (cfd3d7) vanish on a light theme otherwise.
    static func readable(_ hex: String) -> Color {
        Color(hex: ThemePalette.readable(hex, on: Theme.palette.sidebar, toward: Theme.palette.textPrimary, minimum: 3))
    }
}

/// The repository's labels, ticked when the PR has them.
private struct PullRequestLabelPicker: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OctetTextField(placeholder: "Filter labels", text: $query)
            if let labels = model.repositoryLabels {
                let filtered = labels.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if filtered.isEmpty {
                            Text(labels.isEmpty ? "This repository has no labels." : "No matching labels.")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(6)
                        }
                        ForEach(filtered) { label in
                            let on = detail.labels.contains { $0.name == label.name }
                            PickerRow(on: on, label: label) { model.toggleLabel(label) }
                        }
                    }
                }
                .frame(maxHeight: 280)
                .octetScrollIndicators()
            } else {
                Text("Reading labels…")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(6)
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(Theme.card)
    }

    private struct PickerRow: View {
        let on: Bool
        let label: PullRequestLabel
        let toggle: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    OctetIcon("check", size: 12)
                        .foregroundStyle(Theme.accent)
                        .opacity(on ? 1 : 0)
                    Circle().fill(Color(hex: label.color)).frame(width: 9, height: 9)
                    Text(label.name)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// A comment or review in the Comments section.
private struct PullRequestCommentCard: View {
    let item: PullRequestDetail.TimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GitHubAvatar(login: item.author, size: 16)
                Text(item.author)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if case .review(let verdict) = item.kind {
                    PullRequestVerdictChip(verdict: verdict)
                }
                Spacer(minLength: 4)
                Text(PullRequestJSON.ago(item.date))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if !item.body.isEmpty {
                MarkdownView(text: item.body)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border.opacity(0.6), lineWidth: 1))
    }
}

struct PullRequestVerdictChip: View {
    let verdict: PullRequestDetail.Verdict

    var body: some View {
        let tint = PullRequestStyle.verdictColor(verdict)
        Text(verdict.title)
            .font(Theme.captionFont.weight(.medium))
            .foregroundStyle(verdict == .commented || verdict == .dismissed ? Theme.textSecondary : tint)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill((verdict == .commented || verdict == .dismissed ? Theme.textTertiary : tint).opacity(0.16)))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Timeline

struct PullRequestTimelineTab: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    let newestFirst: Bool

    var body: some View {
        let items = detail.timeline(newestFirst: newestFirst)
        if items.isEmpty {
            Text("No activity yet.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PullRequestTimelineRow(item: item, model: model,
                                           first: index == 0, last: index == items.count - 1)
                }
            }
        }
    }
}

private struct PullRequestTimelineRow: View {
    let item: PullRequestDetail.TimelineItem
    @ObservedObject var model: PullRequestPlaneModel
    let first: Bool
    let last: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rail
            content
                .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered && isCommit ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            if case .commit(let sha) = item.kind { model.copy(sha, "commit \(sha.prefix(7))") }
        }
        .help(isCommit ? "Copy the commit's SHA" : "")
    }

    private var isCommit: Bool {
        if case .commit = item.kind { return true }
        return false
    }

    /// A 1pt line through every row, with this row's mark on it.
    private var rail: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : Theme.divider).frame(width: 1, height: 10)
                Rectangle().fill(last ? .clear : Theme.divider).frame(width: 1)
            }
            OctetIcon(icon, size: 12)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.sidebar))
                .padding(.top, 3)
        }
        .frame(width: 18)
    }

    private var icon: String {
        switch item.kind {
        case .opened: "pull.request"
        case .commit: "commit"
        case .comment: "message"
        case .review(let verdict):
            switch verdict {
            case .approved: "circle.check"
            case .changesRequested: "circle.x"
            default: "message"
            }
        case .merged: "merge"
        case .closed: "circle.x"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .opened: Color(hex: AgentStateColor.done)
        case .merged: PullRequestStyle.violet
        case .closed: Theme.danger
        case .review(let verdict): PullRequestStyle.verdictColor(verdict)
        case .commit, .comment: Theme.textTertiary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .commit(let sha):
            HStack(spacing: 8) {
                Text(item.text.isEmpty ? "Commit" : item.text)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(String(sha.prefix(7)))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                when
            }
        case .comment, .review:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    GitHubAvatar(login: item.author, size: 14)
                    Text(item.author).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if case .review(let verdict) = item.kind {
                        PullRequestVerdictChip(verdict: verdict)
                    } else {
                        Text("commented").font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    when
                }
                let excerpt = PullRequestDetail.firstLines(item.body)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .opened, .merged, .closed:
            HStack(spacing: 6) {
                if !item.author.isEmpty {
                    GitHubAvatar(login: item.author, size: 14)
                    Text(item.author).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                Text(item.author.isEmpty ? item.text : item.text.lowercased())
                    .font(Theme.uiFont)
                    .foregroundStyle(item.author.isEmpty ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 4)
                when
            }
        }
    }

    private var when: some View {
        Text(PullRequestJSON.ago(item.date))
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }
}
