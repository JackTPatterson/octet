import SwiftUI

/// Workflow runs for the project in front, from `gh run list`.
struct OperationsPlane: View {
    let kind: PlaneKind
    let directory: String?
    @State private var items: [OperationItem] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var failure: String?
    @State private var query = ""
    @State private var scope = "all"
    @State private var selected: String?
    @State private var refresh = 0
    private var filtered: [OperationItem] {
        items.filter { item in
            (query.isEmpty || "\(item.title) \(item.workflow) \(item.branch) \(item.status)".localizedCaseInsensitiveContains(query)) &&
            (scope == "all" || (scope == "failed" ? item.tone == .bad : item.tone == .pending))
        }
    }
    private var failing: Int { items.filter { $0.tone == .bad }.count }
    private var running: Int { items.filter { $0.tone == .pending }.count }
    private var project: String { directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            ServiceHeader(title: "CI", count: loaded ? summary : project, loading: loading) {
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh workflow runs") { refresh += 1 }.disabled(loading)
            }
            if directory != nil, loaded || failure == nil {
                ServiceFilterBar(placeholder: "Filter runs, workflows or branches…", query: $query, scope: $scope,
                                 scopes: [("all", "All"), ("failed", "Failed"), ("running", "Running")])
            }
            content
        }
        .foregroundStyle(Theme.textPrimary).background(Theme.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(kind.rawValue):\(directory ?? ""):\(refresh)") { await load() }
        .task(id: directory) {
            // Runs finish while the pane is open; keep the list honest.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !loading, directory != nil else { continue }
                refresh += 1
            }
        }
    }

    private var summary: String {
        var parts = ["\(items.count) runs"]
        if failing > 0 { parts.append("\(failing) failed") }
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if directory == nil {
            PlaneServiceMessage(icon: kind.icon, title: "No project in front", detail: "Open a repository to see its workflow runs.")
        } else if !loaded && failure == nil {
            ServiceListSkeleton()
        } else if let failure, items.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: "Couldn't load CI runs", detail: failure)
        } else if items.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: "No workflow runs", detail: "GitHub Actions runs will appear here once a workflow runs in this repository.")
        } else if filtered.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: "No matches", detail: "Try a different name, branch or status.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let failure { ServiceBanner(text: "Showing the last results. " + failure) }
                    ForEach(filtered) { item in
                        ServiceRow(icon: item.icon, tone: item.tone, title: item.title,
                                   subtitle: "\(item.workflow) · \(item.branch) · \(ServiceTime.ago(item.createdAt))",
                                   open: Binding(get: { selected == item.id }, set: { selected = $0 ? item.id : nil }),
                                   trailing: { ServiceStatusLabel(text: item.statusText, tone: item.tone) }) {
                            detail(item)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }.octetScrollIndicators()
        }
    }

    private func detail(_ item: OperationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ServiceFacts(rows: [
                ("Run", "#\(item.id)" + (item.attempt > 1 ? " · attempt \(item.attempt)" : "")),
                ("Workflow", item.workflow),
                ("Branch", item.branch),
                ("Event", item.event),
                ("Started", ServiceTime.full(item.createdAt)),
            ] + (ServiceTime.duration(from: item.createdAt, to: item.updatedAt).map { [("Duration", $0)] } ?? []))
            HStack(spacing: 6) {
                if let url = item.url {
                    OctetButton(title: "View on GitHub", icon: "arrow.up.right", kind: .secondary, compact: true) { NSWorkspace.shared.open(url) }
                    OctetButton(title: "Copy link", icon: "link.badge.plus", kind: .ghost, compact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
        }
    }

    /// A refresh keeps the list it had; only a failure with nothing to show
    /// replaces the pane.
    @MainActor private func load() async {
        guard let cwd = directory else { loaded = false; items = []; return }
        loading = true
        let sample = ServiceSample.shows("ci")
        let result = await Task.detached(priority: .userInitiated) {
            if sample { return LoginShell.Result(status: 0, output: ServiceSample.runs) }
            return LoginShell.run(["gh", "run", "list", "--limit", "30", "--json", "databaseId,displayTitle,workflowName,headBranch,status,conclusion,url,event,createdAt,updatedAt,attempt"], in: cwd)
        }.value
        guard !Task.isCancelled else { return }
        loading = false
        guard result.status == 0 else {
            failure = "Check that GitHub CLI is installed and signed in with gh auth login.\n\n" + result.output
            return
        }
        do {
            let next = try OperationItem.parse(result.output, ci: true)
            if next.map(\.id) != items.map(\.id) || next.map(\.status) != items.map(\.status) { items = next }
            failure = nil
            loaded = true
            if sample { selected = "9020" }
            if let selected, !items.contains(where: { $0.id == selected }) { self.selected = nil }
        } catch { failure = "Couldn't read the response. Refresh to try again.\n\(error.localizedDescription)" }
    }
}

struct PlaneServiceMessage: View {
    let icon, title, detail: String
    var body: some View {
        PlaneMessage(icon: icon, title: title, detail: detail.isEmpty ? nil : detail)
    }
}

struct OperationItem: Identifiable {
    let id, title, subtitle, status, detail: String
    var url: URL?
    /// CI facts for the row and its details; empty for container rows.
    var workflow = "", branch = "", event = "", createdAt = "", updatedAt = ""
    var attempt = 1

    var tone: ServiceTone {
        switch status.lowercased() {
        case "success", "running": .good
        case "failure", "timed_out", "dead", "startup_failure": .bad
        case "in_progress", "queued", "waiting", "restarting", "pending", "requested": .pending
        default: .idle
        }
    }
    var icon: String {
        switch tone {
        case .good: "circle.check"
        case .bad: "circle.x"
        case .pending: "circle.dot"
        default: status.lowercased() == "cancelled" ? "circle.x" : "circle.dot"
        }
    }
    var statusText: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
    var tint: Color {
        switch status.lowercased() {
        case "success", "running": return .green
        case "failure", "timed_out", "dead": return .red
        case "in_progress", "queued", "waiting", "restarting": return .orange
        default: return Theme.textSecondary
        }
    }

    static func parse(_ output: String, ci: Bool) throws -> [Self] {
        if ci {
            return try JSONDecoder().decode([Run].self, from: Data(output.utf8)).map {
                Self(id: String($0.databaseId), title: $0.displayTitle, subtitle: "\($0.workflowName) · \($0.headBranch)",
                     status: $0.conclusion.flatMap { $0.isEmpty ? nil : $0 } ?? $0.status,
                     detail: "Run #\($0.databaseId)\n\($0.event) · \($0.createdAt)", url: URL(string: $0.url),
                     workflow: $0.workflowName, branch: $0.headBranch, event: $0.event,
                     createdAt: $0.createdAt, updatedAt: $0.updatedAt ?? $0.createdAt, attempt: $0.attempt ?? 1)
            }
        }
        return try output.split(separator: "\n").map { line in
            let row = try JSONDecoder().decode(Container.self, from: Data(line.utf8))
            return Self(id: row.id, title: row.names ?? "Container", subtitle: row.image ?? "",
                        status: row.state ?? "unknown", detail: [row.id, row.status, row.ports].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    /// Decode only the fields used by the pane. Docker may return other value
    /// types, such as the nested Platform object, alongside these strings.
    private struct Container: Decodable {
        let id: String
        let names, image, state, status, ports: String?

        enum CodingKeys: String, CodingKey {
            case id = "ID", names = "Names", image = "Image"
            case state = "State", status = "Status", ports = "Ports"
        }
    }

    private struct Run: Decodable {
        let databaseId: Int
        let displayTitle, workflowName, headBranch, status, url, event, createdAt: String
        let conclusion: String?
        let updatedAt: String?
        let attempt: Int?
    }
}
