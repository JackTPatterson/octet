import Foundation

/// ⌘↑ / ⌘↓ in a shell pane: scrolls to the previous or next prompt.
@MainActor
enum PromptJumper {
    /// Takes the key in a pane that isn't running an agent (agents keep
    /// their own ⌘↑ / ⌘↓).
    static func handle(_ direction: PromptJump.Direction, store: SessionStore) -> Bool {
        guard let paneId = store.keyPaneId,
              !store.snapshot.agents.contains(where: { $0.paneId == paneId && $0.agent != nil }) else { return false }
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pane = (try? client.call("pane.get", ["pane_id": paneId]))?["pane"] as? [String: Any],
                  let scroll = pane["scroll"] as? [String: Any],
                  let current = (scroll["offset_from_bottom"] as? NSNumber)?.intValue,
                  let maxOffset = (scroll["max_offset_from_bottom"] as? NSNumber)?.intValue,
                  let viewport = (scroll["viewport_rows"] as? NSNumber)?.intValue else { return }
            let total = maxOffset + viewport
            guard let read = (try? client.call("pane.read", ["pane_id": paneId, "source": "recent", "lines": total]))?["read"]
                    as? [String: Any], let text = read["text"] as? String else { return }
            var lines = text.components(separatedBy: "\n")
            // A trailing newline isn't a row.
            if lines.count > total, lines.last?.isEmpty == true { lines.removeLast() }
            guard let offset = PromptJump.offset(direction, rows: PromptJump.promptRows(lines),
                                                 currentOffset: current, total: total, viewport: viewport) else { return }
            _ = try? client.call("pane.scroll", ["pane_id": paneId, "offset_from_bottom": offset])
        }
        return true
    }
}
