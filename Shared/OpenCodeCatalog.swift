import Foundation

/// What an OpenCode server offers a conversation: the models of every
/// provider it's signed in to, each model's reasoning variants, and the
/// agents (Build, Plan and any the person defined) a message can go to.
///
/// OpenCode reaches thousands of models across providers, and each provider
/// spells reasoning its own way (OpenAI's `reasoningEffort`, Anthropic's
/// adaptive thinking and budgets, Gemini's `thinkingLevel`, Bedrock's
/// `reasoningConfig`...). The server resolves all of that and reports, per
/// model, the named variants it will accept; a client only picks a name.
/// Those names come from one small vocabulary, so the effort slider can
/// order them the same way for every model.
struct OpenCodeCatalog: Equatable {
    struct Provider: Equatable, Identifiable {
        let id: String
        let name: String
        var models: [Model]
    }

    struct Model: Equatable, Identifiable {
        /// `provider/model`, as OpenCode's `--model` and config spell it.
        var id: String { "\(providerID)/\(modelID)" }
        let providerID: String
        let modelID: String
        let name: String
        let providerName: String
        /// Variant names, weakest to strongest; empty when the model has no
        /// reasoning setting to choose.
        var variants: [String] = []
        var reasoning = false
        var attachments = false
        var images = false
        var context: Int?
        var output: Int?
        /// Per million tokens; zero for free models.
        var inputCost: Double?
        var outputCost: Double?
        /// `alpha`, `beta`, `deprecated` or `active`.
        var status: String?

        var isFree: Bool { inputCost == 0 && outputCost == 0 }

        /// One line for the model menu.
        var detail: String {
            var parts: [String] = []
            if let context { parts.append("\(OpenCodeCatalog.tokens(context)) context") }
            if isFree { parts.append("free") }
            else if let inputCost, let outputCost { parts.append(String(format: "$%.2f / $%.2f per M", inputCost, outputCost)) }
            if let status, status != "active" { parts.append(status) }
            return parts.joined(separator: " · ")
        }
    }

