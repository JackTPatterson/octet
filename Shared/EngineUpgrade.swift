import Foundation

/// A session server older than this Octet. Updating Octet replaces the engine
/// in the app, but a server started before keeps running (that's what keeps
/// shells alive across restarts) on the old binary, which can't stream panes:
/// every pane would draw empty. The old server can hand its live panes to the
/// new binary itself (`server.live_handoff`), shells and all.
enum EngineUpgrade {
    /// What Octet asks to tell: a pane that can't exist, streamed. A current
    /// engine says there's no such pane; an older one doesn't know the call.
    static let probeMethod = "pane.stream"
    static let probeParams: [String: Any] = ["pane_id": "octet-upgrade-probe"]

    /// Whether the probe's error came from a server that predates the call.
    static func isOutdated(code: String, message: String) -> Bool {
        code == "invalid_request" && message.contains("unknown variant") && message.contains(probeMethod)
    }

    /// The request that hands the running server's panes to `enginePath`.
    static func handoffParams(enginePath: String) -> [String: Any] {
        ["import_exe": enginePath]
    }
}
