import SwiftUI

struct OperationsPlane: View {
    let kind: PlaneKind
    let directory: String?
    @State private var items: [OperationItem] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var query = ""
    @State private var selected: String?
    @State private var refresh = 0
    private var isCI: Bool { kind == .ci }
    private var filtered: [OperationItem] {
        items.filter { query.isEmpty || "\($0.title) \($0.subtitle) \($0.status)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(kind.title).font(Theme.uiFontMedium)
                Text("\(items.count)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh \(kind.title)") { refresh += 1 }.disabled(loading)
            }.padding(.horizontal, 12).frame(height: 36)
            HStack {
                OctetIcon(isCI ? "branch" : "containers", size: 12)
                Text(isCI ? (directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project") : "Current Docker context · all containers")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.font(Theme.captionFont).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.bottom, 10)
            OctetTextField(placeholder: isCI ? "Filter workflow runs…" : "Filter containers…", text: $query).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            content
        }
        .foregroundStyle(Theme.textPrimary).background(Theme.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(kind.rawValue):\(directory ?? ""):\(refresh)") { await load() }
    }

    @ViewBuilder private var content: some View {
        if isCI && directory == nil {
            PlaneServiceMessage(icon: kind.icon, title: "No project in front", detail: "Open a repository to see its workflow runs.")
        } else if let failure {
            PlaneServiceMessage(icon: kind.icon, title: "Couldn't load \(isCI ? "CI runs" : "containers")", detail: failure)
        } else if loading && items.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: "Loading \(isCI ? "workflow runs" : "containers")…", detail: "")
        } else if items.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: isCI ? "No workflow runs" : "No containers", detail: isCI ? "GitHub Actions runs will appear here once a workflow runs in this repository." : "Running and stopped containers in your active Docker context will appear here.")
        } else if filtered.isEmpty {
            PlaneServiceMessage(icon: kind.icon, title: "No matches", detail: "Try a different name or status.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { item in
                        OctetCollapsible(title: item.title, open: Binding(
                            get: { selected == item.id },
                            set: { selected = $0 ? item.id : nil }
                        ), trailing: {
                            Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(Theme.captionFont).foregroundStyle(item.tint)
                        }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.subtitle).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                                Text(item.detail).font(Theme.captionFont.monospaced()).foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if let url = item.url {
                                    OctetButton(title: "View run on GitHub", icon: "arrow.up.right", kind: .ghost, compact: true) { NSWorkspace.shared.open(url) }
                                }
                            }.padding(.bottom, 10)
                        }.padding(.horizontal, 12)
                        Divider()
                    }
                }
            }.octetScrollIndicators()
        }
    }

    @MainActor private func load() async {
        loading = true
        failure = nil
        items = []
        selected = nil
        guard !isCI || directory != nil else { loading = false; return }
        let ci = isCI, cwd = directory
        let result = await Task.detached(priority: .userInitiated) {
            LoginShell.run(ci
                ? ["gh", "run", "list", "--limit", "30", "--json", "databaseId,displayTitle,workflowName,headBranch,status,conclusion,url,event,createdAt"]
                : ["docker", "ps", "--all", "--format", "{{json .}}"], in: ci ? cwd : nil)
        }.value
        guard !Task.isCancelled else { return }
        loading = false
        guard result.status == 0 else {
            failure = (ci ? "Check that GitHub CLI is installed and signed in with gh auth login.\n\n" : "Check that Docker is installed and its daemon is running.\n\n") + result.output
            return
        }
        do { items = try OperationItem.parse(result.output, ci: ci) }
        catch { failure = "Couldn't read the response. Refresh to try again.\n\(error.localizedDescription)" }
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
                     detail: "Run #\($0.databaseId)\n\($0.event) · \($0.createdAt)", url: URL(string: $0.url))
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
    }
}
