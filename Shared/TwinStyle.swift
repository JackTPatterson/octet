import Foundation

/// How one agent's interface reads, so the twin can be that interface rather
/// than a generic chat window. Claude marks a step with `●` and what came
/// back with `⎿`, and calls an edit an Update; Codex writes `•` and calls the
/// same thing a patch. Keeping those makes the twin the agent you know.
struct TwinStyle: Equatable {
    let id: String
    let displayName: String
    /// Marks a step the agent took.
    let bullet: String
    /// Marks what came back from it.
    let resultMarker: String
    /// Sits at the head of the input box.
    let promptPrefix: String
    /// What the agent calls the key it interrupts on.
    let interruptHint: String
    /// What it calls its checklist.
    let planTitle: String

    static func forAgent(_ agent: String?) -> TwinStyle {
        switch AgentBrand.forAgent(agent)?.id {
        case "claude": claude
        case "codex": codex
        default: generic(AgentBrand.forAgent(agent)?.displayName ?? "Agent")
        }
    }

    static let claude = TwinStyle(
        id: "claude",
        displayName: "Claude Code",
        bullet: "●",
        resultMarker: "⎿",
        promptPrefix: ">",
        interruptHint: "esc to interrupt",
        planTitle: "To do"
    )

    static let codex = TwinStyle(
        id: "codex",
        displayName: "Codex",
        bullet: "•",
        resultMarker: "└",
        promptPrefix: "›",
        interruptHint: "esc to interrupt",
        planTitle: "Plan"
    )

    static func generic(_ name: String) -> TwinStyle {
        TwinStyle(id: "generic", displayName: name, bullet: "•", resultMarker: "└",
                  promptPrefix: "›", interruptHint: "esc to interrupt", planTitle: "Plan")
    }

    /// What this agent calls the tool, in its own words: Claude writes
    /// `Update(file.swift)` where the call is named Edit.
    func toolTitle(_ name: String) -> String {
        let lowered = name.lowercased()
        switch id {
        case "claude":
            if lowered == "edit" || lowered == "multiedit" { return "Update" }
            if lowered == "notebookedit" { return "Update notebook" }
            return name
        default:
            if lowered.contains("apply_patch") || lowered.contains("edit") { return "Apply patch" }
            if lowered == "exec" || lowered.contains("shell") { return "Run" }
            return name
        }
    }

    /// `Bash(npm test)` — the title an agent puts on a step.
    func callLine(tool: String, argument: String, limit: Int = 120) -> String {
        let title = toolTitle(tool)
        guard !argument.isEmpty else { return title }
        let room = max(8, limit - title.count - 2)
        let value = argument.count > room ? String(argument.prefix(room - 1)) + "…" : argument
        return "\(title)(\(value))"
    }

    /// `claude-opus-5-20260101` reads better as `opus-5`; `gpt-5-codex` is
    /// already what its agent calls it, so it is left alone.
    static func shortModel(_ model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        // A release date isn't the model's name.
        parts.removeAll { part in part.count >= 6 && part.allSatisfy { $0.isNumber } }
        if parts.first == "claude", parts.count > 1 { parts.removeFirst() }
        return parts.isEmpty ? model : parts.joined(separator: "-")
    }

    /// `~/Developer/herd`, or `…/scratchpad/twin/proj` when there is no home
    /// to measure it against: the folder, not the path to it.
    static func shortPath(_ path: String, keeping components: Int = 2) -> String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        guard !tilde.hasPrefix("~") else { return tilde }
        let parts = tilde.split(separator: "/")
        guard parts.count > components else { return tilde }
        return "…/" + parts.suffix(components).joined(separator: "/")
    }

    /// `Ran 3 commands · 2 files changed` style line under a step, from what
    /// came back. Empty when there is nothing worth saying.
    static func resultLine(_ output: String, limit: Int = 200) -> String {
        let lines = output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return "" }
        let head = first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
        guard lines.count > 1 else { return head }
        return "\(head)  (+\(lines.count - 1) line\(lines.count == 2 ? "" : "s"))"
    }
}
