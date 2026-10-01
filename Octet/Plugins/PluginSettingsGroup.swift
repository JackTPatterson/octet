import AppKit
import SwiftUI

/// Opens Settings › Plugins at one plugin's settings, from a chip, a link
/// or a toast.
@MainActor
enum PluginSettingsOpener {
    static var opener: (() -> Void)?

    static func show(pluginId: String) {
        UserDefaults.standard.set(SettingsView.Section.plugins.rawValue, forKey: SettingsView.sectionKey)
        PluginSettingsFocus.shared.pluginId = pluginId
        NSApp.activate(ignoringOtherApps: true)
        opener?()
    }
}

/// The plugin Settings was opened for, drawn picked out until it's saved.
@MainActor
final class PluginSettingsFocus: ObservableObject {
    static let shared = PluginSettingsFocus()
    @Published var pluginId: String?
}

/// One plugin's settings: a field for each value it asks for, saved
/// together. Secrets go to the Keychain.
struct PluginSettingsGroup: View {
    let plugin: OctetPlugin
    @ObservedObject private var store = PluginSettingsStore.shared
    @ObservedObject private var focus = PluginSettingsFocus.shared
    @State private var drafts: [String: String] = [:]
    @State private var loaded = false

    private var settings: [OctetPluginManifest.Setting] { plugin.manifest.settings ?? [] }

    private var changed: Bool {
        settings.contains { (drafts[$0.id] ?? "") != store.value($0, of: plugin) }
    }

    var body: some View {
        SettingsGroup(title: plugin.manifest.name) {
            ForEach(Array(settings.enumerated()), id: \.element.id) { index, setting in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: setting.title, detail: setting.detail) {
                    HStack(spacing: 6) {
                        field(setting)
                        if let link = setting.linkURL {
                            Button("Get One") { NSWorkspace.shared.open(link) }
                        }
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: store.isComplete(plugin) ? "Connected" : "Not set up yet",
                        detail: "Saved for \(plugin.manifest.name)'s commands, which read them as environment variables. Secrets go to the Keychain.") {
                Button("Save") {
                    store.save(drafts, for: plugin)
                    if focus.pluginId == plugin.id { focus.pluginId = nil }
                    ToastCenter.shared.info("Saved \(plugin.manifest.name)'s settings")
                }
                .keyboardShortcut(focus.pluginId == plugin.id ? .defaultAction : nil)
                .disabled(!changed)
            }
        }
        .overlay {
            if focus.pluginId == plugin.id {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func field(_ setting: OctetPluginManifest.Setting) -> some View {
        let binding = Binding(get: { drafts[setting.id] ?? "" }, set: { drafts[setting.id] = $0 })
        Group {
            if setting.isSecret {
                SecureField(setting.placeholder ?? "", text: binding)
            } else {
                TextField(setting.placeholder ?? "", text: binding)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 240)
        .labelsHidden()
        .onSubmit { if changed { store.save(drafts, for: plugin) } }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        drafts = Dictionary(uniqueKeysWithValues: settings.map { ($0.id, store.value($0, of: plugin)) })
    }
}
