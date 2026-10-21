import SwiftUI

/// Settings › Plugins: where plugins live (the Marketplace), the folder for
/// making your own, and the settings of plugins that have some.
struct PluginSettings: View {
    @ObservedObject private var host = OctetPluginHost.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsGroup(title: "Plugins") {
            SettingsRow(
                title: "Find, add and turn off plugins",
                detail: "Plugins for your agents and for the terminal are in one place, the Marketplace. Filter by Agents or Terminal there."
            ) {
                OctetButton(title: "Open Marketplace", compact: true) {
                    MarketplaceWindow.open()
                    MarketplaceWindow.showPlugins()
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Plugin folder",
                detail: "Each terminal plugin is a folder here with a plugin.json manifest. One you add by hand starts turned off, because what it contributes runs as shell commands."
            ) {
                HStack(spacing: 6) {
                    OctetButton(title: "Reveal", compact: true) { host.revealUserDirectory() }
                    OctetButton(title: "Reload", compact: true) { host.reload() }
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Update plugins automatically",
                detail: "Installs new versions of plugins from the Marketplace as they're published, checked at launch and every few hours. Off, Octet says when there's an update."
            ) {
                HStack(spacing: 8) {
                    OctetButton(title: "Check Now", compact: true) { host.checkForUpdates(manual: true) }
                        .disabled(host.registryLoading)
                    Toggle("Update plugins automatically", isOn: $settings.values.autoUpdatePlugins)
                        .labelsHidden().toggleStyle(OctetSwitchStyle())
                }
            }
        }
        // Octet's own features that come as plugins: switched on here, and
        // their settings appear below once they are (Other Macs' and
        // Delegation's under Integrations).
        let features = host.plugins.filter { $0.isBundled && $0.manifest.feature != nil }
        if !features.isEmpty {
            SettingsGroup(title: "Built-in features") {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, plugin in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: plugin.manifest.name, detail: plugin.manifest.description) {
                        Toggle(plugin.manifest.name, isOn: Binding(get: { host.isEnabled(plugin) },
                                                                   set: { host.setEnabled(plugin, $0) }))
                            .labelsHidden().toggleStyle(OctetSwitchStyle())
                    }
                }
            }
        }
        ForEach(host.plugins.filter { $0.manifest.settings?.isEmpty == false && host.isEnabled($0) }) { plugin in
            PluginSettingsGroup(plugin: plugin)
        }
        if !host.problems.isEmpty {
            SettingsGroup(title: "Couldn't load") {
                ForEach(Array(host.problems.enumerated()), id: \.offset) { index, problem in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: problem) { EmptyView() }
                }
            }
        }
    }
}
