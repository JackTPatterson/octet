import Foundation
import SQLite3

/// Reads model-call usage out of each agent's own session logs. Pure: hand
/// it a log's bytes (or OpenCode's database path) and it returns records,
/// priced at API rates where the agent doesn't say what a call cost.
enum UsageLogParsers {
    // MARK: Claude Code

    /// `~/.claude/projects/<project>/<session>.jsonl`: one line per event;
    /// assistant lines carry `message.usage` and `message.model`. A message
    /// streamed in several content blocks is logged once per block with the
    /// same id, so records keep the id for `UsageRecords.dedupe`.
    static func claude(_ data: Data) -> [UsageRecord] {
        var records: [UsageRecord] = []
        forEachLine(data, containing: [usageNeedle, assistantNeedle]) { object in
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let tokens = TokenUsage.claude(usage),
                  let date = (object["timestamp"] as? String).flatMap(parseDate) else { return }
            let model = message["model"] as? String ?? "claude"
            // Claude Code's placeholder for messages it wrote itself.
            guard model != "<synthetic>" else { return }
            let longWrites = (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
            let key = (message["id"] as? String).map { $0 + ":" + (object["requestId"] as? String ?? "") }
            records.append(UsageRecord(date: date, provider: "claude",
                                       sessionId: object["sessionId"] as? String ?? "",
                                       model: model, cwd: object["cwd"] as? String, tokens: tokens,
                                       cost: UsagePricing.cost(model: model, tokens: tokens, longWrites: longWrites),
                                       cacheSavings: UsagePricing.cacheSavings(model: model, tokens: tokens), key: key))
        }
        return records
    }

    // MARK: Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: `token_count` events
    /// carry the conversation's running total, sometimes twice for one call,
    /// so each record is the growth since the last total. The model comes
    /// from the latest `turn_context`. Codex counts cached input inside
    /// `input_tokens`, and reasoning inside `output_tokens`.
    static func codex(_ data: Data, fallbackSession: String = "") -> [UsageRecord] {
        var records: [UsageRecord] = []
        var session = fallbackSession
        var cwd: String?
        var model = "codex"
        var previous: TokenUsage?
        forEachLine(data, containingAny: [tokenCountNeedle, turnContextNeedle, sessionMetaNeedle]) { object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String { session = id }
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                if let name = payload["model"] as? String, !name.isEmpty { model = name }
                cwd = payload["cwd"] as? String ?? cwd
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let date = (object["timestamp"] as? String).flatMap(parseDate) else { return }
                let current = codexTotal(total)
                let delta = growth(from: previous, to: current)
                previous = current
                guard let delta, !delta.isEmpty else { return }
                records.append(UsageRecord(date: date, provider: "codex", sessionId: session, model: model, cwd: cwd,
                                           tokens: delta, cost: UsagePricing.cost(model: model, tokens: delta),
                                           cacheSavings: UsagePricing.cacheSavings(model: model, tokens: delta), key: nil))
            default:
                break
            }
        }
        return records
    }

    static func codexTotal(_ total: [String: Any]) -> TokenUsage {
        func int(_ key: String) -> Int { (total[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return TokenUsage(input: max(0, int("input_tokens") - cached), cacheRead: cached,
                          cacheWrite: int("cache_write_input_tokens"), output: int("output_tokens"))
    }

    /// What a running total grew by. A total that went down is a counter
    /// that started again (a resumed process), so all of it is new.
    static func growth(from previous: TokenUsage?, to current: TokenUsage) -> TokenUsage? {
        guard let previous else { return current }
        let fell = current.input < previous.input || current.cacheRead < previous.cacheRead
            || current.cacheWrite < previous.cacheWrite || current.output < previous.output
        if fell { return current }
        return TokenUsage(input: current.input - previous.input, cacheRead: current.cacheRead - previous.cacheRead,
                          cacheWrite: current.cacheWrite - previous.cacheWrite, output: current.output - previous.output)
    }

    // MARK: OpenCode

    /// One assistant message from OpenCode's `message` table. OpenCode
    /// reports each message's cost at its provider's price; that wins over
    /// the estimate, split the way the estimate would split it. Free and
    /// subscription providers report zero, so those fall back to the estimate.
    static func openCode(messageJSON data: Data, sessionId: String) -> UsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["role"] as? String == "assistant",
              let rawTokens = object["tokens"] as? [String: Any],
              var tokens = TokenUsage.openCode(rawTokens) else { return nil }
        // Reasoning is billed as output but reported beside it.
        tokens.output += (rawTokens["reasoning"] as? NSNumber)?.intValue ?? 0
        let time = object["time"] as? [String: Any]
        guard let created = (time?["created"] as? NSNumber)?.doubleValue else { return nil }
        var model = object["modelID"] as? String ?? "opencode"
        if model.hasPrefix("~") { model.removeFirst() }
        let estimate = UsagePricing.cost(model: model, tokens: tokens)
        let reported = (object["cost"] as? NSNumber)?.doubleValue ?? 0
        let cost = reported > 0 ? estimate.scaled(to: reported) : estimate
        return UsageRecord(date: Date(timeIntervalSince1970: created / 1000), provider: "opencode", sessionId: sessionId,
                           model: model, cwd: (object["path"] as? [String: Any])?["cwd"] as? String, tokens: tokens,
                           cost: cost, cacheSavings: UsagePricing.cacheSavings(model: model, tokens: tokens), key: nil)
    }

    /// Every assistant message in OpenCode's database since `since`, read
    /// only, so a running OpenCode keeps its lock.
    static func openCode(database path: String, since: Date) -> [UsageRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        let sql = "SELECT session_id, data FROM message WHERE time_created >= ? AND data LIKE '%\"tokens\"%'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(since.timeIntervalSince1970 * 1000))
        var records: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let session = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            if let record = openCode(messageJSON: data, sessionId: String(cString: session)) { records.append(record) }
        }
        return records
    }

    // MARK: Lines

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let assistantNeedle = Array("\"assistant\"".utf8)
    private static let tokenCountNeedle = Array("\"token_count\"".utf8)
    private static let turnContextNeedle = Array("\"turn_context\"".utf8)
    private static let sessionMetaNeedle = Array("\"session_meta\"".utf8)

    /// Logs run to gigabytes, mostly tool output; a byte search skips the
    /// lines that can't matter before any JSON is parsed.
    private static func forEachLine(_ data: Data, containing all: [[UInt8]] = [], containingAny any: [[UInt8]] = [],
                                    _ body: ([String: Any]) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count
            var start = 0
            while start < count {
                let remaining = count - start
                let newline = memchr(base + start, Int32(UInt8(ascii: "\n")), remaining)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let length = end - start
                if length > 0 {
                    let line = base + start
                    let matches = all.allSatisfy { contains(line, length, $0) }
                        && (any.isEmpty || any.contains { contains(line, length, $0) })
                    if matches,
                       let object = try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length)) as? [String: Any] {
                        body(object)
                    }
                }
                start = end + 1
            }
        }
    }

    private static func contains(_ haystack: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(haystack, length, $0.baseAddress, needle.count) != nil }
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        return plain.date(from: text)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
}
