import SwiftUI

/// The repository's open pull requests; picking one calls `open`, which the
/// host turns into a pull request plane.
struct PullRequestListPlane: View {
    let directory: String
    let open: (Int) -> Void
    /// Opens the Pull Requests page; nil hides its button.
    let openFullPage: (() -> Void)?
    /// Whether the plane is in front; it polls gh only then.
    let visible: Bool
    /// Shows the PR for the branch checked out; nil hides its button.
    let currentBranch: (() -> Void)?
    @StateObject private var model: PullRequestListModel

    init(directory: String, visible: Bool = true, openFullPage: (() -> Void)? = nil,
         currentBranch: (() -> Void)? = nil, open: @escaping (Int) -> Void) {
        self.directory = directory
        self.visible = visible
        self.currentBranch = currentBranch
        self.open = open
        self.openFullPage = openFullPage
        _model = StateObject(wrappedValue: PullRequestListModel(directory: directory))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .pollWhileSeen(visible, start: model.start, stop: model.stop)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Pull Requests")
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
            if let items = model.items {
                Text("\(items.count)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if let currentBranch {
                OctetButton(title: "Current Branch", icon: "branch", kind: .ghost, compact: true, action: currentBranch)
                    .help("The pull request for the branch checked out here")
            }
            if let openFullPage {
                OctetIconButton(icon: "arrow.up.left.and.arrow.down.right", help: "Open Full Page", action: openFullPage)
            }
            OctetIconButton(icon: "arrow.clockwise", help: "Refresh") { model.refresh() }
                .disabled(model.loading)
        }
        .padding(.horizontal, PullRequestStyle.horizontalPadding)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        if PlaneLoadingPreview.shows("pullRequests") {
            PullRequestListSkeleton()
        } else if let failure = model.failure {
            message(failure.title, failure.remedy)
        } else if let items = model.items {
            if items.isEmpty {
                message("No open pull requests.", nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            PullRequestRow(item) { open(item.number) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .octetScrollIndicators()
            }
        } else {
            PullRequestListSkeleton()
        }
    }

    private func message(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            if let detail {
                Text(detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One pull request in a list, the same in the panel's list and the Pull
/// Requests page: state, number and title, then who opened it, the
/// repository when the list spans several, its age, checks and size.
struct PullRequestRow: View {
    let tone: PullRequestTone
    let number: Int
    let title: String
    let author: String
    /// "owner/name", for a list across repositories.
    var repository: String?
    let updatedAt: Date?
    let isDraft: Bool
    var checks: PullRequestChecksSummary?
    var additions: Int?
    var deletions: Int?
    var url: URL?
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    OctetIcon(tone.icon, size: 13)
                        .foregroundStyle(tone.color)
                    Text(verbatim: "#\(number)")
                        .font(Theme.uiFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    Text(title)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let checks, checks.tone != .none {
                        OctetIcon(PullRequestStyle.checksIcon(checks.tone), size: 12)
                            .foregroundStyle(PullRequestStyle.checksColor(checks.tone))
                            .help(checks.text)
                    }
                    if let additions, let deletions {
                        DiffStatLabel(added: additions, removed: deletions)
                            .font(Theme.captionFont.monospacedDigit())
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    GitHubAvatar(login: author, size: 14)
                    Text(author)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let repository {
                        Text(repository)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(PullRequestJSON.ago(updatedAt))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(Theme.captionFont)
                .padding(.leading, 19)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isDraft ? "Draft: \(title)" : title)
        .accessibilityLabel("\(repository.map { $0 + " " } ?? "")#\(number) \(title) by \(author)\(isDraft ? ", draft" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let url {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }
}

extension PullRequestRow {
    /// A row of the panel's list, from `gh pr list`.
    init(_ item: PullRequestSummary, action: @escaping () -> Void) {
        self.init(tone: item.tone, number: item.number, title: item.title, author: item.author,
                  updatedAt: item.updatedAt, isDraft: item.isDraft, checks: item.checks,
                  additions: item.additions, deletions: item.deletions, action: action)
    }
}

/// `gh pr list` for the folder's repository, read on appear and every
/// minute while it shows.
@MainActor
final class PullRequestListModel: ObservableObject {
    let directory: String
    @Published private(set) var items: [PullRequestSummary]?
    @Published private(set) var failure: PullRequestLoadFailure?
    @Published private(set) var loading = false
    private var timer: Timer?
    private var generation = 0

    init(directory: String) {
        self.directory = directory
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: PullRequestPlaneModel.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        generation += 1
        let generation = self.generation, directory = self.directory
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LoginShell.run(["gh", "pr", "list", "--json", PullRequestSummary.fields, "--limit", "50"], in: directory)
            let items = result.status == 0 ? PullRequestSummary.parseList(result.output) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == generation else { return }
                    self.loading = false
                    if let items {
                        self.failure = nil
                        if items != self.items { self.items = items }
                    } else if self.items == nil {
                        // A failed refresh keeps the list it had.
                        self.failure = result.status == 0
                            ? .other("gh's answer couldn't be read.")
                            : PullRequestLoadFailure.classify(status: result.status, output: result.output)
                    }
                }
            }
        }
    }
}
