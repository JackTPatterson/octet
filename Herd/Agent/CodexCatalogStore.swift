import Foundation

/// What Codex says it can do, asked once and kept.
///
/// The pickers need this before any thread exists, so it comes from its own
/// short-lived `codex app-server`, the same way `CodexUsage` reads the
/// allowance, and is cached so the controls are populated at first paint.
@MainActor
final class CodexCatalogStore: ObservableObject {
    static let shared = CodexCatalogStore()

    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var profiles: [CodexPermissionProfile] = []
    private var loading = false

    private static let modelsKey = "herd.codex.models.v1"
    private static let profilesKey = "herd.codex.profiles.v1"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.modelsKey),
           let saved = try? JSONDecoder().decode([CodexModel].self, from: data) {
            models = saved
        }
        if let data = defaults.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([CodexPermissionProfile].self, from: data) {
            profiles = saved
        }
    }

    var defaultModel: CodexModel? { models.first(where: \.isDefault) ?? models.first }

    func model(_ id: String?) -> CodexModel? {
        guard let id else { return defaultModel }
        return models.first { $0.id == id } ?? defaultModel
    }

    /// Asks Codex what it offers. Cheap enough to call whenever a Codex
    /// conversation opens, and skipped while one is already in flight.
    func load() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let answers = CodexRPC.ask([
                CodexRPC.Call(id: 2, method: "model/list", params: [:]),
                CodexRPC.Call(id: 3, method: "permissionProfile/list", params: [:]),
            ])
            let models = CodexCatalog.models(from: answers[2])
            let profiles = CodexCatalog.profiles(from: answers[3])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CodexCatalogStore.shared.finish(models: models, profiles: profiles) }
            }
        }
    }

    private func finish(models: [CodexModel], profiles: [CodexPermissionProfile]) {
        loading = false
        let defaults = UserDefaults.standard
        if !models.isEmpty, models != self.models {
            self.models = models
            if let data = try? JSONEncoder().encode(models) { defaults.set(data, forKey: Self.modelsKey) }
        }
        if !profiles.isEmpty, profiles != self.profiles {
            self.profiles = profiles
            if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        }
    }
}
