import Combine
import Foundation

/// Keeps Octet's own MCP servers in every installed agent's settings while
/// the feature behind them is on, and takes them out when it's turned off.
/// What was put where is remembered, so it runs again only when something
/// changed: the feature, the app's location, or which agents are installed.
@MainActor
final class AgentMCPInstaller {
    static let shared = AgentMCPInstaller()

    /// A server and whether the feature behind it is on.
    struct Feature {
        let server: String
        let subcommand: String
        let title: String
        let enabled: () -> Bool
    }

    static let features = [
        Feature(server: PeerMCP.serverName, subcommand: "peer-mcp", title: "the other-Macs tools") {
            SettingsStore.shared.values.peersEnabled
        },
        Feature(server: DelegationMCP.serverName, subcommand: "delegate-mcp", title: "the delegation tools") {
            SettingsStore.shared.values.delegationEnabled
        },
    ]

    private var subscriptions: Set<AnyCancellable> = []
    private var running: Set<String> = []

    /// Brings every feature's server in line now, and again whenever the
    /// installed agents change.
    func start() {
        guard subscriptions.isEmpty else { return }
        AgentDiscoveryStore.shared.$agents
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { AgentMCPInstaller.shared.syncAll() } }
            .store(in: &subscriptions)
    }

    func syncAll() {
        for feature in Self.features { sync(feature) }
    }

    /// Adds or removes one feature's server; `force` adds it again even if
    /// nothing seems to have changed, and says how it went.
    func sync(server: String, force: Bool = false) {
        guard let feature = Self.features.first(where: { $0.server == server }) else { return }
        sync(feature, force: force)
    }

    private func sync(_ feature: Feature, force: Bool = false) {
        guard !running.contains(feature.server) else { return }
        let key = "octet.mcp.installed.\(feature.server)"
        let recorded = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let agents = Set(AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id))
            .intersection(AgentMCP.supported)
        var steps: [(agent: String, steps: [AgentMCP.Step])] = []
        var wanted: [String: String] = [:]

        if feature.enabled() {
            guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else {
                if force { ToastCenter.shared.fail(nil, "octet-cli is missing from the app bundle") }
                return
            }
            let server = AgentMCP.Server(name: feature.server, command: cli, args: [feature.subcommand])
            for agent in agents.sorted() {
                wanted[agent] = cli
                if force || recorded[agent] != cli, let install = AgentMCP.install(server, agent: agent) {
                    steps.append((agent, install))
                }
            }
        }
        // Agents it was put into that shouldn't have it now.
        let server = AgentMCP.Server(name: feature.server, command: "", args: [])
        for agent in recorded.keys.sorted() where wanted[agent] == nil {
            if let remove = AgentMCP.remove(server, agent: agent) { steps.append((agent, remove)) }
        }
        guard !steps.isEmpty else {
            if force { ToastCenter.shared.info("No agent here takes MCP servers", detail: "Octet adds its tools to Claude Code, Codex, Gemini, Qwen, OpenCode, Cursor and Copilot.") }
            return
        }

        running.insert(feature.server)
        let adding = feature.enabled()
        DispatchQueue.global(qos: .utility).async {
            var failed: [String: String] = [:]
            for (agent, agentSteps) in steps {
                for step in agentSteps {
                    if let problem = Self.perform(step, server: feature.server) { failed[agent] = problem }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running.remove(feature.server)
                    // Remember what's in place; a failed add is tried again next time.
                    var now = wanted
                    for agent in failed.keys where adding { now[agent] = nil }
                    UserDefaults.standard.set(now, forKey: key)
                    let names = steps.map(\.agent).filter { failed[$0] == nil && wanted[$0] != nil }
                        .map { AgentBrand.displayNames[$0] ?? $0.capitalized }
                    if !failed.isEmpty {
                        ToastCenter.shared.fail(nil, "Couldn't update \(feature.title) everywhere",
                                                detail: failed.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    } else if adding, !names.isEmpty {
                        ToastCenter.shared.info("Added \(feature.title) to \(ListFormatter.localizedString(byJoining: names))",
                                                detail: "New agent sessions pick them up.")
                    }
                }
            }
        }
    }

    /// Does one step; the problem, if it didn't work.
    nonisolated private static func perform(_ step: AgentMCP.Step, server: String) -> String? {
        switch step {
        case .run(let command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-lc", command + " </dev/null"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return error.localizedDescription }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // Removing what isn't there, or adding what is, is fine.
            if process.terminationStatus == 0 || AgentMCP.isHarmless(text) { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "failed"
        case .json(let path, let key, let entry):
            let existing = FileManager.default.contents(atPath: path)
            // Nothing to take out of a file that isn't there.
            if existing == nil, entry == nil { return nil }
            guard let data = AgentMCP.edited(existing, server: server, key: key, entry: entry) else {
                return "\(path) isn't plain JSON; add \(server) there by hand"
            }
            if data == existing { return nil }
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
