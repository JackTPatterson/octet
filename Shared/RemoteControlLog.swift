import Foundation

/// Whether a Claude Code session in a terminal has Remote Control on, from
/// its session log. `/remote-control` writes a `bridge_status` record with
/// the session's claude.ai link when it connects; run again, it turns Remote
/// Control off and writes only the command. Records from before the Claude
/// process started belong to an earlier run of a resumed session.
struct RemoteControlLog: Equatable {
    private(set) var url: URL?
    private(set) var isOn = false
    /// A `/remote-control` seen while on: off, unless it reconnects.
    private var toggledWhileOn = false

    /// Folds in one log line; `since` is when the Claude process started.
    mutating func consume(_ line: String, since: Date?) {
        // Most lines are neither; skip them before parsing.
        guard line.contains("bridge_status") || line.contains("remote-control") else { return }
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              record["type"] as? String == "system" else { return }
        if let since, let stamp = record["timestamp"] as? String, let date = Self.date(stamp), date < since { return }
        switch record["subtype"] as? String {
        case "bridge_status":
            url = (record["url"] as? String).flatMap(URL.init(string:)) ?? url
            isOn = true
            toggledWhileOn = false
        case "local_command":
            let command = (record["commandRun"] as? [String: Any])?["command"] as? String
            guard command == "remote-control" || command == "rc" else { return }
            // The command's echo comes first; its bridge_status (if it
            // connected) follows. A toggle that isn't followed by one is off.
            if isOn {
                if toggledWhileOn { isOn = false; url = nil }
                toggledWhileOn = true
            }
        default:
            break
        }
    }

    /// On as of the lines read so far: a toggle while on with no reconnect
    /// after it has turned it off.
    var active: Bool { isOn && !toggledWhileOn }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
