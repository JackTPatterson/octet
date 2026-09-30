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
        installFormerlyBuiltIn()
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
            for item in plugin.manifest.contributes.statusItems where !item.run.isEmpty {
                items[OctetPlugins.statusItemId(plugin: plugin.id, item: item.id)] = (item, plugin)
            }
        }
        return items
    }

    /// Every chip the bar can show: Octet's own, then enabled plugins'.
    var statusDescriptors: [StatusItemDescriptor] {
        StatusBarItems.builtIns + plugins.filter(isEnabled).flatMap { plugin in
            plugin.manifest.contributes.statusItems.filter { !$0.run.isEmpty }.map { OctetPlugins.descriptor($0, of: plugin) }
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
        case "delegation": SettingsStore.shared.values.delegationEnabled
        default: false
        }
    }

    private static func setFeature(_ feature: String, _ on: Bool, in values: inout OctetSettings) {
        switch feature {
        case "peers": values.peersEnabled = on
        case "delegation": values.delegationEnabled = on
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

    private var registryWaiters: [() -> Void] = []

    /// Fetches the index; `then` runs once it's in, or once it failed.
    func loadRegistry(force: Bool = false, then: (() -> Void)? = nil) {
        if let then { registryWaiters.append(then) }
        guard !registryLoading else { return }
        guard force || !registryLoaded else { return finishRegistryLoad() }
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
                        host.registry = registry.plugins.filter { $0.problem == nil && $0.runsHere }
                        host.registryError = nil
                        host.registryLoaded = true
                    case .failure(let error):
                        host.registryError = error.localizedDescription
                    }
                    host.finishRegistryLoad()
                }
            }
        }.resume()
    }

    private func finishRegistryLoad() {
        let waiters = registryWaiters
        registryWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: - Plugins that used to be built in

    /// Plugins that shipped inside Octet before the registry. Each is
    /// installed from it once, so nobody loses the chips or icons they had;
    /// one removed afterwards stays removed, and one turned off before
    /// isn't installed.
    static let formerlyBuiltIn = ["status-chips", "dev-runtimes", "github-repos"]
    private static let formerlyBuiltInKey = "octet.plugins.formerlyBuiltInInstalled"

    func installFormerlyBuiltIn() {
        let defaults = UserDefaults.standard
        var done = Set(defaults.stringArray(forKey: Self.formerlyBuiltInKey) ?? [])
        let disabled = Set(SettingsStore.shared.values.disabledPlugins)
        for id in Self.formerlyBuiltIn where !done.contains(id) && (disabled.contains(id) || plugins.contains { $0.id == id }) {
            done.insert(id)
        }
        defaults.set(Array(done), forKey: Self.formerlyBuiltInKey)
        let wanted = Self.formerlyBuiltIn.filter { !done.contains($0) }
        guard !wanted.isEmpty else { return }
        loadRegistry { [weak self] in
            guard let self, self.registryLoaded else { return }  // Offline: next launch.
            for id in wanted {
                guard let entry = self.registry.first(where: { $0.id == id }) else {
                    // Not for this platform, or gone from the registry.
                    self.markFormerlyBuiltIn(id)
                    continue
                }
                self.install(entry, quietly: true) { installed in
                    if installed { self.markFormerlyBuiltIn(id) }
                }
            }
        }
    }

    private func markFormerlyBuiltIn(_ id: String) {
        let defaults = UserDefaults.standard
        let done = Set(defaults.stringArray(forKey: Self.formerlyBuiltInKey) ?? []).union([id])
        defaults.set(Array(done), forKey: Self.formerlyBuiltInKey)
    }

    /// The registry's newer version of an installed plugin, if there is one.
    func update(for plugin: OctetPlugin) -> PluginRegistry.Entry? {
        guard !plugin.isBundled, let entry = registry.first(where: { $0.id == plugin.id }),
              PluginRegistry.isNewer(entry.version, than: plugin.manifest.version) else { return nil }
        return entry
    }

    /// Installs (or updates) a registry plugin and turns it on: choosing it
    /// in the Marketplace is the consent a folder dropped in doesn't give.
    func install(_ entry: PluginRegistry.Entry, quietly: Bool = false, then: ((Bool) -> Void)? = nil) {
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
                if !quietly { ToastCenter.shared.info("Installed \(entry.name)", detail: "Version \(entry.version)") }
                then?(true)
            } catch {
                if !quietly { ToastCenter.shared.fail(nil, "Couldn't install \(entry.name)", detail: error.localizedDescription) }
                then?(false)
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
            // Only what has a command on this platform.
            plugin.manifest.contributes.completions.filter { !$0.run.isEmpty }.map { ($0, plugin) }
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

    // MARK: - Menu items

    typealias MenuItem = (item: OctetPluginManifest.MenuItemContribution, plugin: OctetPlugin)

    /// Enabled plugins' items for a tab's or workspace's menu in
    /// `directory`: the ones with a command here whose files are present.
    func menuItems(for place: OctetPluginManifest.MenuItemContribution.Place, directory: String) -> [MenuItem] {
        let root = Self.repositoryRoot(of: directory)
        return plugins.filter(isEnabled).flatMap { plugin in
            plugin.manifest.contributes.menuItems
                .filter { $0.isIn(place) && !$0.run.isEmpty
                    && StatusBarItems.hasMarker($0.whenFiles ?? [], from: directory, root: root) }
                .map { ($0, plugin) }
        }
    }

    /// Runs a menu item's command in `directory`, then opens what it
    /// printed in a new tab of `workspaceId`.
    func perform(_ entry: MenuItem, directory: String, workspaceId: String?, in window: WindowContext) {
        let timeout = min(max(entry.item.timeoutSeconds ?? 10, 1), 30)
        StatusCommand.run(entry.item.run, in: directory, environment: Self.environment(entry.plugin, directory: directory),
                          timeout: timeout) { [weak window] output in
            guard let window else { return }
            let result = PluginMenuOutput.parse(output)
            if result.command == nil {
                ToastCenter.shared.info(entry.item.title, detail: result.message ?? "Nothing to start here")
            }
            Self.open(result, title: entry.item.title, directory: directory, workspaceId: workspaceId, in: window)
        }
    }

    /// What every plugin command sees.
    static func environment(_ plugin: OctetPlugin, directory: String) -> [String: String] {
        ["OCTET_PLUGIN_DIR": plugin.directory, "OCTET_CWD": directory,
         "OCTET_REPO_ROOT": repositoryRoot(of: directory) ?? directory]
    }

    /// Opens the command a plugin printed in a new tab of `workspaceId`;
    /// nothing when it printed none.
    private static func open(_ result: PluginMenuOutput, title: String, directory: String,
                             workspaceId: String?, in window: WindowContext) {
        guard let command = result.command else { return }
        let label = result.label ?? title
        let cwd = result.cwd.map { $0.hasPrefix("/") ? $0 : directory + "/" + $0 } ?? directory
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var layout: [String: Any] = [
            "tab_label": label,
            // The shell stays when the command ends, so its output can be read.
            "root": ["type": "pane", "label": label, "cwd": cwd,
                     "command": [shell, "-lic", "\(command); exec \(shell) -l"]] as [String: Any],
        ]
        if let workspaceId { layout["workspace_id"] = workspaceId }
        window.applyLayout(layout, failure: "Couldn't start \(label)")
    }

    // MARK: - Panels

    typealias Panel = (panel: OctetPluginManifest.PanelContribution, plugin: OctetPlugin)

    /// Enabled plugins' tab bar panels for `directory`: the ones with a
    /// command here whose files are present.
    func panels(directory: String) -> [Panel] {
        let root = Self.repositoryRoot(of: directory)
        return plugins.filter(isEnabled).flatMap { plugin in
            plugin.manifest.contributes.panels
                .filter { !$0.run.isEmpty && StatusBarItems.hasMarker($0.whenFiles ?? [], from: directory, root: root) }
                .map { ($0, plugin) }
        }
    }

    /// Reads a panel in `directory`; nil hides its button.
    func read(_ entry: Panel, directory: String, completion: @escaping @MainActor (PluginPanel?) -> Void) {
        let timeout = min(max(entry.panel.timeoutSeconds ?? 8, 1), 30)
        StatusCommand.run(entry.panel.run, in: directory, environment: Self.environment(entry.plugin, directory: directory),
                          timeout: timeout) { completion(PluginPanel.parse($0)) }
    }

    /// Runs one of a panel's actions, asking first when it says to. A
    /// command it prints opens in a new tab and a message is shown; `done`
    /// follows either way, to read the panel again.
    func act(_ action: PluginPanel.Action, item: String?, entry: Panel, directory: String, workspaceId: String?,
             in window: WindowContext, done: @escaping () -> Void) {
        guard !entry.panel.act.isEmpty else { return }
        let run = { [weak window] in
            var environment = Self.environment(entry.plugin, directory: directory)
            environment["OCTET_ACTION"] = action.id
            if let item { environment["OCTET_ITEM"] = item }
            let timeout = min(max(entry.panel.timeoutSeconds ?? 8, 1) * 4, 120)
            StatusCommand.run(entry.panel.act, in: directory, environment: environment, timeout: timeout) { output in
                let result = PluginMenuOutput.parse(output)
                if let message = result.message { ToastCenter.shared.info(action.title, detail: message) }
                if let window {
                    Self.open(result, title: action.title, directory: directory, workspaceId: workspaceId, in: window)
                }
                done()
            }
        }
        guard let question = action.confirm else { return run() }
        ConfirmCenter.shared.ask(ConfirmCenter.Request(title: question, confirmTitle: action.title, destructive: true,
                                                       onConfirm: { _ in run() }, onCancel: { done() }))
    }

    /// The repository `directory` is in, found by its `.git`.
    static func repositoryRoot(of directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func revealUserDirectory() {
        try? FileManager.default.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: userDirectory))
    }
}
