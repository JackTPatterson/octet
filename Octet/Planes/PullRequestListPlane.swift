import SwiftUI

/// The repository's open pull requests; picking one calls `open`, which the
/// host turns into a pull request plane.
struct PullRequestListPlane: View {
    let directory: String
    let open: (Int) -> Void
    /// Opens the Pull Requests page; nil hides its button.
    let openFullPage: (() -> Void)?
    @StateObject private var model: PullRequestListModel

    init(directory: String, openFullPage: (() -> Void)? = nil, open: @escaping (Int) -> Void) {
        self.directory = directory
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
        .onAppear { model.start() }
        .onDisappear { model.stop() }
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
                            PullRequestListRow(item: item) { open(item.number) }
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

/// One open PR: state, title, then number, author, age, checks and size.
private struct PullRequestListRow: View {
    let item: PullRequestSummary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                OctetIcon(item.tone.icon, size: 14)
                    .foregroundStyle(item.tone.color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(item.number) · \(item.author) · updated \(PullRequestJSON.ago(item.updatedAt))")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if item.checks.tone != .none {
                            OctetIcon(PullRequestStyle.checksIcon(item.checks.tone), size: 11)
                                .foregroundStyle(PullRequestStyle.checksColor(item.checks.tone))
                                .help(item.checks.text)
                        }
                        DiffStatLabel(added: item.additions, removed: item.deletions)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(item.isDraft ? "Draft: \(item.title)" : item.title)
        .accessibilityLabel("#\(item.number) \(item.title) by \(item.author)\(item.isDraft ? ", draft" : "")")
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
