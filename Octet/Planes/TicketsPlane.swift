import SwiftUI

/// A project's issues from GitHub (through gh) or from Linear and Jira
/// (through their own APIs, with credentials the Keychain keeps).
struct TicketsPlane: View {
    let directory: String?
    @State private var provider: IssueTracker = {
        #if DEBUG
        // OCTET_TICKETS_PROVIDER=Linear (or Jira) opens the pane on that tracker, for screenshots.
        return ProcessInfo.processInfo.environment["OCTET_TICKETS_PROVIDER"].flatMap(IssueTracker.init(rawValue:)) ?? .github
        #else
        return .github
        #endif
    }()
    @State private var connections: [TrackerConnection] = []
    @State private var connectionId = ""
    @State private var adding = false
    @State private var draft = TrackerCredentials()
    @State private var connecting = false
    @State private var connectFailure: String?
    @State private var containers: [TrackerContainer] = []
    @State private var container = ""
    @State private var board = false
    @State private var boardSession = UUID()
    @State private var draggedIssue: String?
    @State private var dragToken = ""
    @State private var boardTargets: [String] = []
    @State private var movingIssue: String?
    @State private var boardRevision = 0
    private var boardContext: [String] { [provider.rawValue, project, connectionId, container, scope, who.rawValue, savedFilter] }
    @State private var savedFilter = ""
    @State private var filterFailure: String?
    @State private var savedFilters: [TrackerContainer] = []
    @State private var query = ""
    @State private var expanded = Set<String>()
    @State private var scope = "open"
    @State private var who = IssueWho.anyone
    @State private var issues: [TrackerIssue] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var refresh = 0
    private var project: String { directory.map { AccountProfiles.projectRoot(of: $0) ?? $0 } ?? "" }
    private var projectName: String { URL(fileURLWithPath: project).lastPathComponent }
    private var connection: TrackerConnection? { connections.first { $0.id == connectionId } }
    /// The first connection keeps the key it had before there could be several.
    private var containerKey: String {
        "octet.tickets.\(provider.rawValue).\(project)" + (connectionId == TrackerConnection.legacyId ? "" : ".\(connectionId)")
    }
    private var connectionKey: String { "octet.tickets.connection.\(provider.rawValue).\(project)" }
    private var connected: Bool { provider == .github || connection != nil }
    private var filter: IssueFilter { IssueFilter(scope: scope, who: who, savedFilter: savedFilter.isEmpty ? nil : savedFilter) }

    /// Same as `ServiceSample`: the made-up list the demo hook shows.
    private var sampling: Bool { ServiceSample.shows("tickets") }

