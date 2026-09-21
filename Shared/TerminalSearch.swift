import Foundation

/// Search coordinates refer to the retained buffer, not the visible viewport.
struct TerminalSearchMatch: Codable, Equatable {
    struct Point: Codable, Equatable { let row: Int; let col: Int }
    let start: Point
    let end: Point

    var parameters: [String: Any] {
        ["start": ["row": start.row, "col": start.col],
         "end": ["row": end.row, "col": end.col]]
    }
}

struct TerminalSearchResult {
    let revision: UInt64
    let total: Int
    let ordinal: Int?
    let match: TerminalSearchMatch?

    init(response: [String: Any], paneId: String) throws {
        guard response["pane_id"] as? String == paneId,
              let revision = response["content_revision"] as? UInt64,
              let total = response["total"] as? Int, total >= 0,
              let raw = response["matches"] as? [[String: Any]] else {
            throw EngineSocketError.malformedResponse("Invalid terminal search response")
        }
        self.revision = revision
        self.total = total
        if total == 0 {
            ordinal = nil
            match = nil
        } else {
            guard let current = response["current"] as? Int, raw.indices.contains(current),
                  let global = response["current_global"] as? Int, (0..<total).contains(global) else {
                throw EngineSocketError.malformedResponse("Invalid terminal search match index")
            }
            ordinal = global + 1
            match = try JSONDecoder().decode(TerminalSearchMatch.self, from: JSONSerialization.data(withJSONObject: raw[current]))
        }
    }

    /// Keep the chosen match near the middle without scrolling beyond the buffer.
    func scrollOffset(maximum: Int, viewportRows: Int) -> Int? {
        guard let match else { return nil }
        let top = max(0, match.start.row - max(0, viewportRows) / 2)
        return max(0, min(maximum, maximum - top))
    }

    static func find(paneId: String, query: String, backward: Bool, previous: TerminalSearchResult?,
                     request: (String, [String: Any]) throws -> [String: Any]) throws -> TerminalSearchResult {
        // Output may arrive between revision acquisition and search. Retry a
        // bounded number of times; never block the UI or spin on a noisy pane.
        for attempt in 0..<3 {
            do {
                let motion = try request("pane.copy_motion", ["pane_id": paneId,
                    "cursor": ["row": 0, "col": 0], "motion": "line_end"])
                guard let revision = motion["content_revision"] as? UInt64 else {
                    throw EngineSocketError.malformedResponse("Missing terminal content revision")
                }
                var params: [String: Any] = ["pane_id": paneId, "query": query,
                    "direction": backward ? "backward" : "forward",
                    "cursor": ["row": 0, "col": 0], "content_revision": revision]
                if let previous, previous.revision == revision, let match = previous.match {
                    params["previous"] = match.parameters
                    params["cursor"] = ["row": match.start.row, "col": match.start.col]
                }
                return try TerminalSearchResult(response: request("pane.copy_search", params), paneId: paneId)
            } catch EngineSocketError.server(let code, _) where code == "stale_content" && attempt < 2 {
                continue
            }
        }
        throw EngineSocketError.malformedResponse("Terminal output kept changing during search")
    }
}
