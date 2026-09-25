import Foundation
import SQLite3

/// One step of an agent's plan, whichever agent made it: Claude Code's
/// tasks and TodoWrite, Codex's plan, OpenCode's and Qwen's todos all come
/// down to a line of text and where it stands.
struct AgentTodo: Equatable, Identifiable {
    enum Status: Equatable {
        case pending, inProgress, completed

        /// Every spelling the agents use: `in_progress`, `inProgress`,
        /// `active`, `done`, …; nil for one Octet doesn't know (`deleted`).
        init?(_ raw: String) {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "") {
            case "pending", "todo", "open", "notstarted": self = .pending
            case "inprogress", "active", "running", "started": self = .inProgress
            case "completed", "complete", "done", "finished": self = .completed
            default: return nil
            }
        }
    }

    let id: String
    var text: String
    /// What it says while under way ("Running the tests"), when the agent gives one.
    var activeText: String?
    var status: Status
    var detail: String?

    /// The line to show: the under-way wording while it's the one in progress.
    var shownText: String { status == .inProgress ? (activeText ?? text) : text }
}

extension Array where Element == AgentTodo {
    var completedCount: Int { filter { $0.status == .completed }.count }
    var current: AgentTodo? { first { $0.status == .inProgress } }
}

enum AgentTodos {
    // MARK: - Tool calls

    /// Tools that replace the whole list: Claude Code's older TodoWrite,
    /// OpenCode's todowrite (Octet names it TodoWrite), Qwen's todo_write.
    static let listTools: Set<String> = ["todowrite", "todo_write"]

    /// A `{todos: [...]}` input: `content`/`text`/`task` and `status`, with
    /// Claude's `activeForm`.
    static func fromTodoWrite(_ input: [String: Any]) -> [AgentTodo]? {
        guard let raw = input["todos"] as? [[String: Any]] else { return nil }
        return raw.enumerated().compactMap { index, item in
            guard let text = (item["content"] ?? item["text"] ?? item["task"] ?? item["title"]) as? String,
                  let status = (item["status"] as? String).flatMap(AgentTodo.Status.init) else { return nil }
            let id = (item["id"] as? String) ?? (item["id"] as? Int).map(String.init) ?? "\(index)"
            return AgentTodo(id: id, text: text, activeText: item["activeForm"] as? String, status: status)
        }
    }

    /// Codex's plan, `{plan: [{step, status}], explanation}`, from its
    /// `update_plan` call or `turn/plan/updated`.
    static func fromPlan(_ object: [String: Any]) -> [AgentTodo]? {
        guard let raw = object["plan"] as? [[String: Any]] else { return nil }
        return raw.enumerated().compactMap { index, item in
            guard let text = (item["step"] ?? item["content"] ?? item["text"]) as? String,
                  let status = (item["status"] as? String).flatMap(AgentTodo.Status.init) else { return nil }
            return AgentTodo(id: "\(index)", text: text, status: status)
        }
    }

    /// The list as a conversation's tool calls last left it: a list tool
    /// replaces it, a plan update replaces it, and Claude Code's TaskCreate
    /// and TaskUpdate add and change one task at a time.
    static func latest(in items: [AgentItem]) -> [AgentTodo]? {
        var list: [AgentTodo]?
        for item in items where item.parent == nil {
            guard case .tool(let call) = item.kind, let input = call.inputObject else { continue }
            let name = call.name.lowercased()
            if listTools.contains(name), let todos = fromTodoWrite(input) {
                list = todos
            } else if name == "update_plan", let plan = fromPlan(input) {
                list = plan
            } else if name == "taskcreate", let subject = input["subject"] as? String {
                // Claude Code numbers tasks from 1 and says so in the result.
                let id = call.result.flatMap(taskNumber(in:)) ?? "\((list?.count ?? 0) + 1)"
                var tasks = list ?? []
                tasks.append(AgentTodo(id: id, text: subject, activeText: input["activeForm"] as? String,
                                       status: .pending, detail: input["description"] as? String))
                list = tasks
            } else if name == "taskupdate", let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                      var tasks = list, let index = tasks.firstIndex(where: { $0.id == id }) {
                if input["status"] as? String == "deleted" {
                    tasks.remove(at: index)
                } else {
                    if let status = (input["status"] as? String).flatMap(AgentTodo.Status.init) { tasks[index].status = status }
                    if let subject = input["subject"] as? String { tasks[index].text = subject }
                    if let active = input["activeForm"] as? String { tasks[index].activeText = active }
                }
                list = tasks
            }
        }
        return list
    }

    /// "Task #4 created successfully" → "4".
    static func taskNumber(in result: String) -> String? {
        guard let range = result.range(of: #"#(\d+)"#, options: .regularExpression) else { return nil }
        return String(result[range].dropFirst())
    }

    // MARK: - Claude Code's task files

    /// Where Claude Code keeps a session's tasks, one JSON file each:
    /// `~/.claude/tasks/session-<first 8 of the session id>/`.
    static func claudeTasksDirectory(sessionId: String, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/.claude/tasks/session-" + String(sessionId.lowercased().prefix(8)), isDirectory: true)
    }

    /// The session's tasks, in the order they were made; nil when it has none.
    static func claudeTasks(in directory: URL) -> [AgentTodo]? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let tasks = files.filter { $0.pathExtension == "json" }.compactMap { url -> AgentTodo? in
            guard let data = try? Data(contentsOf: url),
                  let task = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let subject = task["subject"] as? String,
                  let status = (task["status"] as? String).flatMap(AgentTodo.Status.init) else { return nil }
            let id = (task["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
            return AgentTodo(id: id, text: subject, activeText: task["activeForm"] as? String,
                             status: status, detail: task["description"] as? String)
        }
        guard !tasks.isEmpty else { return nil }
        return tasks.sorted { (Int($0.id) ?? .max, $0.id) < (Int($1.id) ?? .max, $1.id) }
    }

    // MARK: - Codex's rollout

    /// The plan from one rollout line, when it's an `update_plan` call.
    static func codexPlan(fromRolloutLine line: String) -> [AgentTodo]? {
        guard line.contains("update_plan"), let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let payload = record["payload"] as? [String: Any] ?? record
        guard payload["name"] as? String == "update_plan" else { return nil }
        let arguments: [String: Any]?
        if let text = payload["arguments"] as? String, let data = text.data(using: .utf8) {
            arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            arguments = payload["arguments"] as? [String: Any]
        }
        return arguments.flatMap(fromPlan)
    }

    /// The last plan in a Codex rollout file.
    static func codexPlan(inRollout path: String) -> [AgentTodo]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var plan: [AgentTodo]?
        for line in text.split(separator: "\n") where line.contains("update_plan") {
            if let found = codexPlan(fromRolloutLine: String(line)) { plan = found }
        }
        return plan
    }

    // MARK: - OpenCode's database

    static var openCodeDatabase: String { NSHomeDirectory() + "/.local/share/opencode/opencode.db" }

    /// A session's todos from OpenCode's own database, read-only.
    static func openCodeTodos(sessionId: String, database: String = openCodeDatabase) -> [AgentTodo]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let query = "SELECT content, status, position FROM todo WHERE session_id = ? ORDER BY position"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionId, -1, transient)
        var todos: [AgentTodo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let content = sqlite3_column_text(statement, 0), let rawStatus = sqlite3_column_text(statement, 1),
                  let status = AgentTodo.Status(String(cString: rawStatus)) else { continue }
            todos.append(AgentTodo(id: "\(sqlite3_column_int(statement, 2))", text: String(cString: content), status: status))
        }
        return todos.isEmpty ? nil : todos
    }
}
