import Foundation

/// Moving a Claude Code conversation to another folder. Claude Code keeps
/// each session under the project folder it was started in
/// (`~/.claude/projects/<folder>/<session>.jsonl`), and `--resume` looks
/// only in the current folder's project, so a conversation can't follow a
/// `cd`. The transcript is copied into the new folder's project with every
/// record's `cwd` rewritten, and the session resumed there by the same id.
enum ConversationMove {
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One transcript record with its `cwd` pointed at `folder`. Records
    /// without one, and lines that aren't JSON objects, pass through as
    /// they are, so nothing Claude Code wrote is lost.
    static func rewriteCwd(in line: String, to folder: String) -> String {
        guard line.contains("\"cwd\""),
              let data = line.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["cwd"] is String else { return line }
        object["cwd"] = folder
        guard let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return line
        }
        return String(decoding: rewritten, as: UTF8.self)
    }

    /// Copies the transcript at `source` to `destination`, rewriting `cwd`
    /// on every record. A subagent folder beside the transcript, named for
    /// the session, is copied too.
    static func copyClaudeTranscript(from source: String, to destination: String, folder: String) throws {
        let manager = FileManager.default
        guard let data = manager.contents(atPath: source) else {
            throw Problem(message: "Couldn't read the conversation's transcript at \(source).")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { rewriteCwd(in: String($0), to: folder) }
        try manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: destination, atomically: true, encoding: .utf8)
        // Subagent transcripts live in <session id>/ next to the session.
        let sidecar = (source as NSString).deletingPathExtension
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: sidecar, isDirectory: &isDirectory), isDirectory.boolValue {
            let target = (destination as NSString).deletingPathExtension
            if manager.fileExists(atPath: target) { try manager.removeItem(atPath: target) }
            try manager.copyItem(atPath: sidecar, toPath: target)
        }
    }

    /// Where the moved transcript goes: the new folder's project.
    static func claudeDestination(sessionId: String, folder: String, home: String = NSHomeDirectory()) -> String {
        AgentConversation.claudeLogPath(sessionId: sessionId, cwd: folder, home: home)
    }
}
