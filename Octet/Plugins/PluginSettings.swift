import SwiftUI

/// Settings › Plugins: Octet's own plugins, on or off, and where to add more.
struct PluginSettings: View {
    @ObservedObject private var host = OctetPluginHost.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsGroup(title: "Installed") {
            if host.plugins.isEmpty {
                SettingsRow(title: "No plugins", detail: "Add a plugin folder below, then reload.") { EmptyView() }
            }
            ForEach(Array(host.plugins.enumerated()), id: \.element.id) { index, plugin in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: plugin.manifest.name, detail: detail(plugin)) {
                    Toggle(plugin.manifest.name, isOn: Binding(
                        get: { host.isEnabled(plugin) },
                        set: { host.setEnabled(plugin, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
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
        SettingsGroup(title: "Plugin folder") {
            SettingsRow(
                title: "Plugin folder",
                detail: "Each plugin is a folder here with a plugin.json manifest. Plugins you add start turned off, because what they contribute runs as shell commands."
            ) {
                HStack(spacing: 6) {
                    Button("Reveal") { host.revealUserDirectory() }
                    Button("Reload") { host.reload() }
                }
            }
        }
        .onAppear { host.reload() }
    }

    private func detail(_ plugin: OctetPlugin) -> String {
        let manifest = plugin.manifest
        var lines: [String] = []
        if let description = manifest.description, !description.isEmpty { lines.append(description) }
        let adds = manifest.contributes.completions.map { completion in
            "Completes " + ([completion.command] + completion.path).joined(separator: " ")
        }
        if !adds.isEmpty { lines.append(adds.joined(separator: " · ")) }
        let source = plugin.isBundled ? "Built in" : (manifest.author.map { "By \($0)" } ?? "Installed")
        lines.append("\(source) · \(manifest.version)")
        return lines.joined(separator: "\n")
    }
}
