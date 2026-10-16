import AppKit
import SwiftUI

/// The Pull Requests page, after T3 Code's: every pull request that
/// involves you, across repositories, on the left; the one picked, in full,
/// on the right. Opened over the terminal like the changes review (palette,
/// View menu, or the Pull Requests plane's "Open Full Page"); Esc closes it.
/// Everything it runs is a gh read: search, list, view.
@MainActor
final class PullRequestsPageModel: ObservableObject {
    /// The focused folder when the page opened: "This project", and where
    /// a PR of that folder's own repository opens without `-R`.
    let directory: String?

    @Published var scope: PullRequestScope { didSet { if scope != oldValue { scopeChanged(from: oldValue) } } }
    @Published var queryText = "" { didSet { if queryText != oldValue { refreshIfClosedWanted() } } }
    @Published var sort: PullRequestSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey); wantStatsIfNeeded() }
    }
    @Published var filters = PullRequestFilters() {
        didSet { if filters != oldValue { refreshIfClosedWanted(); wantStatsIfNeeded() } }
    }
    @Published var selectedId: String?

    /// Search results by section; nil until the first answer.
    @Published private(set) var found: [PullRequestInboxGroup: [PullRequestInboxItem]]?
    @Published private(set) var failure: PullRequestLoadFailure?
    @Published private(set) var loading = false
    /// `directory`'s repository, "owner/name", once gh has said.
    @Published private(set) var projectRepository: String?
    /// Sizes and checks by row id, as they arrive.
    @Published private(set) var stats: [String: PullRequestStats] = [:]

    private var generation = 0
    private var timer: Timer?
    /// Whether the last read asked for closed and merged PRs too.
    private var fetchedClosed = false
    // Row stats are read a few at a time: a long list would otherwise start
    // a hundred gh processes at once and trip GitHub's rate limit.
    private var queue: [PullRequestInboxItem] = []
    private var inFlight: Set<String> = []
    private static let maxConcurrent = 4
    /// Read stats outlive the page, keyed by row and its last update, so
    /// reopening it doesn't read every row again.
    private static var statsCache: [String: (updatedAt: Date?, stats: PullRequestStats)] = [:]
    /// Your GitHub login, for grouping "This project"; read once per launch.
    private static var viewer: String?
    private static let sortKey = "octet.pullRequests.sort"

    init(directory: String?, scope: PullRequestScope = .all) {
        self.directory = directory
        self.scope = directory == nil && scope == .project ? .all : scope
        self.sort = UserDefaults.standard.string(forKey: Self.sortKey).flatMap(PullRequestSort.init(rawValue:)) ?? .updated
    }

    // MARK: - What shows

    var query: PullRequestQuery { PullRequestQuery(queryText) }

    /// A typed `is:` wins over the Filters menu's states, so `is:merged`
    /// finds merged PRs without a trip to the menu.
    private var effectiveFilters: PullRequestFilters {
        var filters = self.filters
        if !query.states.isEmpty { filters.tones = [.open, .draft, .closed, .merged] }
        return filters
    }

    private var wantsClosed: Bool { filters.wantsClosed || query.wantsClosed }

    /// The sections, searched, filtered and sorted.
    var sections: [(group: PullRequestInboxGroup, items: [PullRequestInboxItem])] {
        guard let found else { return [] }
        let query = self.query, filters = effectiveFilters, stats = self.stats
        let repository: String? = if case .repository(let name) = scope { name.lowercased() } else { nil }
        return PullRequestInbox.grouped(found).compactMap { section in
            let items = section.items.filter { item in
                (repository == nil || item.repository.lowercased() == repository)
                    && query.matches(item)
                    && filters.admits(item, in: section.group, stats: stats[item.id])
            }
            return items.isEmpty ? nil : (section.group, sort.sorted(items, stats: stats))
        }
    }

    var visibleItems: [PullRequestInboxItem] { sections.flatMap(\.items) }

    var selected: PullRequestInboxItem? {
        let items = visibleItems
        return items.first { $0.id == selectedId } ?? items.first
    }

    /// The repositories in the results, for the scope picker.
    var repositories: [String] {
        guard let found else { return [] }
        return PullRequestInbox.repositories(found)
    }

    /// Whether `item` is `directory`'s own repository: it then opens there,
    /// with checkout and the rest as in the panel.
    func isLocal(_ item: PullRequestInboxItem) -> Bool {
        guard directory != nil, let projectRepository else { return false }
        return projectRepository.lowercased() == item.repository.lowercased()
    }

    func step(_ offset: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected?.id } ?? 0
        selectedId = items[(index + offset + items.count) % items.count].id
    }

    // MARK: - Reading

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

    private func scopeChanged(from old: PullRequestScope) {
        // A repository is a slice of "All"; only "This project" reads differently.
        if old == .project || scope == .project {
            found = nil
            failure = nil
            refresh()
        }
    }

    private func refreshIfClosedWanted() {
        if wantsClosed && !fetchedClosed { refresh() }
    }

    func refresh() {
        generation += 1
        let generation = self.generation, closed = wantsClosed
        let directory = self.directory, project = scope == .project
        let knownRepository = projectRepository, knownViewer = Self.viewer
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // The folder's repository, for "This project" and for opening
            // its PRs without -R.
            var repository = knownRepository
            if repository == nil, let directory {
                let result = LoginShell.run(["gh", "repo", "view", "--json", "nameWithOwner"], in: directory)
                repository = result.status == 0
                    ? PullRequestJSON.object(in: result.output)?["nameWithOwner"] as? String : nil
            }
            let outcome = project
                ? Self.readProject(directory: directory, repository: repository, viewer: knownViewer, closed: closed)
                : Self.readSearches(closed: closed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let repository { self.projectRepository = repository }
                    if let viewer = outcome.viewer { Self.viewer = viewer }
                    guard self.generation == generation else { return }
                    self.loading = false
                    if let found = outcome.found {
                        self.failure = nil
                        self.fetchedClosed = closed
                        for (id, stats) in outcome.stats { self.store(stats, for: id, updatedAt: outcome.updatedAt[id]) }
                        if found != self.found { self.found = found }
                        self.restoreCachedStats()
                        self.wantStatsIfNeeded()
                    } else if self.found == nil {
                        // A failed refresh keeps the list it had.
                        self.failure = outcome.failure
                    }
                }
            }
        }
    }

    private struct Outcome {
        var found: [PullRequestInboxGroup: [PullRequestInboxItem]]?
        var failure: PullRequestLoadFailure?
        var stats: [String: PullRequestStats] = [:]
        var updatedAt: [String: Date] = [:]
        var viewer: String?
    }

    /// The four searches at once; with `closed`, each again for closed and
    /// merged PRs. One section failing still shows the others.
    nonisolated private static func readSearches(closed: Bool) -> Outcome {
        let groups = PullRequestInboxGroup.allCases.filter { $0.searchFlag != nil }
        let jobs = groups.flatMap { group in [(group, false)] + (closed ? [(group, true)] : []) }
        let lock = NSLock()
        var results: [PullRequestInboxGroup: [PullRequestInboxItem]] = [:]
        var failure: PullRequestLoadFailure?
        var succeeded = 0
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (group, closed) = jobs[index]
            guard let arguments = PullRequestInbox.searchArguments(group, closed: closed) else { return }
            let result = LoginShell.run(arguments, in: NSHomeDirectory())
            let items = result.status == 0 ? PullRequestInbox.parseSearch(result.output) : nil
            lock.lock()
            defer { lock.unlock() }
            if let items {
                succeeded += 1
                results[group, default: []] += items
            } else if failure == nil {
                failure = result.status == 0
                    ? .other("gh's answer couldn't be read.")
                    : PullRequestLoadFailure.classify(status: result.status, output: result.output)
            }
        }
        guard succeeded > 0 else { return Outcome(failure: failure ?? .other("gh found nothing to search.")) }
        // Open and closed answers for a section, in one list, each PR once.
        for (group, items) in results {
            var seen = Set<String>()
            results[group] = items.filter { seen.insert($0.id).inserted }
        }
        return Outcome(found: results)
    }

    /// `gh pr list` in the focused folder, grouped by why each PR is yours.
    nonisolated private static func readProject(directory: String?, repository: String?, viewer: String?, closed: Bool) -> Outcome {
        guard let directory, let repository else { return Outcome(failure: .notRepository) }
        var viewer = viewer
        if viewer == nil {
            let me = LoginShell.run(["gh", "api", "user", "--jq", ".login"], in: directory)
            let login = me.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if me.status == 0, !login.isEmpty, !login.contains(" ") { viewer = login }
        }
        let result = LoginShell.run(PullRequestInbox.listArguments(closed: closed), in: directory)
        guard result.status == 0, let rows = PullRequestInbox.parseList(result.output, repository: repository, viewer: viewer) else {
            return Outcome(failure: result.status == 0
                           ? .other("gh's answer couldn't be read.")
                           : PullRequestLoadFailure.classify(status: result.status, output: result.output), viewer: viewer)
        }
        var outcome = Outcome(found: [:], viewer: viewer)
        for row in rows {
            outcome.found?[row.group, default: []].append(row.item)
            if let stats = row.stats {
                outcome.stats[row.item.id] = stats
                outcome.updatedAt[row.item.id] = row.item.updatedAt
            }
        }
        return outcome
    }

    // MARK: - Row stats

    /// Asks for a row's size and checks: it came into view.
    func want(_ item: PullRequestInboxItem) {
        if let cached = Self.statsCache[item.id], cached.updatedAt == item.updatedAt {
            if stats[item.id] != cached.stats { stats[item.id] = cached.stats }
            return
        }
        guard !inFlight.contains(item.id), !queue.contains(where: { $0.id == item.id }) else { return }
        queue.append(item)
        pump()
    }

    /// Sorting by size and the failing-checks filter need every row's
    /// stats, not just the rows on screen.
    private func wantStatsIfNeeded() {
        guard sort == .changes || filters.checksFailing, let found else { return }
        var seen = Set<String>()
        for item in found.values.joined() where seen.insert(item.id).inserted { want(item) }
    }

    private func restoreCachedStats() {
        guard let found else { return }
        for item in found.values.joined() {
            if let cached = Self.statsCache[item.id], cached.updatedAt == item.updatedAt, stats[item.id] != cached.stats {
                stats[item.id] = cached.stats
            }
        }
    }

    private func store(_ stats: PullRequestStats, for id: String, updatedAt: Date?) {
        Self.statsCache[id] = (updatedAt, stats)
        if self.stats[id] != stats { self.stats[id] = stats }
    }

    private func pump() {
        while inFlight.count < Self.maxConcurrent, !queue.isEmpty {
            let item = queue.removeFirst()
            inFlight.insert(item.id)
            DispatchQueue.global(qos: .utility).async {
                let result = LoginShell.run(PullRequestStats.arguments(for: item), in: NSHomeDirectory())
                let stats = result.status == 0 ? PullRequestStats.parse(result.output) : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.inFlight.remove(item.id)
                        if let stats { self.store(stats, for: item.id, updatedAt: item.updatedAt) }
                        self.pump()
                    }
                }
            }
        }
    }
}

