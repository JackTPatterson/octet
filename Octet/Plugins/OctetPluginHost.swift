import AppKit
import Foundation

/// The plugins Octet has loaded, and which of them are on. Plugins that ship
/// with Octet start on; ones a person installs start off, because what they
/// contribute runs as that person's shell commands.
@MainActor
final class OctetPluginHost: ObservableObject {
    static let shared = OctetPluginHost()

    @Published private(set) var plugins: [OctetPlugin] = []
    /// Folders that looked like plugins but couldn't be loaded, and why.
    @Published private(set) var problems: [String] = []

    private init() { reload() }

    var bundledDirectory: String? { Bundle.main.resourceURL?.appendingPathComponent("Plugins").path }
    var userDirectory: String { OctetPlugins.userDirectory() }

    func reload() {
        let bundled = bundledDirectory
        let user = userDirectory
        let found = OctetPlugins.discover(bundled: bundled, user: user)
        plugins = found.plugins
        problems = found.problems
        runtimeMatcher = nil
    }

    // MARK: - Runtime icons

    private var runtimeMatcher: RuntimeMatcher?
    private weak var store: SessionStore?
    private var runtimeTimer: Timer?

    /// Starts marking tabs with what their panes run, for as long as a
    /// plugin with runtime rules is on.
    func attach(_ store: SessionStore) {
        self.store = store
        runtimeTimer?.invalidate()
        runtimeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRuntimes() }
        }
        refreshRuntimes()
    }

    private func refreshRuntimes() {
        let matcher = runtimeMatcher ?? RuntimeMatcher(plugins: plugins.filter(isEnabled))
        runtimeMatcher = matcher
        store?.refreshPaneRuntimes(matcher: matcher)
    }

    // MARK: - Status bar

    /// Enabled plugins' status chips, by descriptor id.
    var statusItems: [String: (item: OctetPluginManifest.StatusItemContribution, plugin: OctetPlugin)] {
        var items: [String: (OctetPluginManifest.StatusItemContribution, OctetPlugin)] = [:]
        for plugin in plugins where isEnabled(plugin) {
            for item in plugin.manifest.contributes.statusItems {
                items[OctetPlugins.statusItemId(plugin: plugin.id, item: item.id)] = (item, plugin)
            }
        }
        return items
    }

    /// Every chip the bar can show: Octet's own, then enabled plugins'.
    var statusDescriptors: [StatusItemDescriptor] {
        StatusBarItems.builtIns + plugins.filter(isEnabled).flatMap { plugin in
            plugin.manifest.contributes.statusItems.map { OctetPlugins.descriptor($0, of: plugin) }
        }
    }

    /// The chips turned on, in the order they show.
    var statusBarOrder: [String] {
        let values = SettingsStore.shared.values
        return StatusBarItems.resolve(saved: values.statusBarChips, customized: values.statusBarCustomized,
                                      seen: values.statusBarSeen, available: statusDescriptors)
    }

    /// Saves an arrangement made in Settings.
    func setStatusBarOrder(_ order: [String]) {
        var values = SettingsStore.shared.values
        values.statusBarChips = order
        values.statusBarCustomized = true
        values.statusBarSeen = Array(Set(values.statusBarSeen).union(statusDescriptors.map(\.id))).sorted()
        SettingsStore.shared.values = values
        objectWillChange.send()
    }

    func resetStatusBar() {
        var values = SettingsStore.shared.values
        values.statusBarChips = []
        values.statusBarCustomized = false
        values.statusBarSeen = []
        SettingsStore.shared.values = values
        objectWillChange.send()
    }

    /// The icon an enabled plugin has for a runtime, by its id.
    func runtimeBadge(id: String) -> RuntimeBadge? {
        let matcher = runtimeMatcher ?? RuntimeMatcher(plugins: plugins.filter(isEnabled))
        runtimeMatcher = matcher
        return matcher.badge(id: id)
    }

    func isEnabled(_ plugin: OctetPlugin) -> Bool {
        let values = SettingsStore.shared.values
        guard plugin.isBundled else { return values.enabledPlugins.contains(plugin.id) }
        if let feature = plugin.manifest.feature { return Self.isFeatureOn(feature) }
        return plugin.manifest.enabledByDefault == false
            ? values.enabledPlugins.contains(plugin.id)
            : !values.disabledPlugins.contains(plugin.id)
    }

    func setEnabled(_ plugin: OctetPlugin, _ enabled: Bool) {
        var values = SettingsStore.shared.values
        values.enabledPlugins.removeAll { $0 == plugin.id }
        values.disabledPlugins.removeAll { $0 == plugin.id }
        if plugin.isBundled, let feature = plugin.manifest.feature {
            Self.setFeature(feature, enabled, in: &values)
        } else if plugin.isBundled, plugin.manifest.enabledByDefault != false {
            if !enabled { values.disabledPlugins.append(plugin.id) }
        } else if enabled {
            values.enabledPlugins.append(plugin.id)
        }
        SettingsStore.shared.values = values
        runtimeMatcher = nil
        refreshRuntimes()
        objectWillChange.send()
    }

    /// Native features a built-in plugin stands for.
    private static func isFeatureOn(_ feature: String) -> Bool {
        switch feature {
        case "peers": SettingsStore.shared.values.peersEnabled
        default: false
        }
    }

    private static func setFeature(_ feature: String, _ on: Bool, in values: inout OctetSettings) {
        switch feature {
        case "peers": values.peersEnabled = on
        default: break
        }
    }

    /// The built-in plugin standing for a native feature, when it's on.
    func featurePlugin(_ feature: String) -> OctetPlugin? {
        plugins.first { $0.isBundled && $0.manifest.feature == feature }
    }

    // MARK: - Registry

    /// Plugins published to the registry, for the Marketplace.
    @Published private(set) var registry: [PluginRegistry.Entry] = []
    @Published private(set) var registryLoading = false
    @Published private(set) var registryLoaded = false
    @Published private(set) var registryError: String?
    /// Plugin ids being installed or updated.
    @Published private(set) var installing: Set<String> = []

    /// The index to read; a fork or a company can point Octet at its own.
    var registryURL: URL {
        UserDefaults.standard.string(forKey: "octet.plugins.registryURL").flatMap(URL.init(string:))
            ?? PluginRegistry.defaultURL
    }

    func loadRegistry(force: Bool = false) {
        guard !registryLoading, force || !registryLoaded else { return }
        registryLoading = true
        var request = URLRequest(url: registryURL)
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<PluginRegistry, Error> = Result {
                if let error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data else {
                    throw NSError(domain: "PluginRegistry", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The plugin registry didn't answer"])
                }
                return try PluginRegistry.parse(data)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let host = OctetPluginHost.shared
                    host.registryLoading = false
                    switch result {
                    case .success(let registry):
                        host.registry = registry.plugins.filter { $0.problem == nil }
                        host.registryError = nil
                        host.registryLoaded = true
                    case .failure(let error):
                        host.registryError = error.localizedDescription
                    }
                }
            }
        }.resume()
    }

    /// The registry's newer version of an installed plugin, if there is one.
    func update(for plugin: OctetPlugin) -> PluginRegistry.Entry? {
        guard !plugin.isBundled, let entry = registry.first(where: { $0.id == plugin.id }),
              PluginRegistry.isNewer(entry.version, than: plugin.manifest.version) else { return nil }
        return entry
    }

    /// Installs (or updates) a registry plugin and turns it on: choosing it
    /// in the Marketplace is the consent a folder dropped in doesn't give.
    func install(_ entry: PluginRegistry.Entry) {
        guard installing.insert(entry.id).inserted else { return }
        let root = userDirectory, registry = registryURL
        Task { @MainActor in
            defer { installing.remove(entry.id) }
            do {
                try await PluginInstaller.install(entry, into: root, registry: registry)
                reload()
                if let plugin = plugins.first(where: { $0.id == entry.id }), !isEnabled(plugin) {
                    setEnabled(plugin, true)
                }
                ToastCenter.shared.info("Installed \(entry.name)", detail: "Version \(entry.version)")
            } catch {
                ToastCenter.shared.fail(nil, "Couldn't install \(entry.name)", detail: error.localizedDescription)
            }
        }
    }

    /// Removes a plugin the person installed. Built-in ones can only be
    /// turned off.
    func uninstall(_ plugin: OctetPlugin) {
        guard !plugin.isBundled else { return }
        do {
            try FileManager.default.removeItem(atPath: plugin.directory)
            var values = SettingsStore.shared.values
            values.enabledPlugins.removeAll { $0 == plugin.id }
            SettingsStore.shared.values = values
            reload()
            refreshRuntimes()
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't remove \(plugin.manifest.name)", detail: error.localizedDescription)
        }
    }

    private var completionContributions: [(OctetPluginManifest.CompletionContribution, OctetPlugin)] {
        plugins.filter(isEnabled).flatMap { plugin in
            plugin.manifest.contributes.completions.map { ($0, plugin) }
        }
    }

    /// The completion spec for `command`: Octet's own or the corpus's, with
    /// what enabled plugins add to it.
    func spec(for command: String) -> CompletionSpec? {
        OctetPlugins.applying(completionContributions, to: SpecCorpus.merged(for: command), command: command)
    }

    /// Whether a plugin wants the menu open at this point in the line.
    func opensMenu(_ textBeforeCaret: String) -> Bool {
        OctetPlugins.opensMenu(textBeforeCaret, contributions: completionContributions.map(\.0))
    }

    /// Starts fetching values a plugin will want soon, from what's typed.
    func prefetch(line: String, cwd: String) {
        for (contribution, plugin) in completionContributions {
            guard let prefix = contribution.prefetchWhenTyping, !prefix.isEmpty, line.hasPrefix(prefix) else { continue }
            GeneratorCache.shared.refreshIfStale(OctetPlugins.generator(contribution, of: plugin), cwd: cwd)
        }
    }

    func revealUserDirectory() {
        try? FileManager.default.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: userDirectory))
    }
}
