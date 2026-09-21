import Foundation

/// Kinds of palette entries; also the filter chips.
enum PaletteKind: String, CaseIterable, Identifiable {
    case action, workspace, tab, agent, project, plugin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: return "Actions"
        case .workspace: return "Workspaces"
        case .tab: return "Tabs"
        case .agent: return "Agents"
        case .project: return "Projects"
        case .plugin: return "Plugins"
        }
    }

    /// Query prefix that selects this filter, e.g. `>new tab`.
    var prefix: String {
        switch self {
        case .action: return ">"
        case .workspace: return "%"
        case .tab: return "#"
        case .agent: return "@"
        case .project: return "/"
        case .plugin: return "!"
        }
    }

    /// Splits a leading filter prefix off a raw query.
    static func parse(_ raw: String) -> (filter: PaletteKind?, query: String) {
        for kind in allCases where raw.hasPrefix(kind.prefix) {
            return (kind, String(raw.dropFirst(kind.prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return (nil, raw.trimmingCharacters(in: .whitespaces))
    }
}

/// The searchable text of a palette entry, independent of its UI and action.
struct PaletteSearchable: Equatable {
    let id: String
    let kind: PaletteKind
    let title: String
    let subtitle: String
    let keywords: [String]
}

struct PaletteRankedResult: Equatable {
    let id: String
    let score: Int
    let titleIndices: [Int]
}

enum PaletteRanking {
    static let maxResults = 250
    static let zeroStateRecents = 3

    /// Ranks entries for a query. Empty queries return recents first, then
    /// entries in kind order (actions last).
    static func rank(
        _ entries: [PaletteSearchable],
        query rawQuery: String,
        filter chipFilter: PaletteKind?,
        recentIds: [String]
    ) -> [PaletteRankedResult] {
        let (prefixFilter, query) = PaletteKind.parse(rawQuery)
        let filter = prefixFilter ?? chipFilter
        let candidates = entries.filter { filter == nil || $0.kind == filter }
        let recency = Dictionary(recentIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        guard !query.isEmpty else {
            let recent = candidates
                .filter { recency[$0.id] != nil }
                .sorted { recency[$0.id]! < recency[$1.id]! }
                .prefix(filter == nil ? zeroStateRecents : recentIds.count)
            let recentSet = Set(recent.map(\.id))
            let order: [PaletteKind] = [.workspace, .agent, .tab, .project, .plugin, .action]
            let rest = candidates
                .filter { !recentSet.contains($0.id) }
                .enumerated()
                .sorted { lhs, rhs in
                    let l = order.firstIndex(of: lhs.element.kind) ?? 0
                    let r = order.firstIndex(of: rhs.element.kind) ?? 0
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
            return (Array(recent) + rest).prefix(maxResults).map {
                PaletteRankedResult(id: $0.id, score: 0, titleIndices: [])
            }
        }

        var results: [PaletteRankedResult] = []
        for entry in candidates {
            let titleMatch = FuzzyMatcher.match(query, in: entry.title)
            let secondary = ([entry.subtitle] + entry.keywords)
                .compactMap { FuzzyMatcher.match(query, in: $0)?.score }
                .max()
                .map { $0 * 6 / 10 }
            guard let best = [titleMatch?.score, secondary].compactMap({ $0 }).max() else { continue }
            let recencyBonus = recency[entry.id].map { max(0, 12 - $0 * 2) } ?? 0
            results.append(PaletteRankedResult(
                id: entry.id,
                score: best + recencyBonus,
                titleIndices: titleMatch?.indices ?? []
            ))
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(maxResults))
    }

    /// Most-recent-first list with `id` moved to the front.
    static func recording(_ id: String, in recents: [String], limit: Int = 30) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(limit))
    }
}
