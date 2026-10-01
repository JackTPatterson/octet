import Foundation

/// The models Claude Code offers this account, from its `initialize`
/// answer: what the picker lists, and which effort levels each takes.
enum ClaudeModelCatalog {
    struct Entry: Codable, Equatable {
        /// What `--model` and `set_model` take.
        let id: String
        let name: String
        let detail: String
        /// Empty for a model with no effort setting.
        let efforts: [String]
    }

    static func entries(fromInitialize initialize: [String: Any]) -> [Entry] {
        guard let models = initialize["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let value = model["value"] as? String, !value.isEmpty else { return nil }
            // "default" follows whatever Claude Code recommends; pinning
            // what it resolves to now keeps a conversation on one model.
            let resolved = model["resolvedModel"] as? String
            let id = value == "default" ? (resolved ?? value) : value
            let efforts = model["supportsEffort"] as? Bool == false ? [] : (model["supportedEffortLevels"] as? [String] ?? [])
            return Entry(id: id, name: model["displayName"] as? String ?? value,
                         detail: model["description"] as? String ?? resolved ?? "", efforts: efforts)
        }
    }
}
