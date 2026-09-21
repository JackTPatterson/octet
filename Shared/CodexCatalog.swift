import Foundation

/// A model Codex offers, as its app server describes it. Claude Code has no
/// way to list what a subscription allows, so `AgentSession.models` is a
/// curated list; Codex answers `model/list`, so nothing here is guessed.
struct CodexModel: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    var description: String?
    /// The efforts this model takes, in the order Codex lists them.
    var efforts: [String] = []
    var effortDetail: [String: String] = [:]
    var defaultEffort: String?
    var isDefault = false
}

/// A sandbox Codex can run a thread under, e.g. `:read-only`.
struct CodexPermissionProfile: Codable, Equatable, Identifiable {
    let id: String
    var allowed = true

    /// `:workspace` reads as "Workspace".
    var title: String {
        let name = id.hasPrefix(":") ? String(id.dropFirst()) : id
        let spaced = name.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Full access lets the agent leave the folder and reach the network.
    var isDangerous: Bool { id.contains("danger") }

    var detail: String? {
        switch id {
        case ":read-only": "Reads files; asks before anything else"
        case ":workspace": "Writes inside this folder without asking"
        case ":danger-full-access": "No sandbox: any command, any file, the network"
        default: nil
        }
    }
}

/// Reads what Codex reports about itself. The store that keeps the answers
/// lives in the app; this is just the parsing, next to the other agent
/// parsers and covered by the same tests.
enum CodexCatalog {
    static func models(from result: [String: Any]?) -> [CodexModel] {
        guard let rows = result?["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, row["hidden"] as? Bool != true else { return nil }
            let efforts = row["supportedReasoningEfforts"] as? [[String: Any]] ?? []
            var model = CodexModel(id: id, displayName: row["displayName"] as? String ?? id,
                                   description: row["description"] as? String)
            model.efforts = efforts.compactMap { $0["reasoningEffort"] as? String }
            model.effortDetail = Dictionary(uniqueKeysWithValues: efforts.compactMap { effort in
                guard let name = effort["reasoningEffort"] as? String,
                      let detail = effort["description"] as? String else { return nil }
                return (name, detail)
            })
            model.defaultEffort = row["defaultReasoningEffort"] as? String
            model.isDefault = row["isDefault"] as? Bool ?? false
            return model
        }
    }

    static func profiles(from result: [String: Any]?) -> [CodexPermissionProfile] {
        guard let rows = result?["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return CodexPermissionProfile(id: id, allowed: row["allowed"] as? Bool ?? true)
        }
    }
}
