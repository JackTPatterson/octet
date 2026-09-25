import Foundation

/// A terminal that was running something, as Octet last saw it. Journaled
/// while it runs so that if the session server dies (a crash, a restart,
/// the Mac shutting down) and takes the process with it, Octet can reopen
/// the terminal where it was, with its output and the command ready to run.
/// Agents aren't journaled here: `AgentRecovery` resumes their conversation.
struct ShellSessionRecord: Codable, Equatable, Identifiable {
    let terminalId: String
    var workspaceLabel: String
    var tabLabel: String
    var cwd: String
    /// The job's command line.
    var command: String
    var firstSeen: Date
    var lastSeen: Date

    var id: String { terminalId }
}

/// The running job in a pane, from `pane.process_info`.
struct ShellJob: Equatable {
    let command: String
    let name: String
}

enum ShellRecovery {
    /// What's running in the pane, if anything but its own shell: the
    /// foreground group's leader, which is the command that was typed.
    static func job(in result: [String: Any]) -> ShellJob? {
        guard let info = result["process_info"] as? [String: Any] else { return nil }
        let shell = info["shell_pid"] as? Int
        let group = info["foreground_process_group_id"] as? Int
        let processes = (info["foreground_processes"] as? [[String: Any]] ?? []).filter { raw in
            guard let pid = raw["pid"] as? Int, pid != shell else { return false }
            let name = ((raw["argv0"] as? String) ?? (raw["name"] as? String) ?? "") as NSString
            let command = name.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return !ShellPrompt.shells.contains(command)
        }
        guard let leader = processes.first(where: { $0["pid"] as? Int == group }) ?? processes.first else { return nil }
        let name = ShellPrompt.processName(leader["name"] as? String ?? "", argv0: leader["argv0"] as? String)
        let command = (leader["cmdline"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        return ShellJob(command: command, name: name)
    }

    /// The journal after one look at every terminal: busy ones recorded (a
    /// record keeps its first sighting), the rest dropped, since a job that
    /// finished or a terminal closed on purpose has nothing to recover.
    static func record(_ busy: [(pane: EnginePane, job: ShellJob)], in snapshot: EngineSnapshot,
                       into records: [ShellSessionRecord], now: Date = Date()) -> [ShellSessionRecord] {
        busy.compactMap { pane, job in
            guard let terminal = pane.terminalId else { return nil }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let workspace = snapshot.workspaces.first { $0.workspaceId == pane.workspaceId }
            let earlier = records.first { $0.terminalId == terminal }
            return ShellSessionRecord(
                terminalId: terminal,
                workspaceLabel: workspace?.label ?? "",
                tabLabel: tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "",
                cwd: pane.effectiveCwd ?? NSHomeDirectory(),
                command: job.command,
                firstSeen: earlier?.firstSeen ?? now,
                lastSeen: now
            )
        }
    }

    /// Terminals that were running at the last look before the drop and
    /// aren't there now.
    static func lost(_ records: [ShellSessionRecord], lastObserved: Date, liveTerminals: Set<String>,
                     slack: TimeInterval = 30) -> [ShellSessionRecord] {
        records.filter { $0.lastSeen >= lastObserved.addingTimeInterval(-slack) && !liveTerminals.contains($0.terminalId) }
    }

    /// A pane that prints what the terminal last showed, says what it was
    /// running, and leaves a login shell in the folder it ran in.
    static func reopenRequest(_ record: ShellSessionRecord, dump: URL?, shell: String,
                              workspaceId: String?, tabId: String?) -> [String: Any] {
        let label = record.tabLabel.isEmpty ? "Recovered" : record.tabLabel
        let stamp = DateFormatter.localizedString(from: record.lastSeen, dateStyle: .none, timeStyle: .short)
        var script = ""
        if let dump { script += "cat \(quote(dump.path)) 2>/dev/null; " }
        // Dim, on its own line, so it reads as Octet's note and not output.
        script += "printf '\\n\\033[2m── Recovered by Octet · was running at %s:\\033[0m\\n\\033[2m   %s\\033[0m\\n\\n' "
        script += "\(quote(stamp)) \(quote(record.command)); exec \(quote(shell)) -l"
        var params: [String: Any] = [
            "focus": false,
            "root": [
                "type": "pane",
                "label": label,
                "cwd": record.cwd,
                "command": [shell, "-lc", script],
            ] as [String: Any],
        ]
        if let tabId { params["tab_id"] = tabId } else { params["tab_label"] = label }
        if let workspaceId { params["workspace_id"] = workspaceId }
        return params
    }

    /// A command line short enough for a toast or a row: the program's
    /// name instead of its full path, cut at `limit`.
    static func short(_ command: String, limit: Int = 48) -> String {
        var words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = words.first { words[0] = (first as NSString).lastPathComponent }
        let text = words.joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// Where a terminal's last output is kept.
    static func dumpURL(for terminalId: String, in directory: URL) -> URL {
        let safe = terminalId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return directory.appendingPathComponent("\(safe).ansi")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// On-disk journal: `~/Library/Application Support/Octet/shell-sessions.json`.
struct ShellSessionJournal: Codable, Equatable {
    var lastObserved: Date = .distantPast
    var records: [ShellSessionRecord] = []

    static func load(from url: URL) -> ShellSessionJournal {
        guard let data = try? Data(contentsOf: url) else { return ShellSessionJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ShellSessionJournal.self, from: data)) ?? ShellSessionJournal()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
