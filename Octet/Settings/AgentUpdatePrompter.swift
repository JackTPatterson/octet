import Foundation

@MainActor
final class AgentUpdatePrompter {
    static let shared = AgentUpdatePrompter()

    private static let checkedKey = "octet.agentUpdates.checkedAt.v1"
    private static let promptedKey = "octet.agentUpdates.prompted.v1"
    private var checking = false

    func check(_ agents: [DiscoveredAgent], force: Bool = false) {
        guard SettingsStore.shared.values.checkForAgentUpdates, !checking else { return }
        if !force, let checked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date,
           Date().timeIntervalSince(checked) < 24 * 3600 { return }
        checking = true
        AgentUpdateChecker.check(agents) { updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(updates) }
            }
        }
    }

    private func finished(_ updates: [AgentUpdate]) {
        checking = false
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        guard !updates.isEmpty else { return }
        let signature = updates.map { "\($0.id):\($0.latest)" }.joined(separator: "|")
        guard signature != UserDefaults.standard.string(forKey: Self.promptedKey) else { return }
        UserDefaults.standard.set(signature, forKey: Self.promptedKey)
        let commands = updates.map(\.command).joined(separator: "\n")
        ConfirmCenter.shared.ask(
            title: updates.count == 1 ? "An agent update is available" : "Agent updates are available",
            message: "Octet found newer versions of installed agent tools. Update them now?",
            items: updates.map { "\($0.displayName)  \($0.current) → \($0.latest)" },
            detail: commands,
            confirmTitle: updates.count == 1 ? "Update" : "Update All",
            cancelTitle: "Later"
        ) { _ in
            AgentUpdateRunner.run(updates)
        }
    }
}

@MainActor
private enum AgentUpdateRunner {
    static func run(_ updates: [AgentUpdate]) {
        let noun = updates.count == 1 ? updates[0].displayName : "agent tools"
        let toast = ToastCenter.shared.progress("Updating \(noun)…")
        DispatchQueue.global(qos: .utility).async {
            let failures = updates.compactMap { update -> String? in
                let result = execute(update.command)
                guard result.status != 0 else { return nil }
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "\(update.displayName) exited \(result.status)" : "\(update.displayName): \(detail)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failures.isEmpty {
                        ToastCenter.shared.succeed(toast, "Updated \(noun)")
                        AgentDiscoveryStore.shared.scan()
                    } else {
                        ToastCenter.shared.fail(toast, "Some updates didn't finish",
                                                detail: failures.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    nonisolated private static func execute(_ command: String) -> (status: Int32, output: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data.suffix(2_000), as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
