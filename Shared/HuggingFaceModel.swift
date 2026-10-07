import Foundation

/// Adding a model from Hugging Face. A GGUF repo there is pulled by Ollama
/// (`ollama pull hf.co/<owner>/<repo>:<quantization>`), which runs it on
/// the Mac, and the model is then put in OpenCode's config as an Ollama
/// provider model, so an OpenCode conversation can pick it.
enum HuggingFaceModel {
    /// One repo, and the quantization to pull from it.
    struct Reference: Equatable, Hashable {
        let owner: String
        let repo: String
        var quantization: String?

        /// `owner/repo`, as Hugging Face spells it.
        var repoId: String { "\(owner)/\(repo)" }

        /// What Ollama pulls, and the model's name in Ollama afterwards.
        var ollamaName: String { "hf.co/\(repoId)" + (quantization.map { ":\($0)" } ?? "") }

        /// What OpenCode's menu shows: the repo without the GGUF suffix,
        /// and the quantization.
        var displayName: String {
            var name = repo
            for suffix in ["-GGUF", "-gguf", "_GGUF", ".GGUF", "-GGUF-IQ-Imatrix"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return name + (quantization.map { " (\($0))" } ?? "")
        }

        var pageURL: URL { URL(string: "https://huggingface.co/\(repoId)")! }
    }

    /// A repo, as a search turns it up.
    struct Repo: Equatable, Identifiable {
        let id: String
        var downloads: Int = 0
        var likes: Int = 0
        var owner: String { String(id.split(separator: "/").first ?? "") }
        var reference: Reference? { HuggingFaceModel.parse(id) }
    }

    /// One quantization in a repo, with how much it downloads.
    struct Quantization: Equatable, Identifiable {
        let name: String
        var bytes: Int64
        var id: String { name }
    }

    /// Ollama's choice when none is given.
    static let defaultQuantization = "Q4_K_M"

    /// The repo (and quantization) a pasted link, an `hf.co/…` name, an
    /// `ollama run …` line or a plain `owner/repo` means; nil for a search.
    static func parse(_ text: String) -> Reference? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["ollama run ", "ollama pull "] where trimmed.hasPrefix(lead) {
            trimmed = String(trimmed.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "https://hf.co/", "huggingface.co/", "hf.co/"]
        where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
            break
        }
        var quantization: String?
        if let colon = trimmed.lastIndex(of: ":"), !trimmed[trimmed.index(after: colon)...].contains("/") {
            quantization = String(trimmed[trimmed.index(after: colon)...]).uppercased()
            trimmed = String(trimmed[..<colon])
        }
        var parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts.removeFirst(), repo = parts.removeFirst()
        // A file's own page names its quantization: …/blob/main/x-Q8_0.gguf
        if quantization == nil, let file = parts.last, file.lowercased().hasSuffix(".gguf") {
            quantization = self.quantization(ofFile: file)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard [owner, repo].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              repo.lowercased() != "api", owner.lowercased() != "api" else { return nil }
        return Reference(owner: owner, repo: repo, quantization: quantization?.isEmpty == false ? quantization : nil)
    }

    /// The quantization a GGUF file is, from its name: `x-Q4_K_M.gguf`,
    /// `x.Q8_0.gguf`, `x-IQ3_XS-00001-of-00002.gguf`. Nil when it doesn't
    /// say, or for a vision projector (`mmproj-*`).
    static func quantization(ofFile name: String) -> String? {
        var stem = (name as NSString).lastPathComponent
        guard stem.lowercased().hasSuffix(".gguf") else { return nil }
        if stem.lowercased().hasPrefix("mmproj") { return nil }
        stem = String(stem.dropLast(5))
        if let shard = stem.range(of: #"-\d+-of-\d+$"#, options: .regularExpression) {
            stem.removeSubrange(shard)
        }
        let candidates = stem.split(whereSeparator: { $0 == "-" || $0 == "." }).map(String.init).reversed()
        for candidate in candidates.prefix(2) {
            let upper = candidate.uppercased()
            if upper.range(of: #"^(I?Q\d+(_[A-Z0-9]+)*|F16|F32|BF16|FP16|FP32)$"#, options: .regularExpression) != nil {
                return upper
            }
        }
        return nil
    }