    var body: some View {
        VStack(spacing: 0) {
            ServiceHeader(title: "Issues", count: headerCount, loading: loading) {
                if provider != .github, connection != nil {
                    OctetIconButton(icon: "ellipsis", help: "\(provider.rawValue) connections") { presentConnectionMenu() }
                }
                if connected, !project.isEmpty {
                    OctetIconButton(icon: "arrow.clockwise", help: "Refresh issues") { refresh += 1 }.disabled(loading)
                }
            }
            ViewThatFits(in: .horizontal) {
                OctetSegmented(selection: $provider, items: IssueTracker.allCases.map { (value: $0, title: $0.rawValue) })
                OctetSelect(selection: $provider, options: IssueTracker.allCases.map { (value: $0, title: $0.rawValue) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PullRequestStyle.horizontalPadding).padding(.bottom, 8)
            if project.isEmpty {
                message("No project in front", "Open a project to view its issues.")
            } else if !connected || adding {
                connectCard
            } else {
                tracker
            }
        }
        .background(Theme.sidebar).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: provider, initial: true) { _, now in
            // Another tracker's list isn't this one's.
            issues = []; loaded = false; failure = nil; expanded = []; containers = []
            savedFilters = []; savedFilter = ""; filterFailure = nil
            connectFailure = nil; draft = TrackerCredentials(); adding = false
            connections = now == .github ? [] : IssueService.connections(now)
            let saved = UserDefaults.standard.string(forKey: connectionKey) ?? ""
            connectionId = connections.first { $0.id == saved }?.id ?? connections.first?.id ?? ""
        }
        .onChange(of: boardContext) { _, _ in
            boardSession = UUID(); draggedIssue = nil; dragToken = ""; boardTargets = []; movingIssue = nil
        }
        .task(id: "\(provider.rawValue):\(project):\(connectionId)") { await loadContainers() }
        .task(id: "\(provider.rawValue):\(project):\(connectionId):\(scope):\(who.rawValue):\(container):\(refresh):\(containers.count):\(savedFilter)") { await loadIssues() }
    }

    private var headerCount: String? {
        if project.isEmpty { return nil }
        guard connected, loaded else { return projectName }
        let base = "\(issues.count) \(scope == "all" ? "" : scope)".trimmingCharacters(in: .whitespaces)
        return who == .anyone ? base : base + " · " + who.title.lowercased()
    }

    // MARK: Connecting

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(adding ? "Add a \(provider.rawValue) connection" : "Connect \(provider.rawValue)").font(Theme.uiFontMedium)
            Text(provider == .linear
                 ? "Paste a personal API key; each key is one workspace. It's kept in your Keychain and sent only to api.linear.app."
                 : draft.server
                 ? "Your site over https, a username and password (or leave the username empty to use a personal access token). They're kept in your Keychain and sent only to your Jira site."
                 : "Use your site, your account's email and an API token (scoped tokens work too). They're kept in your Keychain and sent only to Atlassian.")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            if provider == .jira {
                OctetSegmented(selection: $draft.server, items: [(value: false, title: "Cloud"), (value: true, title: "Self-hosted")])
                OctetTextField(placeholder: draft.server ? "Site, e.g. jira.example.com" : "Site, e.g. acme.atlassian.net", text: $draft.site, label: "Jira site")
                OctetTextField(placeholder: draft.server ? "Username (empty for a token)" : "Account email", text: $draft.email, label: "Jira account")
            }
            OctetTextField(placeholder: provider == .linear ? "API key" : draft.server ? "Password or access token" : "API token", text: $draft.token, secure: true,
                           label: "\(provider.rawValue) token") { connect() }
            HStack(spacing: 6) {
                OctetButton(title: connecting ? "Connecting…" : "Connect", compact: true) { connect() }
                    .disabled(connecting || !draftComplete)
                if !draft.server {
                    OctetButton(title: provider == .linear ? "Create a key" : "Create a token", icon: "arrow.up.right", kind: .ghost, compact: true) {
                        NSWorkspace.shared.open(provider == .linear
                            ? URL(string: "https://linear.app/settings/account/security")!
                            : URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    }
                }
                if adding { OctetButton(title: "Cancel", kind: .ghost, compact: true) { adding = false; connectFailure = nil } }
            }
            if let connectFailure { ServiceBanner(text: connectFailure).padding(.horizontal, -8) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PullRequestStyle.horizontalPadding).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var draftComplete: Bool {
        let token = !draft.token.trimmingCharacters(in: .whitespaces).isEmpty
        if provider == .linear { return token }
        guard token, JiraAPI.baseURL(draft.site, keepPath: draft.server) != nil else { return false }
        return draft.server || draft.email.contains("@")
    }

    /// Checks the credentials by asking for the teams or projects they can
    /// see, and keeps them only if that works.
    private func connect() {
        guard draftComplete, !connecting else { return }
        var trial = draft
        trial.token = trial.token.trimmingCharacters(in: .whitespacesAndNewlines)
        trial.site = trial.site.trimmingCharacters(in: .whitespacesAndNewlines)
        trial.email = trial.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracker = provider
        connecting = true
        connectFailure = nil
        Task {
            do {
                if tracker == .linear {
                    let found = try await IssueConnection.linearTeams(token: trial.token)
                    trial.name = found.workspace
                } else {
                    trial = try await IssueConnection.jiraConnect(trial).credentials
                }
                guard tracker == provider else { return }
                let saved = try IssueCredentialStore.add(trial, for: tracker)
                connections = IssueService.connections(tracker)
                chooseConnection(saved.id)
                adding = false
                draft = TrackerCredentials()
            } catch {
                connectFailure = error.localizedDescription
            }
            connecting = false
        }
    }

    private func chooseConnection(_ id: String) {
        guard id != connectionId else { return }
        connectionId = id
        UserDefaults.standard.set(id, forKey: connectionKey)
        issues = []; loaded = false; failure = nil; expanded = []; containers = []; container = ""
    }

    private func presentConnectionMenu() {
        let tracker = provider
        var items: [OctetMenuItem] = [.header("\(tracker.rawValue) connections")]
        for item in connections {
            items.append(.action(item.displayName, icon: item.id == connectionId ? "check" : nil) { chooseConnection(item.id) })
        }
        items.append(.divider)
        items.append(.action("Add connection…", icon: "plus") { draft = TrackerCredentials(); connectFailure = nil; adding = true })
        if let current = connection {
            items.append(.action("Disconnect \(current.displayName)", icon: "trash", destructive: true) {
                IssueCredentialStore.remove(current)
                connections = IssueService.connections(tracker)
                connectionId = connections.first?.id ?? ""
                UserDefaults.standard.set(connectionId, forKey: connectionKey)
                containers = []; container = ""; issues = []; loaded = false; failure = nil; expanded = []
            })
        }
        OctetContextMenu.present(items)
    }

    // MARK: Listing

    private var tracker: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { pickers }
                VStack(alignment: .leading, spacing: 6) { pickers }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PullRequestStyle.horizontalPadding).padding(.bottom, 8)
            if let filterFailure { ServiceBanner(text: filterFailure) }
            HStack {
                OctetButton(title: board ? "List" : "Board", icon: board ? "list.bullet" : "rectangle.split.3x1", compact: true) { board.toggle() }
                if provider == .jira, !savedFilters.isEmpty {
                    OctetSelect(selection: $savedFilter, options: [(value: "", title: "All project issues")] + savedFilters.map { (value: $0.id, title: $0.name) })
                }
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 8)
            ServiceFilterBar(placeholder: "Filter by title, label or key…", query: $query, scope: $scope,
                             scopes: [("open", "Open"), ("closed", "Closed"), ("all", "All")])
            if provider != .github, containers.isEmpty, failure == nil, loaded || !loading {
                message("No \(provider.containerNoun)s", "This account can't see any \(provider.containerNoun)s. Check its access in \(provider.rawValue).")
            } else if !loaded && failure == nil {
                ServiceListSkeleton()
            } else if let failure, issues.isEmpty {
                message("Couldn't load issues", failure)
            } else if issues.isEmpty {
                message("No \(scope == "all" ? "" : scope + " ")issues", "\(provider.rawValue) issues for this \(provider == .github ? "repository" : provider.containerNoun) will appear here.")
            } else {
                let filtered = issues.filter {
                    query.isEmpty || "\($0.key) \($0.title) \($0.labels.map(\.name).joined(separator: " "))".localizedCaseInsensitiveContains(query)
                }
                if filtered.isEmpty { message("No matches", "Try another title, label or issue key.") }
                else if board {
                    if let failure { ServiceBanner(text: failure) }
                    if movingIssue != nil { ProgressView("Updating issue…").font(Theme.captionFont) }
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(Set(filtered.map(\.stateName) + boardTargets + (provider == .github ? ["Open", "Closed"] : []))).sorted(), id: \.self) { state in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(state.isEmpty ? "No status" : state).font(Theme.uiFontMedium)
                                    ForEach(filtered.filter { $0.stateName == state }) { issue in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Button { if expanded.contains(issue.id) { expanded.remove(issue.id) } else { expanded.insert(issue.id) } } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(issue.key).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                                                    Text(issue.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain)
                                            if expanded.contains(issue.id) { detail(issue) }
                                        }.padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .disabled(movingIssue != nil)
                                        .onDrag { beginBoardDrag(issue) }
                                    }
                                }.frame(width: 300, alignment: .topLeading)
                                .frame(minHeight: 120, alignment: .topLeading)
                                .contentShape(Rectangle())
                                .dropDestination(for: String.self) { tokens, _ in
                                    guard tokens == [dragToken], !dragToken.isEmpty, movingIssue == nil,
                                          let issue = issues.first(where: { $0.id == draggedIssue }), issue.stateName != state else { return false }
                                    moveOnBoard(issue, destination: state)
                                    return true
                                }
                            }
                        }.padding(12)
                    }
                }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if let failure { ServiceBanner(text: failure) }
                            ForEach(filtered) { issue in
                                ServiceRow(icon: issue.closed ? "circle.check" : "circle.dot", tone: issue.closed ? .merged : .good,
                                           title: issue.title, subtitle: subtitle(issue),
                                           open: Binding(
                                    get: { expanded.contains(issue.id) },
                                    set: { if $0 { expanded.insert(issue.id) } else { expanded.remove(issue.id) } }
                                ), trailing: {
                                    if issue.comments > 0 {
                                        HStack(spacing: 3) {
                                            OctetIcon("message", size: 11)
                                            Text("\(issue.comments)").font(Theme.captionFont.monospacedDigit())
                                        }.foregroundStyle(Theme.textTertiary).help("\(issue.comments) comments")
                                    }
                                }) { detail(issue) }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 12)
                    }.octetScrollIndicators()
                }
            }
        }
    }

    private func subtitle(_ issue: TrackerIssue) -> String {
        [issue.key, provider == .github || issue.stateName.isEmpty ? nil : issue.stateName, issue.person,
         "updated \(ServiceTime.ago(issue.updatedAt))"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The team or project, then whose issues.
    @ViewBuilder private var pickers: some View {
        if provider != .github, containers.count > 1 {
            Text(provider.containerNoun.capitalized).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            OctetSelect(selection: Binding(get: { container }, set: { chooseContainer($0) }),
                        options: containers.map { (value: $0.id, title: $0.name) })
        }
        OctetSelect(selection: $who, options: IssueWho.allCases.map { (value: $0, title: $0.title) })
        Spacer(minLength: 0)
    }

    private func detail(_ issue: TrackerIssue) -> some View {
        IssueDetailView(issue: issue, tracker: provider, connectionId: provider == .github ? nil : connectionId, directory: project) { next in
            if let index = issues.firstIndex(where: { $0.id == next.id }) { issues[index] = next }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        PlaneServiceMessage(icon: "tickets", title: title, detail: detail)
    }

    // MARK: Loading

    private func chooseContainer(_ id: String) {
        container = id
        UserDefaults.standard.set(id, forKey: containerKey)
        issues = []; loaded = false; expanded = []
    }

    /// The teams or projects the account can see, for Linear and Jira; the
    /// pick the project last made is kept.
    @MainActor private func loadContainers() async {
        guard provider != .github, connection != nil, !project.isEmpty else { return }
        let tracker = provider, id = connectionId
        savedFilter = ""; savedFilters = []; filterFailure = nil
        do {
            let found = try await IssueService.containers(tracker, connectionId: id)
            guard tracker == provider, id == connectionId else { return }
            containers = found
            // A name learned on the way (a Linear workspace) shows in the list.
            connections = IssueService.connections(tracker)
            if tracker == .jira, let connection = try? IssueService.connection(tracker, id) {
                do {
                    let filters = try await IssueConnection.jiraSavedFilters(connection.credentials)
                    guard tracker == provider, id == connectionId else { return }
                    savedFilters = filters
                } catch { filterFailure = "Couldn't load saved filters. \(error.localizedDescription)" }
            }
            let saved = UserDefaults.standard.string(forKey: containerKey) ?? ""
            container = found.contains { $0.id == saved } ? saved : found.first?.id ?? ""
            failure = nil
        } catch {
            guard tracker == provider, id == connectionId else { return }
            failure = error.localizedDescription
            loaded = true
        }
    }

    @MainActor private func beginBoardDrag(_ issue: TrackerIssue) -> NSItemProvider {
        guard movingIssue == nil else { return NSItemProvider() }
        let token = UUID().uuidString, session = boardSession, context = boardContext
        dragToken = token; draggedIssue = issue.id; boardTargets = []
        let tracker = provider, connection = connectionId
        Task {
            do {
                let statuses = try await IssueService.statuses(tracker: tracker, issue: issue, connectionId: connection)
                guard session == boardSession, context == boardContext, token == dragToken else { return }
                boardTargets = statuses.map(\.name)
            } catch {
                guard session == boardSession, context == boardContext, token == dragToken else { return }
                failure = error.localizedDescription
            }
        }
        return NSItemProvider(object: token as NSString)
    }

    @MainActor private func moveOnBoard(_ issue: TrackerIssue, destination: String) {
        let session = boardSession, context = boardContext
        let tracker = provider, connection = connectionId, cwd = project
        movingIssue = issue.id; dragToken = ""; failure = nil; boardRevision += 1
        Task {
            defer {
                if session == boardSession, context == boardContext {
                    movingIssue = nil; draggedIssue = nil; boardTargets = []
                    boardRevision += 1
                }
            }
            do {
                // Refetch per-issue transitions at drop time; drag-time columns are only hints.
                let allowed = try await IssueService.statuses(tracker: tracker, issue: issue, connectionId: connection)
                guard session == boardSession, context == boardContext else { return }
                let status = try IssueBoardMove.resolve(destination: destination, current: issue.stateName, allowed: allowed)
                guard let index = issues.firstIndex(where: { $0.id == issue.id }) else { return }
                issues[index].stateName = status.name; issues[index].closed = status.closed
                do {
                    try await IssueService.setStatus(tracker: tracker, issue: issue, to: status, connectionId: connection, directory: cwd)
                } catch {
                    if session == boardSession, context == boardContext,
                       let index = issues.firstIndex(where: { $0.id == issue.id }) { issues[index] = issue }
                    throw error
                }
                guard session == boardSession, context == boardContext else { return }
                // Requery after success so scope and saved filters reflect the server's result.
                refresh += 1
            } catch {
                guard session == boardSession, context == boardContext else { return }
                failure = error.localizedDescription
            }
        }
    }

    @MainActor private func loadIssues() async {
        guard connected, !project.isEmpty else { return }
        if provider != .github, container.isEmpty { return }
        loading = true
        defer { loading = false }
        let tracker = provider, cwd = project, pick = container, id = connectionId, wanted = filter
        let context = boardContext, revision = boardRevision
        do {
            let next = try await IssueService.list(tracker: tracker, connectionId: tracker == .github ? nil : id,
                                                   container: pick, filter: wanted, directory: cwd)
            guard !Task.isCancelled, context == boardContext, revision == boardRevision, movingIssue == nil else { return }
            // A refresh keeps the list it had; the scope changing starts clean.
            IssueCommentCache.store = [:]
            issues = next
            failure = nil
            loaded = true
            if sampling, tracker == .github { expanded = ["142"] }
            else if sampling, expanded.isEmpty, let first = next.first { expanded = [first.id] }
        } catch {
            guard !Task.isCancelled, context == boardContext, revision == boardRevision, movingIssue == nil else { return }
            failure = error.localizedDescription
            loaded = true
        }
    }
}
