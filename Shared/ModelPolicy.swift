import Foundation

/// What a model policy plugin is told about a conversation and what it
/// answers: the model and effort the next turn runs on, given how much of
/// the account's allowance is used.
enum ModelPolicy {
    /// The agents whose conversations Octet runs itself, and so can move.
    static let agents = ["claude", "codex"]

    /// A model the conversation can run, and the efforts it takes.
    struct Option: Equatable {
        let id: String
        let efforts: [String]
    }

    /// A model and effort; nil effort is the model's default.
    struct Pick: Codable, Equatable {
        var model: String
        var effort: String?
    }

    /// What a policy printed.
    struct Answer: Equatable {
        var model: String?
        var effort: String?
        var message: String?
    }

    /// `model: <id>`, `effort: <level>` and `message: <why>` lines; others
    /// are ignored, and the last of each wins.
    static func parse(_ output: String) -> Answer {
        var answer = Answer()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "model": answer.model = value
            case "effort": answer.effort = value.lowercased()
            case "message": answer.message = String(value.prefix(200))
            default: continue
            }
        }
        return answer
    }

    /// The variable a window's usage is in: `5h` is OCTET_USAGE_5H, `7d
    /// Opus` is OCTET_USAGE_7D_OPUS.
    static func variable(forWindow name: String) -> String {
        let suffix = name.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return "OCTET_USAGE_" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// The policy's environment: the agent, the person's pick, what it can
    /// be moved to (`OCTET_MODELS`, as the picker lists them), the efforts
    /// the picked model takes, and each running window's percentage used,
    /// with the fullest as OCTET_USAGE and OCTET_USAGE_WINDOW.
    static func environment(agent: String, pick: Pick, options: [Option], windows: [UsageWindow]) -> [String: String] {
        var environment = [
            "OCTET_AGENT": agent,
            "OCTET_MODEL": pick.model,
            "OCTET_EFFORT": pick.effort ?? "",
            "OCTET_MODELS": options.map(\.id).joined(separator: " "),
            "OCTET_EFFORTS": (options.first { $0.id == pick.model }?.efforts ?? []).joined(separator: " "),
            "OCTET_USAGE": "0",
            "OCTET_USAGE_WINDOW": "",
        ]
        for window in windows {
            environment[variable(forWindow: window.name)] = String(percent(window.used))
        }
        if let fullest = windows.max(by: { $0.used < $1.used }) {
            environment["OCTET_USAGE"] = String(percent(fullest.used))
            environment["OCTET_USAGE_WINDOW"] = fullest.name
            if let resetsAt = fullest.resetsAt {
                environment["OCTET_USAGE_RESETS_AT"] = String(Int(resetsAt.timeIntervalSince1970))
            }
        }
        return environment
    }

    static func percent(_ used: Double) -> Int { Int((min(max(used, 0), 1) * 100).rounded()) }

    /// What the answer moves the conversation to: a model it can run and an
    /// effort that model takes. A model it can't run is ignored; an effort
    /// the model doesn't take falls back to the pick's, or the model's
    /// default.
    static func resolve(_ answer: Answer, pick: Pick, options: [Option]) -> Pick {
        let model = answer.model.flatMap { id in options.contains { $0.id == id } ? id : nil } ?? pick.model
        let efforts = options.first { $0.id == model }?.efforts ?? []
        if let effort = answer.effort, efforts.contains(effort) { return Pick(model: model, effort: effort) }
        if let effort = pick.effort, efforts.contains(effort) || model == pick.model { return Pick(model: model, effort: effort) }
        return Pick(model: model, effort: nil)
    }

    /// What an answer depends on: asked again only when this changes.
    static func key(agent: String, pick: Pick, windows: [UsageWindow]) -> String {
        let usage = windows.sorted { $0.name < $1.name }.map { "\($0.name)=\(percent($0.used))" }
        return ([agent, pick.model, pick.effort ?? "-"] + usage).joined(separator: "|")
    }
}
