import Foundation

/// Context occupancy, never inferred from transcript character counts or billing totals.
struct ContextWindowUsage {
    struct Part: Identifiable, Equatable {
        let id: String
        let label: String
        let tokens: Int
    }
    let used: Int?
    let limit: Int?
    let parts: [Part]

    init(used: Int?, limit: Int?, tokens: TokenUsage?) {
        self.used = used.map { max(0, $0) }
        self.limit = limit.flatMap { $0 > 0 ? $0 : nil }
        // Latest-call cache figures are a breakdown only when they account for
        // this exact occupancy. Otherwise show the provider's total as one part.
        if let used = self.used, let tokens, tokens.input >= 0, tokens.cacheRead >= 0,
           tokens.cacheWrite >= 0, tokens.read == used {
            parts = [Part(id: "input", label: "Uncached input", tokens: tokens.input),
                     Part(id: "cache-read", label: "Cached input", tokens: tokens.cacheRead),
                     Part(id: "cache-write", label: "New cache", tokens: tokens.cacheWrite)].filter { $0.tokens > 0 }
        } else if let used = self.used, used > 0 {
            parts = [Part(id: "context", label: "Session context", tokens: used)]
        } else { parts = [] }
    }
    var fraction: Double? {
        guard let used, let limit else { return nil }
        return min(1, Double(used) / Double(limit))
    }
    var remaining: Int? {
        guard let used, let limit else { return nil }
        return max(0, limit - used)
    }
    /// Cumulative rounding keeps the grid bounded and the total fill accurate.
    func cells(count: Int = 216) -> [String?] {
        guard count > 0 else { return [] }
        guard let limit else { return Array(repeating: nil, count: count) }
        var cells = [String?](), total = 0.0
        for part in parts {
            total += Double(part.tokens)
            let end = min(count, Int((min(1, total / Double(limit)) * Double(count)).rounded(.up)))
            cells.append(contentsOf: repeatElement(Optional(part.id), count: max(0, end - cells.count)))
        }
        cells.append(contentsOf: repeatElement(nil, count: count - cells.count))
        return cells
    }
}
