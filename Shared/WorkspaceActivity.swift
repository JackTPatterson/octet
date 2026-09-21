import Foundation

/// When each workspace was last used, and which ones have gone idle.
///
/// The session server reports what an agent is doing, never when it last did
/// anything, so Octet stamps activity itself: a workspace is touched when it is on screen, when an agent in it
/// changes state, or when a pane title changes. Stamps persist across
/// launches. A workspace first seen with a Claude agent recovers its stamp
/// from the newest Claude transcript for that folder, so sessions abandoned
/// before Octet started don't all look fresh.
struct WorkspaceActivity: Equatable {
    /// Last-activity time per workspace id.
    private(set) var stamps: [String: Date] = [:]
    /// Last observed per-workspace signature (agent seqs + titles).
    private var signatures: [String: String] = [:]

    static let defaultIdleAfter: TimeInterval = 2 * 60 * 60

    init(stamps: [String: Date] = [:]) {
        self.stamps = stamps
    }

    /// Updates stamps from a snapshot. `recover` supplies a last-active time
    /// for a workspace seen for the first time (nil = no evidence → now).
    mutating func observe(
        _ snapshot: EngineSnapshot,
        viewedWorkspaceId: String?,
        now: Date = Date(),
        recover: (EngineWorkspace) -> Date? = { _ in nil }
    ) {
        let present = Set(snapshot.workspaces.map(\.workspaceId))
        stamps = stamps.filter { present.contains($0.key) }
        signatures = signatures.filter { present.contains($0.key) }

        for workspace in snapshot.workspaces {
            let id = workspace.workspaceId
            let signature = Self.signature(of: id, in: snapshot)
            if stamps[id] == nil {
                stamps[id] = min(recover(workspace) ?? now, now)
            } else if let previous = signatures[id], previous != signature {
                stamps[id] = now
            }
            signatures[id] = signature
        }
        if let viewedWorkspaceId, present.contains(viewedWorkspaceId) {
            stamps[viewedWorkspaceId] = now
        }
    }

    /// Changes that count as use: agent state transitions and pane titles.
    static func signature(of workspaceId: String, in snapshot: EngineSnapshot) -> String {
        let agents = snapshot.agents(inWorkspace: workspaceId)
            .sorted { $0.paneId < $1.paneId }
            .map { "\($0.paneId)=\($0.stateChangeSeq ?? 0):\($0.agentStatus.rawValue)" }
        let titles = snapshot.panes.filter { $0.workspaceId == workspaceId }
            .sorted { $0.paneId < $1.paneId }
            .map { "\($0.paneId)=\($0.terminalTitle ?? "")" }
        return (agents + titles).joined(separator: "|")
    }

    /// Splits workspaces into those kept in view and those gone idle. Never
    /// idle: pinned, focused, or an agent that is working or needs input.
    func partition(
        _ workspaces: [EngineWorkspace],
        snapshot: EngineSnapshot,
        pinned: Set<String>,
        idleAfter: TimeInterval,
        now: Date = Date()
    ) -> (active: [EngineWorkspace], idle: [EngineWorkspace]) {
        var active: [EngineWorkspace] = []
        var idle: [EngineWorkspace] = []
        for workspace in workspaces {
            if isIdle(workspace, snapshot: snapshot, pinned: pinned, idleAfter: idleAfter, now: now) {
                idle.append(workspace)
            } else {
                active.append(workspace)
            }
        }
        idle.sort { (stamps[$0.workspaceId] ?? .distantPast) > (stamps[$1.workspaceId] ?? .distantPast) }
        return (active, idle)
    }

    func isIdle(
        _ workspace: EngineWorkspace,
        snapshot: EngineSnapshot,
        pinned: Set<String>,
        idleAfter: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        let id = workspace.workspaceId
        if pinned.contains(id) || id == snapshot.focusedWorkspaceId { return false }
        let busy = snapshot.agents(inWorkspace: id).contains { $0.agentStatus == .working || $0.agentStatus == .blocked }
        if busy || workspace.agentStatus == .working || workspace.agentStatus == .blocked { return false }
        guard let stamp = stamps[id] else { return false }
        return now.timeIntervalSince(stamp) >= idleAfter
    }

    func lastActive(_ workspaceId: String) -> Date? { stamps[workspaceId] }

    /// Backdates a workspace so it reads as idle until it is used again.
    mutating func markIdle(_ workspaceId: String) {
        stamps[workspaceId] = .distantPast
    }

    /// Compact age like `45m`, `3h`, `2d`.
    static func ageLabel(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }
}

/// Recovers a last-activity time from Claude Code's own transcripts.
enum ClaudeTranscriptActivity {
    /// `~/.claude/projects/<cwd with / and . as ->/`.
    static func projectDirectory(forCwd cwd: String, home: String = NSHomeDirectory()) -> String {
        let encoded = cwd.map { $0 == "/" || $0 == "." ? "-" : String($0) }.joined()
        return home + "/.claude/projects/" + encoded
    }

    /// Timestamp of the newest message in the most recently modified
    /// transcript for `cwd`, or nil when there is none.
    static func lastActive(forCwd cwd: String, home: String = NSHomeDirectory()) -> Date? {
        let directory = projectDirectory(forCwd: cwd, home: home)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        let newest = names.filter { $0.hasSuffix(".jsonl") }
            .map { directory + "/" + $0 }
            .max { modified($0) < modified($1) }
        return newest.flatMap { lastTimestamp(inFile: $0) }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Reads only the file's tail and returns the last line's `timestamp`.
    static func lastTimestamp(inFile path: String, tailBytes: Int = 256 * 1024) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let length = min(size, UInt64(tailBytes))
        try? handle.seek(toOffset: size - length)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastTimestamp(inJSONLines: String(decoding: data, as: UTF8.self))
    }

    static func lastTimestamp(inJSONLines text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let raw = object["timestamp"] as? String else { continue }
            if let date = formatter.date(from: raw) ?? plain.date(from: raw) { return date }
        }
        return nil
    }
}
