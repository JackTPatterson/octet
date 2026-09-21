import Foundation

/// OpenCode's models, variants and agents, as its server reports them for a
/// folder (a project can define its own agents and providers). Loaded when a
/// conversation opens and kept per folder.
@MainActor
final class OpenCodeCatalogStore: ObservableObject {
    static let shared = OpenCodeCatalogStore()

    @Published private(set) var catalogs: [String: OpenCodeCatalog] = [:]
    /// The `model` set in OpenCode's config, per folder.
    @Published private(set) var configuredModels: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var loading: Set<String> = []

    func catalog(for cwd: String) -> OpenCodeCatalog { catalogs[cwd] ?? OpenCodeCatalog() }

    /// Every model OpenCode knows, from every provider, and which providers
    /// it's signed in to. Fetched when first browsed.
    @Published private(set) var everything: (providers: [OpenCodeCatalog.Provider], connected: Set<String>)?
    @Published private(set) var everythingError: String?

    func loadEverything(cwd: String) {
        everythingError = nil
        OpenCodeServer.shared.request("GET", "provider", directory: cwd) { [weak self] result in
            switch result {
            case .success(let json):
                // Thousands of models: parsed off the main thread.
                let raw = json as? [String: Any] ?? [:]
                DispatchQueue.global(qos: .userInitiated).async {
                    let parsed = OpenCodeCatalog.allProviders(raw)
                    DispatchQueue.main.async { self?.everything = parsed }
                }
            case .failure(let failure):
                self?.everythingError = failure.description
            }
        }
    }

    /// Fetches the folder's catalog, then calls `done`; again, if asked, to
    /// pick up a provider signed in to since.
    func load(cwd: String, refresh: Bool = false, done: (() -> Void)? = nil) {
        guard refresh || catalogs[cwd] == nil else { done?(); return }
        guard loading.insert(cwd).inserted else { return }
        let server = OpenCodeServer.shared
        var providers: [String: Any]?
        var agents: [[String: Any]] = []
        var configured: String?
        var failure: String?
        let group = DispatchGroup()
        for path in ["config/providers", "agent", "config"] {
            group.enter()
            server.request("GET", path, directory: cwd) { result in
                switch (path, result) {
                case ("config/providers", .success(let json)): providers = json as? [String: Any]
                case ("agent", .success(let json)): agents = json as? [[String: Any]] ?? []
                case ("config", .success(let json)): configured = (json as? [String: Any])?["model"] as? String
                case (_, .failure(let error)): failure = failure ?? error.description
                default: break
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loading.remove(cwd)
                if let providers {
                    self.catalogs[cwd] = OpenCodeCatalog(providers: providers, agents: agents)
                    self.configuredModels[cwd] = configured
                    self.errors[cwd] = nil
                } else if let failure {
                    self.errors[cwd] = failure
                }
                done?()
            }
        }
    }
}
