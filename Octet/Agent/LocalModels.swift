import Foundation

/// Models running on this Mac, offered to OpenCode as providers of their own.
///
/// Ollama, LM Studio and llama.cpp's `llama-server` all speak the OpenAI API
/// on loopback. Octet asks each one what it has loaded and hands the answer
/// to OpenCode as config, so local models show up in the model menu beside the
/// hosted ones, with no keys and nothing leaving the machine.
enum LocalModels {
    struct Endpoint {
        let id: String
        let name: String
        let port: Int
        var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    }

    static let endpoints = [
        Endpoint(id: "octet-ollama", name: "Ollama (local)", port: 11434),
        Endpoint(id: "octet-lmstudio", name: "LM Studio (local)", port: 1234),
        Endpoint(id: "octet-llamacpp", name: "llama.cpp (local)", port: 8080),
    ]

    /// Asks every endpoint for its models and returns OpenCode config JSON for
    /// the ones that answered, or nil when nothing local is running. Servers
    /// that aren't running fail fast, so this is cheap to call at launch.
    static func openCodeConfig() async -> String? {
        let found = await withTaskGroup(of: (Endpoint, [String])?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let models = await models(at: endpoint)
                    return models.isEmpty ? nil : (endpoint, models)
                }
            }
            var all: [(Endpoint, [String])] = []
            for await result in group { if let result { all.append(result) } }
            return all
        }
        guard !found.isEmpty else { return nil }
        var providers: [String: Any] = [:]
        for (endpoint, models) in found {
            providers[endpoint.id] = [
                "npm": "@ai-sdk/openai-compatible",
                "name": endpoint.name,
                "options": ["baseURL": endpoint.baseURL],
                "models": Dictionary(uniqueKeysWithValues: models.map { ($0, ["name": $0]) }),
            ] as [String: Any]
        }
        let config: [String: Any] = ["$schema": "https://opencode.ai/config.json", "provider": providers]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func models(at endpoint: Endpoint) async -> [String] {
        guard let url = URL(string: endpoint.baseURL + "/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}
