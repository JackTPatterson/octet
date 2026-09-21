import Foundation

/// Codex sessions for the Codex agents board. `codex agents` is a TUI with
/// no machine output, so Octet reads what it reads: the `threads` table of
/// Codex's state database (queried read-only), and each thread's rollout
/// log for its state and transcript.
enum CodexThreads {
    struct Thread: Equatable {
        let id: String
        let rolloutPath: String
        let cwd: String
        let name: String
        let preview: String
        let updatedAt: Date?
        let createdAt: Date?
        let model: String?
    }

    /// The newest `state_N.sqlite` under `~/.codex`.
    static func databasePath(home: String = NSHomeDirectory()) -> String? {
        let folder = home + "/.codex"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let versioned = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, folder + "/" + name)
        }
        return versioned.max { $0.0 < $1.0 }?.1
    }

    static let query = """
    select id, rollout_path, cwd, title, name, preview, first_user_message, updated_at_ms, created_at_ms, model \
    from threads where archived = 0 order by updated_at desc limit 80
    """

    /// Where one thread's rollout log lives, for reopening its transcript.
    /// Read straight from the state database, since the store that usually
    /// holds these paths may not have refreshed yet at launch.
    static func rolloutPath(threadId: String, home: String = NSHomeDirectory()) -> String? {
        guard !threadId.isEmpty, threadId.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              let database = databasePath(home: home) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database,
                             "select id, rollout_path from threads where id = '\(threadId)' limit 1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data).first?.rolloutPath
    }

    /// Rows from `sqlite3 -json`.
    static func parse(_ data: Data) -> [Thread] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let path = row["rollout_path"] as? String else { return nil }
            func text(_ key: String) -> String? {
                (row[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            func date(_ key: String) -> Date? { (row[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            let name = text("name") ?? text("title") ?? text("first_user_message").map { String($0.prefix(60)) } ?? "Untitled session"
            return Thread(id: id, rolloutPath: path, cwd: text("cwd") ?? NSHomeDirectory(),
                          name: name.components(separatedBy: "\n").first ?? name,
                          preview: text("preview") ?? "", updatedAt: date("updated_at_ms"), createdAt: date("created_at_ms"),
                          model: text("model"))
        }
    }

    /// A thread's state from the end of its rollout log: an approval request
    /// with nothing after it needs you; a turn started and not completed is
    /// working if the log moved recently; otherwise it's done.
    static func state(tail lines: [String], modified: Date?, now: Date = Date()) -> BackgroundAgent.State {
        var lastEvent: String?
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if ["token_count", "item_completed", "world_state"].contains(type) { continue }
            lastEvent = type
            break
        }
        guard let lastEvent else { return .idle }
        if lastEvent.contains("approval_request") || lastEvent == "request_user_input" { return .needsInput }
        if lastEvent == "task_complete" || lastEvent == "turn_aborted" { return .done }
        let recent = modified.map { now.timeIntervalSince($0) < 120 } ?? false
        return recent ? .working : .done
    }

    /// The last lines of a file, cheaply.
    static func tail(path: String, bytes: UInt64 = 200_000) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).components(separatedBy: "\n")
    }
}

extension AgentConversation {
    /// A Codex transcript (parsed by TwinTranscript) as transcript items.
    init(twin: TwinConversation) {
        self.init()
        model = twin.model
        cwd = twin.cwd
        for message in twin.messages {
            for (index, block) in message.blocks.enumerated() {
                let id = "\(message.id):\(index)"
                switch block {
                case .text(let text):
                    items.append(AgentItem(id: id, kind: message.role == .user ? .user(text) : .text(text)))
                case .thinking(let text):
                    items.append(AgentItem(id: id, kind: .thinking(text)))
                case .toolCall(let callId, let name, let summary):
                    items.append(AgentItem(id: callId, kind: .tool(AgentToolCall(name: name, summary: summary, input: ""))))
                case .toolResult(let callId, let summary, let isError):
                    if let position = items.firstIndex(where: { $0.id == callId }), case .tool(var call) = items[position].kind {
                        call.result = summary
                        call.isError = isError
                        items[position].kind = .tool(call)
                    }
                }
            }
        }
    }
}
