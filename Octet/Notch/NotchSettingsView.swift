import SwiftUI

/// Settings › Notch: the Octet Notch, its behaviour and the pages it shows.
struct NotchSettingsPage: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsGroup(title: "Octet Notch") {
            SettingsRow(
                title: "Enable Notch",
                detail: "A glanceable view of Octet's agents and work at the top of the screen, around the notch on a MacBook. It works from any app, even when Octet is in the background.",
                setting: \.notch.enabled
            ) {
                Toggle("Enable Notch", isOn: $settings.values.notch.enabled).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Open the notch with",
                detail: "Hover opens it after a short pause. Click leaves it closed until you click it.",
                setting: \.notch.expand,
                disabled: !settings.values.notch.enabled
            ) {
                OctetSelect(selection: $settings.values.notch.expand,
                            options: NotchSettings.Expand.allCases.map { ($0, $0.title) }, width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Show on",
                detail: "Main is the display with the menu bar. The display with the pointer follows you between screens.",
                setting: \.notch.displays,
                disabled: !settings.values.notch.enabled
            ) {
                OctetSelect(selection: $settings.values.notch.displays,
                            options: NotchSettings.Displays.allCases.map { ($0, $0.title) }, width: 190)
            }
            SettingsDivider()
            SettingsRow(
                title: "Show on displays without a notch",
                detail: "A slim pill at the top centre that opens the same way.",
                setting: \.notch.showWithoutNotch,
                disabled: !settings.values.notch.enabled
            ) {
                Toggle("Show on displays without a notch", isOn: $settings.values.notch.showWithoutNotch)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Peek when an agent finishes or needs you",
                detail: "A one-line notice drops from the notch for a few seconds. It stays quiet while Octet is in front.",
                setting: \.notch.peekOnEvents,
                disabled: !settings.values.notch.enabled
            ) {
                Toggle("Peek when an agent finishes or needs you", isOn: $settings.values.notch.peekOnEvents)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Show in full screen",
                detail: "Otherwise the notch hides while a full-screen app, or Octet itself in full screen, is in front.",
                setting: \.notch.showInFullScreen,
                disabled: !settings.values.notch.enabled
            ) {
                Toggle("Show in full screen", isOn: $settings.values.notch.showInFullScreen)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Haptic feedback on open",
                detail: "A light tap on the trackpad when the notch opens.",
                setting: \.notch.haptic,
                disabled: !settings.values.notch.enabled
            ) {
                Toggle("Haptic feedback on open", isOn: $settings.values.notch.haptic)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "Notch size",
                setting: \.notch.size,
                disabled: !settings.values.notch.enabled
            ) {
                OctetSelect(selection: $settings.values.notch.size,
                            options: NotchSettings.Size.allCases.map { ($0, $0.title) }, width: 190)
            }
        }
        SettingsGroup(title: "Notch pages") {
            ForEach(Array(NotchTab.allCases.enumerated()), id: \.element) { index, tab in
                if index > 0 { SettingsDivider() }
                SettingsRow(
                    title: pageTitle(tab),
                    detail: pageDetail(tab),
                    setting: \.notch.tabs,
                    disabled: !settings.values.notch.enabled
                ) {
                    Toggle(pageTitle(tab), isOn: Binding(
                        get: { settings.values.notch.tabs.contains(tab) },
                        set: { settings.values.notch.set(tab, shown: $0) }
                    ))
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
                }
            }
        }
    }

    private func pageTitle(_ tab: NotchTab) -> String {
        switch tab {
        case .agents: "Agents page"
        case .now: "Now page"
        case .usage: "Usage page"
        case .actions: "Actions page"
        }
    }

    private func pageDetail(_ tab: NotchTab) -> String {
        switch tab {
        case .agents: "Every agent across your workspaces and windows, with the ones waiting on you first."
        case .now: "Background tasks, monitors and subagents, and the waits and check-ins that are ready."
        case .usage: "Each agent's allowance and when it resets."
        case .actions: "New conversations, tabs and workspaces, and your recent folders."
        }
    }
}