    struct Agent: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let description: String
        /// A model this agent always uses, which the picker then shows.
        var model: String?
        var variant: String?
        var color: String?
    }

    var providers: [Provider] = []
    /// The server's default model per provider.
    var defaults: [String: String] = [:]
    /// Agents a message can be sent to (primary, not hidden), Build first.
    var agents: [Agent] = []

    var models: [Model] { providers.flatMap(\.models) }

    func model(_ id: String?) -> Model? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// The model a new conversation starts on: the config's `model` when set
    /// and available, else the default of the first signed-in provider.
    func defaultModel(configured: String?) -> Model? {
        if let configured, let model = model(configured) { return model }
        for provider in providers {
            if let id = defaults[provider.id], let model = model("\(provider.id)/\(id)") { return model }
        }
        return models.first
    }

    // MARK: - Variants

    /// OpenCode's variant names, weakest to strongest. `thinking` pairs with
    /// `none` on models that can only turn reasoning on or off.
    static let variantOrder = ["none", "minimal", "low", "medium", "thinking", "high", "xhigh", "max"]

    static func orderedVariants(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let ra = variantOrder.firstIndex(of: a) ?? variantOrder.count
            let rb = variantOrder.firstIndex(of: b) ?? variantOrder.count
            return ra == rb ? a < b : ra < rb
        }
    }

    /// What each variant means, in the slider's words.
    static let variantDetail: [String: String] = [
        "none": "No reasoning: answers straight away",
        "minimal": "The least reasoning the model allows",
        "low": "Light reasoning, quick answers",
        "medium": "Balanced reasoning",
        "thinking": "Reasoning on",
        "high": "Thorough reasoning",
        "xhigh": "Extra-thorough reasoning",
        "max": "The most reasoning the model allows",
    ]

    // MARK: - Parsing

    /// From `GET /config/providers` (the providers OpenCode is signed in to,
    /// with `default`) and `GET /agent`.
    init(providers json: [String: Any], agents agentList: [[String: Any]] = []) {
        defaults = json["default"] as? [String: String] ?? [:]
        let list = json["providers"] as? [[String: Any]] ?? []
        providers = list.compactMap(Self.provider).filter { !$0.models.isEmpty }
            .sorted { a, b in
                // OpenCode's own (Zen, Go) first, then by name.
                let ownA = a.id.hasPrefix("opencode"), ownB = b.id.hasPrefix("opencode")
                return ownA != ownB ? ownA : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        agents = Self.agents(agentList)
    }

    init() {}

    /// Every provider OpenCode knows (`GET /provider`'s `all`), signed in or
    /// not, for browsing the whole catalog.
    static func allProviders(_ json: [String: Any]) -> (providers: [Provider], connected: Set<String>) {
        let connected = Set(json["connected"] as? [String] ?? [])
        let providers = (json["all"] as? [[String: Any]] ?? []).compactMap(provider).filter { !$0.models.isEmpty }
            .sorted { a, b in
                let inA = connected.contains(a.id), inB = connected.contains(b.id)
                return inA != inB ? inA : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        return (providers, connected)
    }

    static func provider(_ json: [String: Any]) -> Provider? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String ?? id
        let raw = json["models"] as? [String: [String: Any]] ?? [:]
        let models = raw.compactMap { key, value in model(value, key: key, provider: id, providerName: name) }
            .filter { $0.status != "deprecated" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Provider(id: id, name: name, models: models)
    }

    static func model(_ json: [String: Any], key: String, provider: String, providerName: String) -> Model? {
        let id = json["id"] as? String ?? key
        let capabilities = json["capabilities"] as? [String: Any] ?? [:]
        let input = capabilities["input"] as? [String: Any] ?? [:]
        let limit = json["limit"] as? [String: Any] ?? [:]
        let cost = json["cost"] as? [String: Any] ?? [:]
        let variants = (json["variants"] as? [String: Any]).map { raw in
            // A variant can be switched off in config with `disabled: true`.
            raw.filter { ($0.value as? [String: Any])?["disabled"] as? Bool != true }.map(\.key)
        } ?? []
        var model = Model(providerID: provider, modelID: id, name: json["name"] as? String ?? id, providerName: providerName)
        model.variants = orderedVariants(variants)
        model.reasoning = capabilities["reasoning"] as? Bool ?? false
        model.attachments = capabilities["attachment"] as? Bool ?? false
        model.images = input["image"] as? Bool ?? false
        model.context = (limit["context"] as? NSNumber)?.intValue
        model.output = (limit["output"] as? NSNumber)?.intValue
        model.inputCost = (cost["input"] as? NSNumber)?.doubleValue
        model.outputCost = (cost["output"] as? NSNumber)?.doubleValue
        model.status = json["status"] as? String
        return model
    }

    static func agents(_ list: [[String: Any]]) -> [Agent] {
        let primary = list.filter { agent in
            let mode = agent["mode"] as? String
            return (mode == "primary" || mode == "all") && agent["hidden"] as? Bool != true
        }
        let agents = primary.compactMap { json -> Agent? in
            guard let name = json["name"] as? String else { return nil }
            let model = (json["model"] as? [String: Any]).flatMap { model -> String? in
                guard let provider = model["providerID"] as? String, let id = model["modelID"] as? String else { return nil }
                return "\(provider)/\(id)"
            }
            return Agent(name: name, description: json["description"] as? String ?? "", model: model,
                         variant: json["variant"] as? String, color: json["color"] as? String)
        }
        // Build, then Plan, then the person's own, as OpenCode's Tab cycles.
        let rank = ["build": 0, "plan": 1]
        return agents.sorted { (rank[$0.name] ?? 2, $0.name) < (rank[$1.name] ?? 2, $1.name) }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%gM", (Double(count) / 1_000_000 * 10).rounded() / 10)
            : "\(count / 1000)K"
    }
}
