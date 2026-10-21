import AppKit

/// ⌘↑ / ⌘↓ in a shell pane: scrolls to the previous or next prompt.
@MainActor
enum PromptJumper {
    /// Copies the output of the last command that finished in the pane in
    /// front, from its shell's prompt marks.
    static func copyLastOutput(store: SessionStore) {
        guard let paneId = store.keyPaneId else { return }
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let marks = (try? client.call("pane.marks", ["pane_id": paneId])).flatMap(PromptMarks.init(response:))
            var output: String?
            if let marks, let last = marks.lastFinished,
               let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "recent", "lines": marks.totalRows]))?["read"]
                as? [String: Any], let text = read["text"] as? String {
                output = PromptMarks.output(of: last, in: text.components(separatedBy: "\n"))
            }
            DispatchQueue.main.async {
                guard let output, !output.isEmpty else {
                    ToastCenter.shared.info("No command output to copy",
                                            detail: marks == nil || marks?.marks.isEmpty == true
                                                ? "This shell doesn't mark its commands (Settings › Terminal › Shell integration)."
                                                : "The last command printed nothing.")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
                ClipboardWatcher.shared.acknowledge()
                ToastCenter.shared.info("Copied the last command's output", detail: ClipboardPreview.summary(output))
            }
        }
    }

    /// ⌘Home (115), ⌘End (119), ⌘PgUp (116), ⌘PgDn (121), in the pane's
    /// own terminal, which keeps its own scrollback.
    static func scroll(pane paneId: String, key: UInt16, store: SessionStore) {
        guard let view = PaneMirrorView.view(of: paneId), let scroll = view.scroll else { return }
        let page = max(1, scroll.viewportRows - 1)
        let target: Int = switch key {
        case 115: scroll.maxOffsetFromBottom
        case 119: 0
        case 116: min(scroll.maxOffsetFromBottom, scroll.offsetFromBottom + page)
        default: max(0, scroll.offsetFromBottom - page)
        }
        view.scroll(toOffsetFromBottom: target)
    }

    /// Takes the key in a pane that isn't running an agent (agents keep
    /// their own ⌘↑ / ⌘↓).
    static func handle(_ direction: PromptJump.Direction, store: SessionStore) -> Bool {
        guard let paneId = store.keyPaneId,
              !store.snapshot.agents.contains(where: { $0.paneId == paneId && $0.agent != nil }) else { return false }
        guard let scroll = PaneMirrorView.view(of: paneId)?.scroll else { return false }
        let client = store.client
        // Offsets count up from the bottom, where the pane's terminal and the
        // engine agree; rows count down from the top of the engine's own
        // scrollback, which can run longer.
        let current = scroll.offsetFromBottom, viewport = scroll.viewportRows
        DispatchQueue.global(qos: .userInitiated).async {
            guard let engine = (try? client.call("pane.get", ["pane_id": paneId]))
                    .flatMap({ ($0["pane"] as? [String: Any])?["scroll"] as? [String: Any] }),
                  let maxOffset = (engine["max_offset_from_bottom"] as? NSNumber)?.intValue else { return }
            let total = maxOffset + viewport
            // The shell's own marks when it has them, exact; else prompts
            // found by their shape.
            var rows = (try? client.call("pane.marks", ["pane_id": paneId]))
                .flatMap(PromptMarks.init(response:))?.promptRows ?? []
            if rows.isEmpty {
                guard let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "recent", "lines": total]))?["read"]
                        as? [String: Any], let text = read["text"] as? String else { return }
                var lines = text.components(separatedBy: "\n")
                // A trailing newline isn't a row.
                if lines.count > total, lines.last?.isEmpty == true { lines.removeLast() }
                rows = PromptJump.promptRows(lines)
            }
            guard let offset = PromptJump.offset(direction, rows: rows,
                                                 currentOffset: current, total: total, viewport: viewport) else { return }
            DispatchQueue.main.async { PaneMirrorView.view(of: paneId)?.scroll(toOffsetFromBottom: offset) }
        }
        return true
    }
}
