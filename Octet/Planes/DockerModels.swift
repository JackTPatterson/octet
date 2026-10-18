import Foundation

struct DockerContext: Decodable, Identifiable {
    let Name: String
    let DockerEndpoint: String
    let Current: Bool
    var id: String { Name }
    var isLocal: Bool { DockerEndpoint.hasPrefix("unix://") }
}

struct DockerContainer: Decodable, Identifiable {
    let id, Names, Image, State, Status: String
    let Ports: String?
    let Labels: String?
    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case Names, Image, State, Status, Ports, Labels
    }
    var running: Bool { State == "running" }
    var paused: Bool { State == "paused" }
    var removable: Bool { ["exited", "created", "dead"].contains(State) }
    var project: String { label("com.docker.compose.project") }
    var service: String { label("com.docker.compose.service") }
    var workingDirectory: String { label("com.docker.compose.project.working_dir") }
    var searchText: String { [id, Names, Image, State, project, service, Ports ?? ""].joined(separator: " ") }
    func label(_ name: String) -> String {
        let prefix = name + "="
        return Labels?.split(separator: ",").first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? ""
    }
    func belongs(to directory: String) -> Bool {
        guard !workingDirectory.isEmpty, !directory.isEmpty else { return false }
        let root = URL(fileURLWithPath: directory).standardizedFileURL.path
        let work = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        return work == root || work.hasPrefix(root + "/") || root.hasPrefix(work + "/")
    }
}

enum DockerAction: String, CaseIterable {
    case start, stop, restart, pause, unpause, remove
    var title: String { self == .unpause ? "Resume" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .start, .unpause: "play.circle"
        case .stop: "square"
        case .pause: "pause.circle"
        case .restart: "arrow.clockwise"
        case .remove: "trash"
        }
    }
    func allowed(for container: DockerContainer) -> Bool {
        switch self {
        case .start: ["exited", "created"].contains(container.State)
        case .stop: container.running || container.State == "restarting"
        case .restart: container.running || container.State == "exited"
        case .pause: container.running
        case .unpause: container.paused
        case .remove: container.removable
        }
    }
    func command(id: String) -> [String] {
        switch self {
        case .remove: ["container", "rm", id] // Never force removal or remove volumes.
        case .stop, .restart: ["container", rawValue, "--time", "10", id]
        default: ["container", rawValue, id]
        }
    }
}

struct DockerInspection: Decodable {
    struct Configuration: Decodable { let Image: String?; let WorkingDir: String?; let User: String?; let Labels: [String: String]? }
    struct ContainerState: Decodable {
        struct HealthInfo: Decodable { let Status: String? }
        let Status: String?; let ExitCode: Int?; let Error: String?; let StartedAt: String?; let FinishedAt: String?; let Health: HealthInfo?
    }
    struct Mount: Decodable { let Source: String?; let Destination: String?; let RW: Bool? }
    struct Network: Decodable { let IPAddress: String?; let Gateway: String? }
    struct Port: Decodable {
        let HostIp: String
        let HostPort: String
        var address: String { (HostIp.contains(":") ? "[\(HostIp)]" : HostIp) + ":" + HostPort }
        func browserURL(containerPort: String, local: Bool) -> URL? {
            guard local, containerPort.hasSuffix("/tcp"), let port = Int(HostPort), (1...65535).contains(port),
                  ["", "0.0.0.0", "127.0.0.1", "::", "::1"].contains(HostIp) else { return nil }
            return URL(string: "\(containerPort == "443/tcp" ? "https" : "http")://127.0.0.1:\(port)")
        }
    }
    struct NetworkInfo: Decodable { let Ports: [String: [Port]?]?; let Networks: [String: Network]? }
    struct Host: Decodable {
        struct Restart: Decodable { let Name: String? }
        let RestartPolicy: Restart?
    }
    let Id: String
    let Created: String?
    let Config: Configuration?
    let State: ContainerState?
    let Mounts: [Mount]?
    let NetworkSettings: NetworkInfo?
    let HostConfig: Host?
    let RestartCount: Int?
}

struct DockerStats: Decodable {
    let CPUPerc, MemUsage, MemPerc, NetIO, BlockIO, PIDs: String
}

