import SwiftUI

/// The Device plane's tools, under the screen: apps, appearance, location,
/// permissions, push and the status bar, each a fold, after T3 Code's
/// device tools. What a platform can't do isn't shown for it.
struct DeviceToolsDrawer: View {
    @ObservedObject var model: DeviceHubModel
    let device: DeviceInfo
    let close: () -> Void

    @State private var appOpen = true
    @State private var appearanceOpen = false
    @State private var locationOpen = false
    @State private var permissionsOpen = false
    @State private var pushOpen = false
    @State private var statusBarOpen = false

    @State private var url = ""
    @State private var app = ""
    @State private var foreground: String?
    @State private var increaseContrast = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var permissionApp = ""
    @State private var permission = ""
    @State private var pushBundle = ""
    @State private var pushAlert = ""

    private var ios: Bool { device.platform == .ios }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tools").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Spacer()
                OctetIconButton(icon: "xmark", help: "Close Tools", action: close)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OctetCollapsible(title: "App", open: $appOpen) { appSection }
                    OctetCollapsible(title: "Appearance", open: $appearanceOpen) { appearanceSection }
                    OctetCollapsible(title: "Location", open: $locationOpen) { locationSection }
                    OctetCollapsible(title: "Permissions", open: $permissionsOpen) { permissionsSection }
                    if ios {
                        OctetCollapsible(title: "Push Notification", open: $pushOpen) { pushSection }
                        OctetCollapsible(title: "Status Bar", open: $statusBarOpen) { statusBarSection }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .octetScrollIndicators()
        }
        .background(Theme.chrome)
        .onAppear { if permission.isEmpty { permission = permissions.first ?? "" } }
    }

    private var permissions: [String] { ios ? DeviceCommands.iosPermissions : DeviceCommands.androidPermissions }

    // MARK: Sections

    @ViewBuilder private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ios {
                HStack(spacing: 6) {
                    Text(foreground.map { "Foreground: \($0)" } ?? "Foreground app unknown.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    OctetIconButton(icon: "arrow.clockwise", help: "Read Foreground App") {
                        model.foregroundApp { foreground = $0 }
                    }
                }
            }
            row {
                OctetTextField(placeholder: "https://… or myapp://", text: $url) { model.openURL(url) }
                OctetButton(title: "Open", compact: true) { model.openURL(url) }.disabled(url.isEmpty)
            }
            row {
                OctetTextField(placeholder: ios ? "Bundle ID to launch" : "Package name to launch", text: $app) { model.launch(app) }
            }
            HStack(spacing: 6) {
                OctetButton(title: "Launch", compact: true) { model.launch(app) }.disabled(app.isEmpty)
                OctetButton(title: "Terminate", kind: .ghost, compact: true) { model.terminate(app) }.disabled(app.isEmpty)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Mode") {
                OctetSegmented(selection: Binding(get: { model.dark ?? false }, set: { model.setDark($0) }),
                               items: [(false, "Light"), (true, "Dark")])
            }
            labeled("Text Size") {
                // "Default" until a size is chosen; the device has no way back to it.
                OctetSelect(selection: Binding(get: { model.textSize }, set: { if let size = $0 { model.setTextSize(size) } }),
                            options: (model.textSize == nil ? [(DeviceTextSize?.none, "Default")] : [])
                                + DeviceTextSize.allCases.map { (Optional($0), $0.title) })
                    .accessibilityLabel("Text Size")
            }
            if ios {
                HStack(spacing: 8) {
                    Text("Increase Contrast").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    Toggle("Increase Contrast", isOn: Binding(get: { increaseContrast }, set: {
                        increaseContrast = $0
                        model.setIncreaseContrast($0)
                    }))
                    .labelsHidden()
                    .toggleStyle(OctetSwitchStyle())
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            row {
                OctetTextField(placeholder: "Latitude", text: $latitude)
                OctetTextField(placeholder: "Longitude", text: $longitude)
            }
            HStack(spacing: 6) {
                OctetMenuButton({
                    DeviceLocationPreset.all.map { preset in
                        OctetMenuItem.action(preset.name) {
                            latitude = String(preset.latitude)
                            longitude = String(preset.longitude)
                            model.setLocation(latitude: preset.latitude, longitude: preset.longitude)
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("Preset")
                        OctetIcon("chevron.down", size: 9).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .fixedSize()
                .font(Theme.uiFont)
                Spacer(minLength: 4)
                let coordinate = DeviceCommands.parseCoordinate(latitude: latitude, longitude: longitude)
                OctetButton(title: "Set", kind: .primary, compact: true) {
                    if let coordinate { model.setLocation(latitude: coordinate.0, longitude: coordinate.1) }
                }
                .disabled(coordinate == nil)
                if ios {
                    OctetButton(title: "Clear", kind: .ghost, compact: true) { model.clearLocation() }
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OctetTextField(placeholder: ios ? "Bundle ID" : "Package name", text: $permissionApp)
            labeled("Permission") {
                OctetSelect(selection: $permission,
                            options: (permission.isEmpty ? [("", "Choose")] : []) + permissions.map { ($0, $0) })
                    .accessibilityLabel("Permission")
            }
            HStack(spacing: 6) {
                OctetButton(title: "Grant", compact: true) { model.permission(.grant, service: permission, app: permissionApp) }
                OctetButton(title: "Revoke", compact: true) { model.permission(.revoke, service: permission, app: permissionApp) }
                OctetButton(title: "Reset", kind: .ghost, compact: true) { model.permission(.reset, service: permission, app: permissionApp) }
            }
            .disabled(permissionApp.isEmpty || permission.isEmpty)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var pushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OctetTextField(placeholder: "Bundle ID", text: $pushBundle)
            OctetTextField(placeholder: "Alert text", text: $pushAlert) { model.push(bundle: pushBundle, alert: pushAlert) }
            OctetButton(title: "Send", kind: .primary, compact: true) { model.push(bundle: pushBundle, alert: pushAlert) }
                .disabled(pushBundle.isEmpty || pushAlert.isEmpty)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var statusBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("9:41, full battery and signal, for screenshots.")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                OctetButton(title: "Clean Status Bar", compact: true) { model.cleanStatusBar(true) }
                OctetButton(title: "Reset", kind: .ghost, compact: true) { model.cleanStatusBar(false) }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Layout

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            content()
        }
    }
}
