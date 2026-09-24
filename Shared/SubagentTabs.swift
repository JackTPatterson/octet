import Foundation

/// Opens a session server tab for each Claude Code subagent (Agent/Task tool call),
/// named after the subagent and running `octet-cli agent-watch`.
enum SubagentHook {
    static let maxLabelLength = 48

    /// Builds the `layout.apply` params for a subagent tab, or nil when the
    /// payload is not a subagent launch inside a session server pane.
    static func tabRequest(
        payload: [String: Any],
        environment: [String: String],
        cliPath: String,
        now: Date = Date()
    ) -> [String: Any]? {
        guard let toolName = payload["tool_name"] as? String,
              toolName == "Agent" || toolName == "Task",
              let workspaceId = environment[EngineProtocol.workspaceIdVariable], !workspaceId.isEmpty,
              let transcriptPath = payload["transcript_path"] as? String,
              transcriptPath.hasSuffix(".jsonl") else { return nil }

        let input = payload["tool_input"] as? [String: Any]
        let description = (input?["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agentType = (input?["subagent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = tabLabel(agentType: agentType, description: description)

        var command = [
            cliPath, "agent-watch",
            "--dir", String(transcriptPath.dropLast(".jsonl".count)) + "/subagents",
            "--since", String(Int(now.timeIntervalSince1970) - 2),
            "--title", label,
        ]
        if let toolUseId = payload["tool_use_id"] as? String, !toolUseId.isEmpty {
            command += ["--tool-use-id", toolUseId]
        }
        if !description.isEmpty {
            command += ["--description", description]
        }

        var pane: [String: Any] = ["type": "pane", "label": label, "command": command]
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { pane["cwd"] = cwd }
        return [
            "workspace_id": workspaceId,
            "tab_label": label,
            "focus": false,
            "root": pane,
        ]
    }

    static func tabLabel(agentType: String, description: String) -> String {
        let parts = [agentType, description].filter { !$0.isEmpty }
        let label = parts.isEmpty ? "Subagent" : parts.joined(separator: ": ")
        return label.count > maxLabelLength ? String(label.prefix(maxLabelLength - 1)) + "…" : label
    }

    static func handlePreToolUse(payload data: Data, environment: [String: String], cliPath: String) {
        guard environment["OCTET_SUBAGENT_TABS"] != "0",
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let socketPath = environment[EngineProtocol.socketPathVariable], !socketPath.isEmpty,
              let request = tabRequest(payload: payload, environment: environment, cliPath: cliPath) else { return }
        _ = try? EngineClient(socketPath: socketPath).call("layout.apply", request)
    }
}

/// The viewer process inside a subagent tab.
enum SubagentWatch {
    static func run(
        directory: String,
        toolUseId: String?,
        description: String?,
        since: TimeInterval,
        title: String,
        environment: [String: String]
    ) -> Never {
        let reporter = PaneAgentReporter(environment: environment)
        let renderer = SubagentTranscriptRenderer()
        renderer.printHeader(title: title)
        reporter.report(state: "working", message: title)
        renderer.onFinished = {
            reporter.report(state: "idle", message: "finished")
            playFinishedSound()
        }
        var lastCheck = Date.distantPast
        renderer.onTick = {
            // The setting is read again each time, so changing it in Octet
            // applies to tabs already open.
            guard let finished = renderer.finishedAt, Date().timeIntervalSince(lastCheck) >= 5 else { return }
            lastCheck = Date()
            let delay = closeDelay()
            guard delay > 0, Date().timeIntervalSince(finished) >= delay else { return }
            if reporter.closeTab() { exit(0) }
        }

        let locator = SubagentTranscriptLocator(
            directory: directory,
            toolUseId: toolUseId,
            description: description,
            since: since
        )
        for _ in 0..<(10 * 60 * 4) {
            if let transcript = locator.find() {
                renderer.follow(transcript)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print(renderer.dim("No subagent transcript appeared in \(directory)."))
        reporter.report(state: "idle", message: "no transcript")
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
}

extension SubagentWatch {
    /// Seconds a finished subagent's tab stays open, 0 for until closed by
    /// hand. The app writes it into its own preferences; the viewer runs
    /// from inside the app bundle, so it reads the app's domain.
    static let closeDelayKey = "subagentTabCloseAfterSeconds"
    /// The system sound a finished subagent plays; empty or missing for none.
    static let finishedSoundKey = "subagentFinishedSound"
    /// macOS's own sounds, offered in Settings.
    static let sounds = ["Glass", "Pop", "Tink", "Purr", "Hero", "Submarine", "Funk", "Bottle", "Morse", "Ping"]

    static func finishedSound(bundleIdentifier: String? = appBundleIdentifier()) -> String? {
        let domain = (bundleIdentifier ?? "com.jpxsoftware.octet") as CFString
        CFPreferencesAppSynchronize(domain)
        let name = CFPreferencesCopyAppValue(finishedSoundKey as CFString, domain) as? String
        return name.flatMap { sounds.contains($0) ? $0 : nil }
    }

    /// Plays without waiting; the viewer keeps tailing meanwhile.
    static func playFinishedSound() {
        guard let name = finishedSound() else { return }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/\(name).aiff"]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        try? player.run()
    }

    static func closeDelay(bundleIdentifier: String? = appBundleIdentifier()) -> TimeInterval {
        let domain = (bundleIdentifier ?? "com.jpxsoftware.octet") as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue(closeDelayKey as CFString, domain) as? NSNumber
        return max(0, value?.doubleValue ?? 0)
    }

    /// The identifier of the app bundle this executable sits in.
    static func appBundleIdentifier(executable: String = CommandLine.arguments.first ?? "") -> String? {
        var url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// Reports a viewer pane's state to the session server so tabs and the sidebar show the
/// subagent as a working/idle Claude agent.
struct PaneAgentReporter {
    let client: EngineClient?
    let paneId: String?

    init(environment: [String: String]) {
        paneId = environment[EngineProtocol.paneIdVariable]
        client = environment[EngineProtocol.socketPathVariable].map(EngineClient.init(socketPath:))
    }

    /// Closes the tab this viewer runs in, unless someone is looking at it.
    /// Returns whether it closed.
    func closeTab() -> Bool {
        guard let client, let paneId, let snapshot = try? client.snapshot(),
              let pane = snapshot.panes.first(where: { $0.paneId == paneId }), !pane.focused else { return false }
        let alone = snapshot.panes.filter { $0.tabId == pane.tabId }.count <= 1
        let closed = alone
            ? (try? client.call("tab.close", ["tab_id": pane.tabId])) != nil
            : (try? client.call("pane.close", ["pane_id": paneId])) != nil
        return closed
    }

    func report(state: String, message: String) {
        guard let client, let paneId else { return }
        _ = try? client.call("pane.report_agent", [
            "pane_id": paneId,
            "source": "octet:subagent",
            "agent": "claude",
            "state": state,
            "message": message,
        ])
    }
}

/// Where an agent keeps its hook config. Every agent Octet supports uses the
/// same shape — a `hooks` map of event name to matcher entries — so one
/// installer serves them all; adding an agent is a row in `specs`.
struct SubagentHookSpec: Identifiable, Equatable {
    let hostId: String
    /// The file holding the hooks map.
    let file: String
    /// The file's own name for a backup Octet writes before editing.
    let backupName: String
    let event: String
    /// Tool names that spawn a subagent.
    let matcher: String

    var id: String { hostId }
    var displayName: String { AgentBrand.displayNames[hostId] ?? hostId }
    var url: URL { URL(fileURLWithPath: file) }
}

/// Adds and removes Octet's subagent hook in each agent's own config.
enum SubagentHookInstaller {
    static func specs(home: String = NSHomeDirectory()) -> [SubagentHookSpec] {
        [
            SubagentHookSpec(hostId: "claude", file: "\(home)/.claude/settings.json",
                             backupName: "settings.json.octet-backup", event: "PreToolUse", matcher: "Agent|Task"),
            SubagentHookSpec(hostId: "codex", file: "\(home)/.codex/hooks.json",
                             backupName: "hooks.json.octet-backup", event: "PreToolUse", matcher: "Agent|Task"),
        ]
    }

    /// Specs for the agents actually installed on this machine.
    static func available(home: String = NSHomeDirectory()) -> [SubagentHookSpec] {
        let installed = Set(AgentHosts.installed(home: home).map(\.id))
        return specs(home: home).filter { installed.contains($0.hostId) }
    }

    static func spec(_ hostId: String, home: String = NSHomeDirectory()) -> SubagentHookSpec? {
        specs(home: home).first { $0.hostId == hostId }
    }

    /// Whether a hook command is one Octet installed. `herd-cli` is the
    /// pre-rename spelling and must remain recognizable so upgrades can
    /// replace its now-stale app-bundle path.
    static func isOctetHookCommand(_ command: String) -> Bool {
        (command.contains("octet-cli") || command.contains("herd-cli"))
            && command.range(of: " hook [a-z_-]+$", options: .regularExpression) != nil
    }

    static func isInstalled(_ spec: SubagentHookSpec) -> Bool {
        guard let data = try? Data(contentsOf: spec.url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[spec.event] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String).map(isOctetHookCommand) ?? false }
        }
    }

    static func hookCommand(cliPath: String, hostId: String) -> String {
        "'\(cliPath.replacingOccurrences(of: "'", with: "'\"'\"'"))' hook \(hostId)"
    }

    /// Returns settings with Octet's hook present (replacing an older path).
    static func installing(into settings: [String: Any], cliPath: String, spec: SubagentHookSpec) -> [String: Any] {
        var settings = removing(from: settings, spec: spec)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[spec.event] as? [[String: Any]] ?? []
        entries.append([
            "matcher": spec.matcher,
            "hooks": [["type": "command", "command": hookCommand(cliPath: cliPath, hostId: spec.hostId), "timeout": 5]],
        ])
        hooks[spec.event] = entries
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any], spec: SubagentHookSpec) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[spec.event] as? [[String: Any]] else { return settings }
        let kept = entries.compactMap { entry -> [String: Any]? in
            var entry = entry
            let inner = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                !(($0["command"] as? String).map(isOctetHookCommand) ?? false)
            }
            guard !inner.isEmpty else { return nil }
            entry["hooks"] = inner
            return entry
        }
        if kept.isEmpty { hooks.removeValue(forKey: spec.event) } else { hooks[spec.event] = kept }
        settings["hooks"] = hooks
        return settings
    }

    @discardableResult
    static func install(cliPath: String, spec: SubagentHookSpec) throws -> Bool {
        let current = try load(spec)
        let updated = installing(into: current, cliPath: cliPath, spec: spec)
        guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return false }
        try save(updated, spec: spec)
        return true
    }

    @discardableResult
    static func uninstall(spec: SubagentHookSpec) throws -> Bool {
        let current = try load(spec)
        let updated = removing(from: current, spec: spec)
        guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return false }
        try save(updated, spec: spec)
        return true
    }

    private static func load(_ spec: SubagentHookSpec) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: spec.url) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func save(_ settings: [String: Any], spec: SubagentHookSpec) throws {
        let url = spec.url
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(spec.backupName)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