enum DockerJSON {
    static func lines<T: Decodable>(_ text: String, as type: T.Type) throws -> [T] {
        try text.split(separator: "\n").map { try JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
    static func shellCommand(context: String, id: String) -> String {
        DockerCommand.arguments(context: context, command: ["exec", "-it", id, "sh"])
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

@MainActor
final class DockerPanelModel: ObservableObject {
    @Published var contexts: [DockerContext] = []
    @Published var context = ""
    @Published var containers: [DockerContainer] = []
    @Published var selected: String?
    @Published var inspection: DockerInspection?
    @Published var stats: DockerStats?
    @Published var failure: String?
    @Published var detailFailure: String?
    @Published var statsFailure: String?
    @Published var actionFailure: String?
    @Published var loading = false
    @Published var detailLoading = false
    @Published var busy: Set<String> = []
    @Published var updated: Date?
    private var listRequest = UUID()
    private var detailRequest = UUID()

    var local: Bool { contexts.first(where: { $0.Name == context })?.isLocal == true }
    var projects: [String] { Array(Set(containers.map(\.project).filter { !$0.isEmpty })).sorted() }

    func discover() async {
        let result = await DockerCommand.run(["context", "ls", "--format", "{{json .}}"])
        guard !Task.isCancelled else { return }
        guard result.status == 0 else { failure = result.failure; return }
        do {
            contexts = try DockerJSON.lines(result.text, as: DockerContext.self)
            if context.isEmpty { changeContext(contexts.first(where: \.Current)?.Name ?? contexts.first?.Name ?? "") }
        } catch { failure = error.localizedDescription }
    }

    func changeContext(_ value: String) {
        listRequest = UUID(); detailRequest = UUID()
        context = value
        containers = []; selected = nil; inspection = nil; stats = nil
        failure = nil; detailFailure = nil; statsFailure = nil; actionFailure = nil
        updated = nil; loading = false; detailLoading = false
    }

    func refresh() async {
        let token = UUID(), target = context
        listRequest = token
        loading = true
        let result = await DockerCommand.run(context: target, ["ps", "--all", "--no-trunc", "--format", "{{json .}}"])
        guard listRequest == token, context == target else { return }
        loading = false
        guard !Task.isCancelled else { return }
        guard result.status == 0 else { failure = result.failure; return }
        do {
            let rows = try DockerJSON.lines(result.text, as: DockerContainer.self)
            containers = rows.sorted { $0.running != $1.running ? $0.running : $0.Names.localizedStandardCompare($1.Names) == .orderedAscending }
            failure = nil
            updated = Date()
            if let selected, !containers.contains(where: { $0.id == selected }) { select(nil) }
        } catch { failure = "Couldn't read Docker's response: \(error.localizedDescription)" }
    }

    func select(_ id: String?) {
        detailRequest = UUID()
        selected = id
        detailLoading = false
        inspection = nil; stats = nil; detailFailure = nil; statsFailure = nil; actionFailure = nil
    }

    func loadDetails() async {
        guard let id = selected else { return }
        let token = UUID(), target = context
        detailRequest = token
        detailLoading = true
        let result = await DockerCommand.run(context: target, ["inspect", "--type", "container", "--format", "{{json .}}", id])
        guard detailRequest == token, selected == id, context == target else { return }
        detailLoading = false
        guard !Task.isCancelled else { return }
        if result.status == 0 {
            do { inspection = try JSONDecoder().decode(DockerInspection.self, from: Data(result.text.utf8)); detailFailure = nil }
            catch { detailFailure = error.localizedDescription }
        } else { detailFailure = result.failure }
        guard containers.first(where: { $0.id == id })?.running == true else { stats = nil; statsFailure = nil; return }
        let metrics = await DockerCommand.run(context: target, ["stats", "--no-stream", "--format", "{{json .}}", id])
        guard !Task.isCancelled, detailRequest == token, selected == id, context == target else { return }
        if metrics.status == 0 {
            do { stats = try DockerJSON.lines(metrics.text, as: DockerStats.self).first; statsFailure = nil }
            catch { statsFailure = error.localizedDescription }
        } else { statsFailure = metrics.failure }
    }

    func perform(_ action: DockerAction, on container: DockerContainer) {
        guard action.allowed(for: container) else { return }
        let target = context, key = context + ":" + container.id
        guard busy.insert(key).inserted else { return }
        actionFailure = nil
        Task {
            let result = await DockerCommand.run(context: target, action.command(id: container.id), timeout: 40)
            busy.remove(key)
            guard context == target else { return }
            if result.status != 0 { actionFailure = "\(action.title) failed: \(result.failure)" }
            await refresh()
            await loadDetails()
        }
    }
}
