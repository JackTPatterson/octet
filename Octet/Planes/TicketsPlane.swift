import SwiftUI
import WebKit

/// Native GitHub issues, plus authenticated project boards for other trackers.
struct TicketsPlane: View {
    let directory: String?
    @State private var provider = "GitHub"
    @State private var address = ""
    @State private var savedAddress = ""
    @State private var query = ""
    @State private var expanded = Set<Int>()
    @State private var scope = "open"
    @State private var issues: [ProjectIssue] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var refresh = 0
    private let providers = ["GitHub", "Jira", "Linear", "Other"]
    private var project: String { directory.map { AccountProfiles.projectRoot(of: $0) ?? $0 } ?? "" }
    private var preferenceKey: String { "octet.tickets.board.\(project).\(provider)" }
    private var validAddress: URL? { Self.boardURL(address) }

    static func boardURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tickets").font(Theme.uiFontMedium)
                Spacer()
                Text(project.isEmpty ? "No project" : URL(fileURLWithPath: project).lastPathComponent)
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.padding(.horizontal, 12).frame(height: 36)
            ViewThatFits(in: .horizontal) {
                OctetSegmented(selection: $provider, items: providers.map { (value: $0, title: $0) })
                OctetSelect(selection: $provider, options: providers.map { (value: $0, title: $0) })
            }.padding(.horizontal, 12).padding(.bottom, 10)
            if project.isEmpty {
                message("No project in front", "Open a project to view its tickets and connect its boards.")
            } else if provider == "GitHub" {
                github
            } else {
                HStack {
                    OctetTextField(placeholder: "HTTPS project or board URL", text: $address) { saveBoard() }
                    OctetButton(title: "Save", compact: true) { saveBoard() }.disabled(validAddress == nil)
                }.padding(.horizontal, 12).padding(.bottom, 10)
                if let url = Self.boardURL(savedAddress) {
                    TicketBoard(url: url).id("\(project):\(provider):\(savedAddress)")
                } else {
                    message("Connect \(provider == "Other" ? "a tracker" : provider)", "Paste this project's board URL above. View the board here and sign in when prompted. The link is saved for this project.")
                }
            }
        }
        .background(Theme.sidebar).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: preferenceKey, initial: true) { _, key in
            savedAddress = UserDefaults.standard.string(forKey: key) ?? ""
            address = savedAddress
        }
        .task(id: "\(project):\(provider):\(scope):\(refresh)") { await loadIssues() }
    }

    private var github: some View {
        VStack(spacing: 0) {
            HStack {
                OctetTextField(placeholder: "Filter issues…", text: $query)
                OctetSelect(selection: $scope, options: [(value: "open", title: "Open"), (value: "closed", title: "Closed"), (value: "all", title: "All")], width: 80)
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh issues") { refresh += 1 }.disabled(loading)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if loading {
                ProgressView("Loading issues…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                message("Couldn't load issues", failure)
            } else if issues.isEmpty {
                message("No \(scope == "all" ? "" : scope + " ")issues", "GitHub issues for this repository will appear here.")
            } else {
                let filtered = issues.filter { query.isEmpty || "#\($0.number) \($0.title)".localizedCaseInsensitiveContains(query) }
                if filtered.isEmpty { message("No matches", "Try another title or issue number.") }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { issue in
                                OctetCollapsible(title: issue.title, open: Binding(
                                    get: { expanded.contains(issue.number) },
                                    set: { if $0 { expanded.insert(issue.number) } else { expanded.remove(issue.number) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("#\(issue.number) · \(issue.state.capitalized) · \(issue.author?.login ?? "Unknown author")")
                                            .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                                        if !issue.labels.isEmpty {
                                            Text(issue.labels.map(\.name).joined(separator: " · ")).font(Theme.captionFont).foregroundStyle(Theme.accent)
                                        }
                                        Text(issue.body.isEmpty ? "No description provided." : issue.body).font(Theme.captionFont).textSelection(.enabled)
                                        if let url = URL(string: issue.url) {
                                            OctetButton(title: "View issue on GitHub", icon: "arrow.up.right", kind: .ghost, compact: true) { NSWorkspace.shared.open(url) }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                                }.padding(.horizontal, 12)
                                Divider()
                            }
                            Text("Showing the latest \(issues.count) issues").font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(12)
                        }
                    }.octetScrollIndicators()
                }
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        PlaneServiceMessage(icon: "tickets", title: title, detail: detail)
    }

    private func saveBoard() {
        guard let url = validAddress else { return }
        savedAddress = url.absoluteString
        UserDefaults.standard.set(savedAddress, forKey: preferenceKey)
    }

    @MainActor private func loadIssues() async {
        guard provider == "GitHub", !project.isEmpty else { return }
        loading = true
        failure = nil
        issues = []
        expanded = []
        let cwd = project, state = scope
        let result = await Task.detached(priority: .userInitiated) {
            LoginShell.run(["gh", "issue", "list", "--state", state, "--limit", "100", "--json", "number,title,body,state,url,author,labels"], in: cwd)
        }.value
        guard !Task.isCancelled else { return }
        loading = false
        guard result.status == 0 else { failure = "Check GitHub CLI sign-in with gh auth login.\n\n" + result.output; return }
        do { issues = try JSONDecoder().decode([ProjectIssue].self, from: Data(result.output.utf8)) }
        catch { failure = "Couldn't read the issue list. \(error.localizedDescription)" }
    }
}

struct ProjectIssue: Decodable, Identifiable {
    var id: Int { number }
    let number: Int
    let title, body, state, url: String
    let author: Author?
    let labels: [Label]
    struct Author: Decodable { let login: String }
    struct Label: Decodable { let name: String }
}

private struct TicketBoard: View {
    let url: URL
    @StateObject private var page = BrowserPage(private: false)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                OctetIconButton(icon: "arrow.left", help: "Back") { page.view.goBack() }.disabled(!page.canGoBack)
                OctetIconButton(icon: "arrow.clockwise", help: "Reload board") { page.reload() }
                Spacer()
                if page.loading { ProgressView().controlSize(.small) }
                OctetIconButton(icon: "arrow.up.right", help: "Open in browser") { NSWorkspace.shared.open(page.pageURL ?? url) }
            }.padding(.horizontal, 12).frame(height: 32)
            ZStack {
                TicketWebView(page: page).opacity(page.failure == nil ? 1 : 0)
                if let failure = page.failure {
                    PlaneServiceMessage(icon: "tickets", title: "Couldn't load this board", detail: "Try reloading or opening it in your browser.\n\(failure.message)")
                }
            }
        }.onAppear { if page.pageURL == nil { page.load(url) } }
    }
}

private struct TicketWebView: NSViewRepresentable {
    let page: BrowserPage
    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