    /// The quantizations a repo offers, from its `api/models` answer with
    /// blobs (each GGUF file's size), biggest last.
    static func quantizations(in json: Any) -> [Quantization] {
        let files = (json as? [String: Any])?["siblings"] as? [[String: Any]] ?? []
        var sizes: [String: Int64] = [:]
        var order: [String] = []
        for file in files {
            guard let name = file["rfilename"] as? String, let quantization = quantization(ofFile: name) else { continue }
            let size = (file["size"] as? NSNumber)?.int64Value ?? 0
            if sizes[quantization] == nil { order.append(quantization) }
            sizes[quantization, default: 0] += size
        }
        return order.map { Quantization(name: $0, bytes: sizes[$0] ?? 0) }
            .sorted { ($0.bytes, $0.name) < ($1.bytes, $1.name) }
    }

    /// The repos a search turned up, from `api/models?search=…`.
    static func repos(in json: Any) -> [Repo] {
        (json as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["id"] ?? item["modelId"]) as? String, id.contains("/") else { return nil }
            return Repo(id: id, downloads: (item["downloads"] as? NSNumber)?.intValue ?? 0,
                        likes: (item["likes"] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func searchURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            .init(name: "search", value: query), .init(name: "filter", value: "gguf"),
            .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "30"),
        ]
        return components.url!
    }

    static func repoURL(_ repoId: String) -> URL {
        URL(string: "https://huggingface.co/api/models/\(repoId)?blobs=true")!
    }

    /// The quantization to pick first: Ollama's default when the repo has
    /// it, else the one in the middle.
    static func suggested(_ quantizations: [Quantization]) -> String? {
        if quantizations.contains(where: { $0.name == defaultQuantization }) { return defaultQuantization }
        guard !quantizations.isEmpty else { return nil }
        return quantizations[quantizations.count / 2].name
    }
}

/// Ollama's streaming pull, line by line.
enum OllamaPull {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!

    struct Progress: Equatable {
        var status: String
        var completed: Int64?
        var total: Int64?
        var error: String?

        var isDone: Bool { status == "success" }

        /// How far the layer being pulled is, 0 to 1.
        var fraction: Double? {
            guard let completed, let total, total > 0 else { return nil }
            return min(1, Double(completed) / Double(total))
        }

        /// A line for the progress row: what's happening, and how much of
        /// the download is done.
        var text: String {
            if let error { return error }
            if let completed, let total, total > 0 {
                let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
                let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                return "\(done) of \(all)"
            }
            switch status {
            case "pulling manifest": return "Finding the model…"
            case "verifying sha256 digest": return "Checking the download…"
            case "writing manifest": return "Almost done…"
            case "success": return "Downloaded"
            default: return status.isEmpty ? "Downloading…" : status.prefix(1).uppercased() + status.dropFirst()
            }
        }
    }

    /// One line of the stream, or nil for one that isn't about progress.
    static func parse(line: String) -> Progress? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? String {
            return Progress(status: "error", error: error)
        }
        guard let status = object["status"] as? String else { return nil }
        return Progress(status: status, completed: (object["completed"] as? NSNumber)?.int64Value,
                        total: (object["total"] as? NSNumber)?.int64Value)
    }

    static func body(model: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])) ?? Data()
    }
}

/// Ollama as an OpenCode provider, in `opencode.json`.
enum OpenCodeOllama {
    static let providerID = "ollama"

    /// What the model is called in OpenCode: `ollama/hf.co/owner/repo:Q`.
    static func modelID(_ ollamaName: String) -> String { "\(providerID)/\(ollamaName)" }

    /// `config` with the model under Ollama's provider, the provider added
    /// if it wasn't there, everything else kept. Nil when the file isn't a
    /// JSON object, which is left alone rather than overwritten.
    static func registered(_ config: Data?, model: String, name: String) -> Data? {
        var root: [String: Any] = [:]
        if let config, !config.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else { return nil }
            root = object
        }
        var providers = root["provider"] as? [String: Any] ?? [:]
        var ollama = providers[providerID] as? [String: Any] ?? [:]
        if ollama["npm"] == nil { ollama["npm"] = "@ai-sdk/openai-compatible" }
        if ollama["name"] == nil { ollama["name"] = "Ollama" }
        var options = ollama["options"] as? [String: Any] ?? [:]
        if options["baseURL"] == nil { options["baseURL"] = "http://127.0.0.1:11434/v1" }
        ollama["options"] = options
        var models = ollama["models"] as? [String: Any] ?? [:]
        var entry = models[model] as? [String: Any] ?? [:]
        entry["name"] = name
        models[model] = entry
        ollama["models"] = models
        providers[providerID] = ollama
        root["provider"] = providers
        if root["$schema"] == nil { root["$schema"] = "https://opencode.ai/config.json" }
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
