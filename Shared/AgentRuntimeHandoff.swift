import Foundation

/// Background work a terminal Claude Code session owns: commands it ran with
/// `run_in_background`, Monitor watches and subagents. None of it outlives
/// the process that started it, so moving the session into Octet means
/// finding what is still live from the session log and starting it again in
/// the conversation that takes over.
struct HandoffRuntime: Equatable, Identifiable {
    enum Kind: Equatable { case task, monitor, agent }

    /// The tool call that started it.
    let id: String
    let kind: Kind
    let title: String
    /// The shell command a task or monitor runs.
    let command: String?
    /// What a subagent was asked to do.
    let prompt: String?
    let startedAt: Date?
    /// When a monitor would have stopped on its own.
    let expiresAt: Date?
}

enum AgentRuntimeHandoff {
    /// What the session log says was still running. `processStart` is when
    /// the terminal's Claude Code process started: anything older belonged
    /// to an earlier process and ended with it.
    static func liveRuntimes(lines: [String], processStart: Date?, now: Date = Date()) -> [HandoffRuntime] {
        var ledger = RuntimeLedger()
        for line in lines { ledger.consume(line) }
        return ledger.live(processStart: processStart, now: now)
    }

    /// The first message the conversation in Octet sends, asking the agent to
    /// start again what the terminal process was running. Nil when nothing
    /// was running and no turn was cut short.
    static func continuationPrompt(_ runtimes: [HandoffRuntime], turnInterrupted: Bool) -> String? {
        guard !runtimes.isEmpty || turnInterrupted else { return nil }
        var lines = ["This session just moved from the terminal into Octet, which restarted Claude Code under the same session. The old process has exited."]
        if !runtimes.isEmpty {
            lines.append("")
            lines.append("These were still running in it and have stopped:")
            for runtime in runtimes {
                var line = "- \(label(runtime.kind)) \"\(runtime.title)\""
                if let command = runtime.command, !command.isEmpty {
                    line += ": `\(TwinTranscript.condense(command, limit: 300))`"
                }
                lines.append(line)
            }
            lines.append("")
            lines.append("Start again the ones that are still needed, the same way as before: background commands with run_in_background, watches with Monitor, subagents with Agent (reuse their original prompts). Skip any that are no longer needed.")
        }
        if turnInterrupted {
            lines.append("")
            lines.append("Your last turn was cut off by the move. Continue it from where it stopped.")
        } else {
            lines.append("Then carry on where you left off. If there is nothing left to do, say so briefly.")
        }
        return lines.joined(separator: "\n")
    }

