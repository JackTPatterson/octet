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

    func isEnabled(_ plugin: OctetPlugin) -> Bool {
        let values = SettingsStore.shared.values
        return plugin.isBundled
            ? !values.disabledPlugins.contains(plugin.id)
            : values.enabledPlugins.contains(plugin.id)
    }

    func setEnabled(_ plugin: OctetPlugin, _ enabled: Bool) {
        var values = SettingsStore.shared.values
        values.enabledPlugins.removeAll { $0 == plugin.id }
        values.disabledPlugins.removeAll { $0 == plugin.id }
        if plugin.isBundled, !enabled { values.disabledPlugins.append(plugin.id) }
        if !plugin.isBundled, enabled { values.enabledPlugins.append(plugin.id) }
        SettingsStore.shared.values = values
        runtimeMatcher = nil
        refreshRuntimes()
        objectWillChange.send()
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