// MARK: - The page

struct PullRequestsPage: View {
    @ObservedObject var model: PullRequestsPageModel
    @ObservedObject var store: SessionStore
    let close: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                PullRequestsList(model: model, close: close)
                    .frame(width: max(320, proxy.size.width * 0.45))
                Rectangle().fill(Theme.divider).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.terminalBackground)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onExitCommand {
            // Esc clears a search first, then leaves.
            if !model.queryText.isEmpty { model.queryText = "" } else { close() }
        }
        .background {
            // ⌥↑ / ⌥↓ step through the rows, as in the changes review.
            Group {
                Button("") { model.step(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("") { model.step(1) }.keyboardShortcut(.downArrow, modifiers: .option)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selected {
            let local = model.isLocal(item)
            // A PR elsewhere still runs gh from the focused folder (or
            // home): `-R` names its repository, so the folder doesn't matter.
            PullRequestPlane(directory: model.directory ?? NSHomeDirectory(),
                             number: item.number, repo: local ? nil : item.repository,
                             askAgent: { askAgent($0, about: item, local: local) },
                             onSummary: { _, _, _ in })
                // Another PR is another model: its repository may differ.
                .id(item.id)
        } else {
            Text(model.found == nil ? "" : "Pick a pull request to see it here.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sidebar)
        }
    }

    /// The agent in the focused folder. The plane's prompts say "gh pr view
    /// N", so a PR elsewhere gets its repository named up front.
    private func askAgent(_ prompt: String, about item: PullRequestInboxItem, local: Bool) {
        guard let directory = model.directory,
              let agent = DiffReviewView.agents(in: store, directory: directory).first else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in a project, then try again.")
            return
        }
        let text = local ? prompt : "This is about \(item.repository)#\(item.number); pass -R \(item.repository) to gh. " + prompt
        store.broadcast(text, to: [Broadcast.Target(paneId: agent.paneId,
                                                    name: DiffReviewView.name(agent, in: store), isAgent: true)])
    }
}

// MARK: - The list column

private struct PullRequestsList: View {
    @ObservedObject var model: PullRequestsPageModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Pull Requests")
                        .font(Theme.interfaceFont(17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if model.loading {
                        ProgressView().controlSize(.mini).accessibilityLabel("Refreshing")
                    }
                    Spacer()
                    OctetIconButton(icon: "xmark", help: "Close (Esc)", action: close)
                }
                OctetTextField(placeholder: "Search pull requests, or label:bug", text: $model.queryText)
                toolbar
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            content
        }
        .background(Theme.terminalBackground)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(PullRequestSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                OutlineMenuLabel(icon: "arrow.down", title: "Sort", active: model.sort != .updated)
            }
            .outlineMenu()
            .help("Sort: \(model.sort.title)")

            Menu {
                Section("State") {
                    toneToggle(.open, "Open")
                    toneToggle(.draft, "Draft")
                    toneToggle(.closed, "Closed")
                    toneToggle(.merged, "Merged")
                }
                Section {
                    Toggle("Review requested", isOn: $model.filters.reviewRequested)
                    Toggle("Checks failing", isOn: $model.filters.checksFailing)
                }
                if !model.filters.isDefault {
                    Divider()
                    Button("Reset Filters") { model.filters = PullRequestFilters() }
                }
            } label: {
                OutlineMenuLabel(icon: "slider.horizontal.3", title: "Filters", active: !model.filters.isDefault)
            }
            .outlineMenu()

            Menu {
                Button { model.scope = .all } label: { checked(model.scope == .all, "All repositories") }
                Button { model.scope = .project } label: {
                    checked(model.scope == .project, model.projectRepository.map { "This project (\($0))" } ?? "This project")
                }
                .disabled(model.directory == nil)
                let repositories = model.repositories
                if !repositories.isEmpty {
                    Divider()
                    ForEach(repositories, id: \.self) { name in
                        Button { model.scope = .repository(name) } label: { checked(model.scope == .repository(name), name) }
                    }
                }
            } label: {
                OutlineMenuLabel(icon: "folder", title: model.scope.title, active: model.scope != .all)
            }
            .outlineMenu()
            .help("Where to look")

            Spacer(minLength: 0)
            OctetIconButton(icon: "arrow.clockwise", help: "Refresh") { model.refresh() }
                .disabled(model.loading)
        }
    }

    private func toneToggle(_ tone: PullRequestTone, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.filters.tones.contains(tone) },
            set: { on in
                if on { model.filters.tones.insert(tone) } else { model.filters.tones.remove(tone) }
            }))
    }

    @ViewBuilder
    private func checked(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, model.found == nil {
            message(failure.title, failure.remedy)
        } else if model.found != nil {
            let sections = model.sections
            if sections.isEmpty {
                message(model.query.isEmpty && model.filters.isDefault ? "No pull requests involve you." : "No pull requests match.",
                        model.query.isEmpty && model.filters.isDefault ? nil : "Try another search, or reset the filters.")
            } else {
                let selectedId = model.selected?.id
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections, id: \.group) { section in
                            OctetShelfHeader(icon: section.group.icon, title: section.group.title, count: section.items.count)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 8)
                            ForEach(section.items) { item in
                                PullRequestsRow(item: item, stats: model.stats[item.id], selected: item.id == selectedId) {
                                    model.selectedId = item.id
                                }
                                .onAppear { model.want(item) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                .octetScrollIndicators()
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.card).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.card).frame(width: 200, height: 10)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityLabel("Loading pull requests")
        }
    }

    private func message(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One PR: state glyph, number and title, checks and size; then who, where
/// and when.
private struct PullRequestsRow: View {
    let item: PullRequestInboxItem
    let stats: PullRequestStats?
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    OctetIcon(item.tone.icon, size: 13)
                        .foregroundStyle(item.tone.color)
                    Text(verbatim: "#\(item.number)")
                        .font(Theme.uiFont.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.title)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let stats {
                        if stats.checks.tone != .none {
                            OctetIcon(PullRequestStyle.checksIcon(stats.checks.tone), size: 12)
                                .foregroundStyle(PullRequestStyle.checksColor(stats.checks.tone))
                                .help(stats.checks.text)
                        }
                        DiffStatLabel(added: stats.additions, removed: stats.deletions)
                            .font(Theme.captionFont.monospacedDigit())
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    GitHubAvatar(login: item.author, size: 14)
                    Text(item.author)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(item.repository)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(PullRequestJSON.ago(item.updatedAt))
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
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(item.isDraft ? "Draft: \(item.title)" : item.title)
        .accessibilityLabel("\(item.repository) #\(item.number) \(item.title) by \(item.author)\(item.isDraft ? ", draft" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let url = item.url {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }
}

// MARK: - Outline menu buttons

/// The toolbar's outline buttons: a hairline border, no fill until hovered,
/// and the label in the primary colour while it narrows the list.
private struct OutlineMenuLabel: View {
    let icon: String
    let title: String
    var active = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            OctetIcon(icon, size: 12)
            Text(title).font(Theme.uiFontMedium).lineLimit(1)
            OctetIcon("chevron.down", size: 9).foregroundStyle(Theme.textTertiary)
        }
        .foregroundStyle(active || hovered ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(active ? Theme.textTertiary : Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private extension View {
    func outlineMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
