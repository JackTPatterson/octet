import Foundation

/// Editorial family profiles for the comparison UI, not measured benchmarks.
/// Unknown models deliberately have no score. Billing text comes only from
/// the provider/catalog description, never from these relative scores.
struct ModelPickerProfile: Equatable {
    let family: String
    let subtitle: String
    let speed: Int
    let quality: Int
    let cost: Int

    static func resolve(id: String, title: String) -> ModelPickerProfile? {
        let text = (id + " " + title).lowercased()
        if text.contains("default") || text.contains("auto") { return nil }
        if text.contains("haiku") { return .init(family: "haiku", subtitle: "Quick and light", speed: 5, quality: 3, cost: 1) }
        if text.contains("sonnet") { return .init(family: "sonnet", subtitle: "Everyday work", speed: 4, quality: 4, cost: 3) }
        if text.contains("opus") { return .init(family: "opus", subtitle: "Hardest problems", speed: 2, quality: 5, cost: 5) }
        return nil
    }
    static func billing(in detail: String?) -> String? {
        guard let detail, let range = detail.range(of: #"\$[0-9]+(?:\.[0-9]+)?/\$[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        let values = detail[range].split(separator: "/")
        return "\(values[0]) in · \(values[1]) out / M tokens"
    }
    static func effectiveEffort(explicit: String?, fallback: String?, levels: [String]) -> String? {
        if let explicit, levels.contains(explicit) { return explicit }
        if let fallback, levels.contains(fallback) { return fallback }
        return levels.first
    }
}
