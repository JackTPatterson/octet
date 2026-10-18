import SwiftUI

/// Settings › Agents & Recovery › Check-ins: the rules long-haul check-ins
/// follow (see CheckInCenter).
struct CheckInSettingsGroup: View {
    @ObservedObject var settings: SettingsStore

    /// Every half hour, as "9:30 AM".
    static let times: [(value: Int, title: String)] = stride(from: 0, to: 24 * 60, by: 30).map { minute in
        (minute, CheckInRecurrence.clock(hour: minute / 60, minute: minute % 60))
    }

    var body: some View {
        SettingsGroup(title: "Check-ins") {
            SettingsRow(
                title: "Pause all check-ins",
                detail: "Nothing comes round, wakes or reminds while this is on. When you turn it off, whatever fell due in the meantime runs once, not once for each time it was missed.",
                setting: \.checkInsPaused
            ) {
                Toggle("Pause all check-ins", isOn: $settings.values.checkInsPaused).labelsHidden().toggleStyle(OctetSwitchStyle())
            }
            SettingsDivider()
            SettingsRow(
                title: "New check-ins",
                detail: "What a check-in does when it comes round, unless you choose otherwise. Waking only ever sends the prompt you saved to that agent's own session.",
                setting: \.checkInDefaultMode
            ) {
                OctetSelect(selection: $settings.values.checkInDefaultMode,
                            options: CheckInMode.allCases.map { ($0.rawValue, $0.title) }, width: 170)
                    .accessibilityLabel("New check-ins")
            }
            SettingsDivider()
            SettingsRow(
                title: "Say when a session looks stalled",
                detail: "A session marked working that has shown no output or activity for this long gets a gentle notice in the sidebar with Resume, Snooze and Ignore. Octet never stops it or sends anything for you.",
                isDefault: settings.values.stallDetection == OctetSettings.defaults.stallDetection
                    && settings.values.stallHours == OctetSettings.defaults.stallHours,
                reset: {
                    settings.values.stallDetection = OctetSettings.defaults.stallDetection
                    settings.values.stallHours = OctetSettings.defaults.stallHours
                }
            ) {
                HStack(spacing: 10) {
                    OctetNumberField(label: "Hours without activity", value: $settings.values.stallHours, range: 1...72, unit: "h",
                                     spokenValue: { "\(Int($0)) hours" }, width: 110)
                        .disabled(!settings.values.stallDetection)
                    Toggle("Say when a session looks stalled", isOn: $settings.values.stallDetection)
                        .labelsHidden().toggleStyle(OctetSwitchStyle())
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Quiet hours",
                detail: "No prompts are sent to agents during these hours. A check-in that falls in them waits until they end; you're still reminded.",
                isDefault: settings.values.quietHours == OctetSettings.defaults.quietHours
                    && settings.values.quietStartMinute == OctetSettings.defaults.quietStartMinute
                    && settings.values.quietEndMinute == OctetSettings.defaults.quietEndMinute,
                reset: {
                    settings.values.quietHours = OctetSettings.defaults.quietHours
                    settings.values.quietStartMinute = OctetSettings.defaults.quietStartMinute
                    settings.values.quietEndMinute = OctetSettings.defaults.quietEndMinute
                }
            ) {
                HStack(spacing: 8) {
                    OctetSelect(selection: $settings.values.quietStartMinute, options: Self.times, width: 104)
                        .accessibilityLabel("Quiet hours start")
                        .disabled(!settings.values.quietHours)
                    Text("to").font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    OctetSelect(selection: $settings.values.quietEndMinute, options: Self.times, width: 104)
                        .accessibilityLabel("Quiet hours end")
                        .disabled(!settings.values.quietHours)
                    Toggle("Quiet hours", isOn: $settings.values.quietHours).labelsHidden().toggleStyle(OctetSwitchStyle())
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Remind me when Octet is closed",
                detail: "Schedules a macOS notification for each upcoming check-in, so you're reminded even if Octet isn't running. Clicking one opens Octet, which catches up and runs it. Octet installs nothing else: no background agent, and nothing outside its own data and these notifications.",
                setting: \.checkInsNotifyWhenClosed
            ) {
                Toggle("Remind me when Octet is closed", isOn: $settings.values.checkInsNotifyWhenClosed)
                    .labelsHidden().toggleStyle(OctetSwitchStyle())
            }
        }
    }
}
