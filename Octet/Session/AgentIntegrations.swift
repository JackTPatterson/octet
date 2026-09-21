import Foundation

/// The session server's official agent integrations (its `integration`
/// command). An installed integration reports accurate agent state and the
/// agent's native session id, which is what lets the session server resume
/// the conversation after a restart.
@MainActor
final class AgentIntegrations: ObservableObject {
    static let shared = AgentIntegrations()

    struct Status: Identifiable, Equatable {
        let agent: String
        let installed: Bool
        let detail: String
        var id: String { agent }
    }

    /// Agents Octet highlights for recovery; others are listed below them.
    static let primary = ["claude", "codex"]

    @Published private(set) var statuses: [Status] = []
    @Published private(set) var loading = false

    func refresh() {
        guard let engine = EngineSession.locateEngine() else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.run(engine, ["integration", "status"])
            let parsed = Self.parse(output)
            DispatchQueue.main.async {
                self.statuses = parsed
                self.loading = false
            }
        }
    }

    func status(_ agent: String) -> Status? {
        statuses.first { $0.agent == agent }
    }

    func install(_ agent: String) {
        guard let engine = EngineSession.locateEngine() else { return }
        let name = AgentBrand.forAgent(agent)?.displayName ?? agent
        let toast = ToastCenter.shared.progress("Installing the \(name) integration…")
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.run(engine, ["integration", "install", agent])
            let installed = Self.parse(Self.run(engine, ["integration", "status"])).first { $0.agent == agent }?.installed == true
            DispatchQueue.main.async {
                if installed {
                    ToastCenter.shared.succeed(toast, "Installed the \(name) integration",
                                               detail: "Restart running \(name) sessions so they report their session id")
                } else {
                    ToastCenter.shared.fail(toast, "Couldn't install the \(name) integration",
                                            detail: PluginCLI.lastLines(output))
                }
                self.refresh()
            }
        }
    }

    /// Parses lines like `claude: not installed (/path)` or
    /// `codex: installed v5 (/path)`.
    nonisolated static func parse(_ output: String) -> [Status] {
        output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":"), !text.hasPrefix("Are you") else { return nil }
            let agent = text[..<colon].replacingOccurrences(of: " (experimental)", with: "")
            guard !agent.contains(" "), !agent.isEmpty else { return nil }
            let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let state = rest.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? rest
            let installed = !state.hasPrefix("not installed")
            return Status(agent: String(agent), installed: installed, detail: state)
        }
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return String(describing: error) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
