import Foundation
import Security

/// What plugins were told in Settings › Plugins. Plain values live in
/// Octet's preferences; secrets in the Keychain, as items Octet made, so
/// reading them never asks. Both reach a plugin's commands as environment
/// variables, never on a command line.
@MainActor
final class PluginSettingsStore: ObservableObject {
    static let shared = PluginSettingsStore()

    private static let defaultsKey = "octet.plugins.settings"
    /// Plain values, by plugin id then setting id.
    @Published private(set) var plain: [String: [String: String]] = [:]
    /// Secrets read once a launch, by plugin id then setting id.
    private var secrets: [String: [String: String]] = [:]
    /// Bumped on every save, for views that show whether a plugin is set up.
    @Published private(set) var revision = 0

    private init() {
        plain = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [String: String]] ?? [:]
    }

    /// Hands the stores to the shared plugin code, once at launch.
    static func install(_ plugins: [OctetPlugin]) {
        let snapshot = Snapshot()
        OctetPlugins.settingsEnvironment = { plugin in snapshot.environment(plugin) }
        // Read now, on the main actor, so a command built on another thread
        // never waits on it.
        for plugin in plugins { _ = shared.commandEnvironment(for: plugin) }
    }

    func value(_ setting: OctetPluginManifest.Setting, of plugin: OctetPlugin) -> String {
        setting.isSecret ? secret(setting.id, of: plugin.id) ?? "" : plain[plugin.id]?[setting.id] ?? ""
    }

    /// Whether every setting the plugin asks for has a value.
    func isComplete(_ plugin: OctetPlugin) -> Bool {
        (plugin.manifest.settings ?? []).allSatisfy { !value($0, of: plugin).isEmpty }
    }

    func save(_ values: [String: String], for plugin: OctetPlugin) {
        var plainValues = plain[plugin.id] ?? [:]
        for setting in plugin.manifest.settings ?? [] {
            let value = (values[setting.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if setting.isSecret {
                setSecret(value, setting.id, of: plugin.id)
            } else {
                plainValues[setting.id] = value.isEmpty ? nil : value
            }
        }
        plain[plugin.id] = plainValues.isEmpty ? nil : plainValues
        UserDefaults.standard.set(plain, forKey: Self.defaultsKey)
        Snapshot.update(plugin.id, environment(for: plugin))
        revision += 1
        GeneratorCache.shared.forget(idPrefix: "plugin.\(plugin.id).")
        NotificationCenter.default.post(name: Self.didChange, object: plugin.id)
    }

    static let didChange = Notification.Name("OctetPluginSettingsDidChange")

    /// The plugin's settings as environment variables, empty ones left out.
    func environment(for plugin: OctetPlugin) -> [String: String] {
        var environment: [String: String] = [:]
        for setting in plugin.manifest.settings ?? [] {
            let value = value(setting, of: plugin)
            if !value.isEmpty { environment[setting.id] = value }
        }
        return environment
    }

    // MARK: - Keychain

    private static func service(_ pluginId: String) -> String { "Octet plugin \(pluginId)" }

    private func secret(_ key: String, of pluginId: String) -> String? {
        if let known = secrets[pluginId]?[key] { return known.isEmpty ? nil : known }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(pluginId),
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let value = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
            ? (item as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "" : ""
        secrets[pluginId, default: [:]][key] = value
        return value.isEmpty ? nil : value
    }

    private func setSecret(_ value: String, _ key: String, of pluginId: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(pluginId),
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(match as CFDictionary)
        if !value.isEmpty {
            var add = match
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrLabel as String] = "Octet plugin \(pluginId): \(key)"
            SecItemAdd(add as CFDictionary, nil)
        }
        secrets[pluginId, default: [:]][key] = value
    }

    /// What commands are handed, readable from any thread: generators are
    /// built off the main actor too.
    private final class Snapshot: @unchecked Sendable {
        private static let lock = NSLock()
        private static var byPlugin: [String: [String: String]] = [:]

        static func update(_ pluginId: String, _ environment: [String: String]) {
            lock.lock()
            byPlugin[pluginId] = environment
            lock.unlock()
        }

        func environment(_ plugin: OctetPlugin) -> [String: String] {
            guard plugin.manifest.settings?.isEmpty == false else { return [:] }
            Self.lock.lock()
            let known = Self.byPlugin[plugin.id]
            Self.lock.unlock()
            if let known { return known }
            // A plugin installed since launch: read on the main actor, and
            // elsewhere go without until it has been.
            guard Thread.isMainThread else { return [:] }
            return MainActor.assumeIsolated { PluginSettingsStore.shared.commandEnvironment(for: plugin) }
        }
    }

    /// For plugin commands that run with an environment dictionary.
    func commandEnvironment(for plugin: OctetPlugin) -> [String: String] {
        guard plugin.manifest.settings?.isEmpty == false else { return [:] }
        let environment = environment(for: plugin)
        Snapshot.update(plugin.id, environment)
        return environment
    }
}