    /// "2 background commands and a monitor", for the conversation's notice.
    static func summary(_ runtimes: [HandoffRuntime]) -> String {
        let parts: [(HandoffRuntime.Kind, String, String)] = [
            (.task, "background command", "background commands"),
            (.monitor, "monitor", "monitors"),
            (.agent, "subagent", "subagents"),
        ]
        let phrases = parts.compactMap { kind, one, many -> String? in
            let count = runtimes.filter { $0.kind == kind }.count
            return count == 0 ? nil : count == 1 ? "a \(one)" : "\(count) \(many)"
        }
        guard let last = phrases.last else { return "" }
        return phrases.count == 1 ? last : phrases.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Reading the log

    fileprivate static func runtime(id: String, call: (name: String, input: [String: Any], at: Date?),
                                result: [String: Any]) -> HandoffRuntime? {
        let input = call.input
        let description = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let command = input["command"] as? String
        switch call.name {
        case "Bash", "Shell", "PowerShell":
            guard result["backgroundTaskId"] != nil || input["run_in_background"] as? Bool == true,
                  result["interrupted"] as? Bool != true else { return nil }
            return HandoffRuntime(id: id, kind: .task, title: description ?? command.map(firstLine) ?? "Background command",
                                  command: command, prompt: nil, startedAt: call.at, expiresAt: nil)
        case "Monitor":
            let timeout = (result["timeoutMs"] as? NSNumber ?? input["timeout_ms"] as? NSNumber)?.doubleValue
            let persistent = result["persistent"] as? Bool == true || input["persistent"] as? Bool == true
            let expires = persistent ? nil : call.at.map { $0.addingTimeInterval((timeout ?? 120_000) / 1_000) }
            return HandoffRuntime(id: id, kind: .monitor, title: description ?? "Monitor",
                                  command: command, prompt: nil, startedAt: call.at, expiresAt: expires)
        case _ where isAgent(call.name):
            // A subagent that returned its answer is done; one launched to
            // run on its own reports how it was launched instead.
            let status = result["status"] as? String
            guard status == "async_launched" || status == "teammate_spawned" else { return nil }
            return HandoffRuntime(id: id, kind: .agent, title: agentTitle(input),
                                  command: nil, prompt: input["prompt"] as? String, startedAt: call.at, expiresAt: nil)
        default:
            return nil
        }
    }

    fileprivate static func isAgent(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    fileprivate static func agentTitle(_ input: [String: Any]) -> String {
        [input["description"], input["name"], input["subagent_type"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty } ?? "Subagent"
    }

    private static func label(_ kind: HandoffRuntime.Kind) -> String {
        switch kind {
        case .task: "Background command"
        case .monitor: "Monitor"
        case .agent: "Subagent"
        }
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? Substring(text))
    }

    /// Where Claude Code delivers task notifications: queued into the input
    /// while a turn runs, or as the user message that starts the next one.
    /// Tool results are skipped, since they may quote old notifications.
    fileprivate static func notificationTexts(_ record: [String: Any]) -> [String] {
        if let attachment = record["attachment"] as? [String: Any],
           let prompt = attachment["prompt"] as? String {
            return [prompt]
        }
        guard record["type"] as? String == "user", let message = record["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String { return [text] }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    /// Notifications that say a task ended. A monitor's per-event notices
    /// carry no status and leave it running.
    static func notifications(in text: String) -> [(toolUseId: String?, taskId: String?)] {
        guard text.contains("<task-notification>") else { return [] }
        return text.components(separatedBy: "<task-notification>").dropFirst().compactMap { chunk in
            let body = chunk.components(separatedBy: "</task-notification>").first ?? chunk
            guard let status = TwinNotes.tag("status", in: body), status != "running" else { return nil }
            return (TwinNotes.tag("tool-use-id", in: body), TwinNotes.tag("task-id", in: body))
        }
    }

    fileprivate static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// When a process started, from the kernel's process table.
    static func processStart(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

/// The runtimes a Claude Code session log has started and not yet seen end,
/// built up one line at a time so a growing log is only read once.
struct RuntimeLedger {
    private var calls: [String: (name: String, input: [String: Any], at: Date?)] = [:]
    private var order: [String] = []
    private var started: [String: HandoffRuntime] = [:]
    private var taskIds: [String: String] = [:]
    private var finishedTools: Set<String> = []
    private var finishedTasks: Set<String> = []

    mutating func consume(_ line: String) {
        guard line.contains("tool_use") || line.contains("task-notification"),
              let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              record["isSidechain"] as? Bool != true else { return }
        let at = (record["timestamp"] as? String).flatMap(AgentRuntimeHandoff.date)
        for text in AgentRuntimeHandoff.notificationTexts(record) {
            for notice in AgentRuntimeHandoff.notifications(in: text) {
                if let tool = notice.toolUseId { finishedTools.insert(tool) }
                if let task = notice.taskId { finishedTasks.insert(task) }
            }
        }
        guard let message = record["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                // Only calls that can start or stop a runtime are kept.
                guard ["Bash", "Shell", "PowerShell", "Monitor", "Agent", "Task",
                       "TaskStop", "KillShell", "KillBash"].contains(name) else { continue }
                calls[id] = (name, input, at)
                order.append(id)
                if ["TaskStop", "KillShell", "KillBash"].contains(name),
                   let task = input["task_id"] as? String ?? input["shell_id"] as? String {
                    finishedTasks.insert(task)
                }
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, let call = calls[id] else { continue }
                let result = record["toolUseResult"] as? [String: Any] ?? [:]
                if block["is_error"] as? Bool != true,
                   let runtime = AgentRuntimeHandoff.runtime(id: id, call: call, result: result) {
                    started[id] = runtime
                    if let task = result["backgroundTaskId"] as? String ?? result["taskId"] as? String
                        ?? result["agentId"] as? String {
                        taskIds[id] = task
                    }
                } else {
                    finishedTools.insert(id)
                    calls[id] = nil
                }
            default:
                continue
            }
        }
    }

    /// What is still running. `processStart` is when the session's current
    /// process started: anything older belonged to an earlier process and
    /// ended with it.
    func live(processStart: Date?, now: Date = Date()) -> [HandoffRuntime] {
        order.compactMap { id -> HandoffRuntime? in
            if let runtime = started[id] {
                if finishedTools.contains(id) || taskIds[id].map(finishedTasks.contains) == true { return nil }
                return runtime
            }
            // A subagent still working in the foreground when the log ends.
            guard !finishedTools.contains(id), let call = calls[id], AgentRuntimeHandoff.isAgent(call.name) else { return nil }
            return HandoffRuntime(id: id, kind: .agent, title: AgentRuntimeHandoff.agentTitle(call.input),
                                  command: nil, prompt: call.input["prompt"] as? String,
                                  startedAt: call.at, expiresAt: nil)
        }.filter { runtime in
            if let expires = runtime.expiresAt, expires <= now { return false }
            guard let processStart, let started = runtime.startedAt else { return true }
            // Log and process clocks are the same machine's; allow for the
            // log line landing a moment before the process table updates.
            return started >= processStart.addingTimeInterval(-2)
        }
    }
}
