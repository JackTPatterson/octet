import Foundation

/// A conversation as Markdown, to paste into an issue or a pull request or
/// keep: what was asked, what the agent said, and a line for each tool it
/// used. Thinking and subagents' inner steps are left out.
enum ConversationExport {
    static func markdown(title: String, agent: String, cwd: String?, items: [AgentItem], date: Date = Date()) -> String {
        var lines = ["# \(title)", ""]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var meta = [agent]
        if let cwd { meta.append("`\((cwd as NSString).abbreviatingWithTildeInPath)`") }
        meta.append(formatter.string(from: date))
        lines += ["_\(meta.joined(separator: " · "))_", ""]

        var speaker: String?
        var tools: [String] = []
        func flushTools() {
            guard !tools.isEmpty else { return }
            lines += tools + [""]
            tools = []
        }
        func heading(_ name: String) {
            guard speaker != name else { return }
            flushTools()
            lines += ["## \(name)", ""]
            speaker = name
        }

        for item in items where item.parent == nil && !item.queued {
            switch item.kind {
            case .user(let text):
                heading("You")
                if !item.images.isEmpty { lines += ["_\(item.images.count == 1 ? "1 image" : "\(item.images.count) images") attached_", ""] }
                if !text.isEmpty { lines += [text, ""] }
            case .text(let text):
                guard !text.isEmpty else { continue }
                heading(agent)
                flushTools()
                lines += [text, ""]
            case .tool(let call):
                heading(agent)
                let summary = call.summary.isEmpty ? "" : " `\(call.summary.replacingOccurrences(of: "`", with: "'"))`"
                tools.append("- **\(call.name)**\(summary)\(call.isError ? " (failed)" : "")")
            case .notice(let text):
                flushTools()
                lines += ["> \(text)", ""]
            case .thinking:
                continue
            }
        }
        flushTools()
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}
