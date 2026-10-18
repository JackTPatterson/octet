import Foundation

/// A plan the agent's last turn ended on, while it's still in plan mode, for
/// the banner over the composer that implements or refines it, after T3
/// Code's plan follow-up.
enum ComposerPlanFollowUp {
    struct Plan: Equatable {
        /// The item it came from, so a dismissed banner stays dismissed.
        let id: String
        let markdown: String

        /// Its first heading, or else its first line, for the banner.
        var title: String? { ComposerPlanFollowUp.title(of: markdown) }
    }

    /// Starts the message that asks for the plan to be carried out; history
    /// leaves these out, as T3 Code's does.
    static let implementationPrefix = "PLEASE IMPLEMENT THIS PLAN:\n"

    static func implementationPrompt(_ plan: Plan) -> String {
        implementationPrefix + plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The plan the latest turn ended on: Claude's ExitPlanMode call when
    /// nothing ran after it, or else, still in plan mode, a final reply laid
    /// out as a plan (a heading or a list). Nil while the turn runs, out of
    /// plan mode (approving the plan leaves it), or when the turn went on to
    /// do work.
    static func latestPlan(in items: [AgentItem], planMode: Bool, running: Bool) -> Plan? {
        guard planMode, !running else { return nil }
        let main = items.filter { $0.parent == nil }
        guard let lastUser = main.lastIndex(where: { if case .user = $0.kind { return true } else { return false } }) else { return nil }
        let turn = main[(lastUser + 1)...]
        for item in turn.reversed() {
            switch item.kind {
            case .tool(let call) where call.name == "ExitPlanMode":
                let plan = (call.inputObject?["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !plan.isEmpty { return Plan(id: item.id, markdown: plan) }
                return lastText(in: turn).map { Plan(id: item.id, markdown: $0) }
            case .tool:
                // It went on to work after its last plan, or never made one.
                return turn.last.flatMap(planShapedReply)
            default:
                continue
            }
        }
        return turn.last.flatMap(planShapedReply)
    }

    private static func lastText(in turn: ArraySlice<AgentItem>) -> String? {
        for item in turn.reversed() {
            if case .text(let text) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// A closing reply that reads as a plan: a Markdown heading, or a
    /// numbered or bulleted list of at least two steps.
    private static func planShapedReply(_ item: AgentItem) -> Plan? {
        guard case .text(let text) = item.kind else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let heading = lines.contains { $0.hasPrefix("#") }
        let steps = lines.filter { line in
            line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
        }
        guard heading || steps.count >= 2 else { return nil }
        return Plan(id: item.id, markdown: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first Markdown heading's text, or the first non-empty line,
    /// shortened for one row.
    static func title(of markdown: String) -> String? {
        let lines = markdown.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let heading = lines.first { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        guard let line = (heading?.isEmpty == false ? heading : lines.first { !$0.isEmpty }) else { return nil }
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return plain.count > 80 ? String(plain.prefix(79)) + "…" : plain
    }
}
