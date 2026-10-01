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
                Button("Open Marketplace") {
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
                    Button("Reveal") { host.revealUserDirectory() }
                    Button("Reload") { host.reload() }
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Update plugins automatically",
                detail: "Installs new versions of plugins from the Marketplace as they're published, checked at launch and every few hours. Off, Octet says when there's an update."
            ) {
                HStack(spacing: 8) {
                    Button("Check Now") { host.checkForUpdates(manual: true) }
                        .disabled(host.registryLoading)
                    Toggle("Update plugins automatically", isOn: $settings.values.autoUpdatePlugins)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        if !host.problems.isEmpty {
            SettingsGroup(title: "Couldn't load") {
                ForEach(Array(host.problems.enumerated()), id: \.offset) { index, problem in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: problem) { EmptyView() }
                }
            }
        }
        // A plugin's own settings, while it's on.
        if settings.values.peersEnabled {
            PeersSettingsGroup(settings: settings)
        }
        if settings.values.delegationEnabled {
            DelegationSettingsGroup(settings: settings)
        }
    }
}
