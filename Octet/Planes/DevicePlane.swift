import SwiftUI

/// The Device plane: a picker of simulators and emulators, then the chosen
/// device's live screen with controls. `deviceId` nil shows the picker.
/// After T3 Code's device hub, done natively: simctl, AXe and adb rather
/// than a Node hub.
struct DevicePlane: View {
    /// The plane's tab, so the floating preview can bring it back.
    let planeId: String
    let deviceId: String?
    let visible: Bool
    let onOpen: (DeviceInfo) -> Void
    let askAgent: (String) -> Void
    /// Puts this plane in front of a visible panel (Open in Panel).
    let showPlane: () -> Void
    /// Shows this plane's Set Up Devices dialog over the window.
    let presentSetup: (DeviceHubModel) -> Void
    @StateObject private var model: DeviceHubModel

    init(planeId: String, deviceId: String?, visible: Bool, onOpen: @escaping (DeviceInfo) -> Void,
         askAgent: @escaping (String) -> Void, showPlane: @escaping () -> Void,
         presentSetup: @escaping (DeviceHubModel) -> Void) {
        self.planeId = planeId
        self.deviceId = deviceId
        self.visible = visible
        self.onOpen = onOpen
        self.askAgent = askAgent
        self.showPlane = showPlane
        self.presentSetup = presentSetup
        _model = StateObject(wrappedValue: DeviceHubModel(deviceId: deviceId))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .picker:
                DevicePicker(model: model) { model.open($0, onOpen: onOpen) }
            case .live where model.floating, .connecting where model.floating:
                // The float has the one stream; the plane says where it went.
                DeviceFloatingNotice(model: model) { DeviceFloat.shared.openInPanel() }
            case .live:
                DeviceLiveView(model: model, askAgent: askAgent) { DeviceFloat.shared.float(planeId: planeId) }
            default:
                DeviceStatusView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
        .onAppear {
            DeviceFloat.shared.register(planeId: planeId, model: model, showPlane: showPlane)
            model.appear(visible: visible)
        }
        .onDisappear {
            DeviceFloat.shared.unregister(planeId: planeId)
            model.setupShowing = false
            model.disappear()
        }
        .onChange(of: visible) { _, now in
            model.setVisible(now)
            presentSetupIfWanted()
        }
        .onChange(of: model.setupShowing) { _, _ in presentSetupIfWanted() }
        .onChange(of: deviceId) { _, now in model.show(id: now) }
    }

    /// Set Up Devices is drawn over the whole window, where its stepper has
    /// room; the plane asks for it while it's the one in front, so a plane
    /// restored behind another doesn't raise it at launch.
    private func presentSetupIfWanted() {
        if model.setupShowing && visible { presentSetup(model) }
    }
}

// MARK: - Picker

private struct DevicePicker: View {
    @ObservedObject var model: DeviceHubModel
    let open: (DeviceInfo) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Devices")
                        .font(Theme.interfaceFont(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if model.listing || PlaneLoadingPreview.shows("device") { LoadingLine(width: 18) }
                    Spacer()
                    OctetButton(title: "Refresh Devices", icon: "arrow.clockwise", compact: true) {
                        Task { await model.refresh() }
                    }
                    .disabled(model.listing)
                }
                if PlaneLoadingPreview.shows("device") || (model.listing && !model.listedOnce && model.devices.isEmpty) {
                    DeviceListSkeleton()
                } else {
                    if model.listedOnce && model.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            note("No simulators or emulators were found on this Mac.")
                            OctetButton(title: "Set Up Devices…", compact: true) { model.setupShowing = true }
                        }
                    }
                    if !model.iosDevices.isEmpty {
                        group("iOS Simulators", model.iosDevices)
                    } else if model.listedOnce && model.xcodeMissing {
                        note("iOS Simulators need Xcode.")
                    }
                    if !model.androidDevices.isEmpty {
                        group("Android Emulators", model.androidDevices)
                    }
                    if model.listedOnce && model.androidMissing {
                        note("Android SDK was not found. Install it with Android Studio or set ANDROID_HOME to your SDK directory.")
                    }
                }
            }
            .padding(14)
        }
        .octetScrollIndicators()
    }

    private func group(_ title: String, _ devices: [DeviceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(devices) { device in
                DeviceRow(device: device, pending: model.pending.contains(device.id)) { open(device) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let pending: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            OctetIcon(device.isTablet ? "device.ipad" : device.platform == .ios ? "device.iphone" : "device.android", size: 15)
                .foregroundStyle(device.booted ? Theme.textPrimary : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(device.statusLine)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if pending {
                LoadingLine(width: 28)
            } else {
                OctetButton(title: device.booted ? "Open" : "Start", kind: device.booted ? .primary : .secondary,
                            compact: true, action: open)
                    .opacity(hovered || device.booted ? 1 : 0.85)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { if !pending { open() } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: device.booted ? "Open" : "Start", open)
    }
}

// MARK: - Starting, stopped, failed

private struct DeviceStatusView: View {
    @ObservedObject var model: DeviceHubModel

    var body: some View {
        VStack(spacing: 10) {
            OctetIcon(model.current?.isTablet == true ? "device.ipad" : "device.iphone", size: 28)
                .foregroundStyle(Theme.textTertiary)
            if let device = model.current {
                Text(device.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                if !device.version.isEmpty {
                    Text(device.version).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
            switch model.phase {
            case .starting:
                message("Starting \(model.current?.name ?? "the device")… This can take a minute.")
                LoadingLine(width: 120)
            case .connecting:
                if model.noVideo {
                    noVideo
                } else {
                    message(model.current == nil ? "Looking for the device…" : "Connecting video…")
                    LoadingLine(width: 120)
                }
            case .stopped:
                message("\(model.current?.name ?? "This device") is stopped.")
                HStack(spacing: 8) {
                    OctetButton(title: "Start Device", icon: "device.power", kind: .primary, compact: true) { model.start() }
                    OctetButton(title: "Choose Another Device", kind: .ghost, compact: true) { model.choosePicker() }
                }
            case .failed(let text):
                message(text)
                HStack(spacing: 8) {
                    if model.current != nil {
                        OctetButton(title: "Try Again", kind: .primary, compact: true) { model.start() }
                    }
                    OctetButton(title: "Choose Another Device", kind: .ghost, compact: true) { model.choosePicker() }
                }
            case .picker, .live:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noVideo: some View {
        VStack(spacing: 10) {
            message("No video received from the device. Reconnect to try again.")
            HStack(spacing: 8) {
                OctetButton(title: "Reconnect", icon: "arrow.clockwise", kind: .primary, compact: true) { model.reconnect() }
                OctetButton(title: "Choose Another Device", kind: .ghost, compact: true) { model.choosePicker() }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Floating

/// The plane while its device is in the floating preview: the plane
/// doesn't stream it a second time.
private struct DeviceFloatingNotice: View {
    @ObservedObject var model: DeviceHubModel
    let openInPanel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            OctetIcon(model.current?.platform == .android ? "device.android"
                      : model.current?.isTablet == true ? "device.ipad" : "device.iphone", size: 28)
                .foregroundStyle(Theme.textTertiary)
            Text("\(model.current?.name ?? "This device") is in a floating window.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                OctetButton(title: "Show Here", kind: .primary, compact: true, action: openInPanel)
                OctetButton(title: "Close Floating Preview", kind: .ghost, compact: true) { DeviceFloat.shared.close() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live

private struct DeviceLiveView: View {
    @ObservedObject var model: DeviceHubModel
    let askAgent: (String) -> Void
    let float: () -> Void
    @AppStorage(DeviceSetup.agentAccessKey) private var agentAccess = false

    var body: some View {
        if let device = model.current {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    screen(device)
                    DeviceControlsRail(model: model, device: device, agentAccess: agentAccess, float: float) {
                        model.sendScreenshot(to: askAgent)
                    }
                    .padding(.trailing, 8)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: .infinity)
                if model.toolsOpen {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    DeviceToolsDrawer(model: model, device: device) {
                        MotionPreferences.shared.perform(.sidebar) { model.toolsOpen = false }
                    }
                    .frame(height: 280)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func screen(_ device: DeviceInfo) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
            DeviceScreenView(frames: model.frames, tablet: device.isTablet, interactive: model.inputAvailable,
                             send: model.send, type: model.type)
                .padding(16)
            VStack(spacing: 6) {
                if model.noVideo {
                    banner("No video received from the device. Reconnect to try again.", button: "Reconnect") {
                        model.reconnect()
                    }
                }
                if device.platform == .ios && model.axeMissing {
                    banner("Simulator input is unavailable. Install AXe for smooth video and touch: brew install cameroncooke/axe/axe",
                           button: "Set Up…") { model.setupShowing = true }
                }
                if agentAccess {
                    Text("Send Screenshot to Agent to ask about what's on screen.")
                        .font(Theme.captionFont)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OctetButton(title: button, compact: true, action: action)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// The controls beside the screen: a vertical pill of icon buttons, after
/// T3 Code's device hub.
private struct DeviceControlsRail: View {
    @ObservedObject var model: DeviceHubModel
    let device: DeviceInfo
    let agentAccess: Bool
    let float: () -> Void
    let sendScreenshot: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            OctetIconButton(icon: "device.home", help: "Home", large: true) { model.send(.button(.home)) }
                .disabled(!model.inputAvailable)
            if device.platform == .android {
                OctetIconButton(icon: "device.back", help: "Back", large: true) { model.send(.button(.back)) }
                OctetIconButton(icon: "device.recents", help: "Recents", large: true) { model.send(.button(.recents)) }
                OctetIconButton(icon: "device.rotate", help: "Rotate", large: true) { model.rotate() }
            }
            divider
            let dark = model.dark ?? false
            OctetIconButton(icon: dark ? "device.sun" : "device.moon",
                            help: dark ? "Switch to Light Mode" : "Switch to Dark Mode", large: true) {
                model.setDark(!dark)
            }
            Menu {
                ForEach(DeviceTextSize.allCases) { size in
                    Button {
                        model.setTextSize(size)
                    } label: {
                        if model.textSize == size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                    }
                }
            } label: {
                OctetIcon("device.textsize", size: 15)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text Size")
            OctetIconButton(icon: "device.tools", help: "Device Tools", active: model.toolsOpen, large: true) {
                MotionPreferences.shared.perform(.sidebar) { model.toolsOpen.toggle() }
            }
            divider
            OctetIconButton(icon: "device.camera", help: "Save Screenshot", large: true) { model.saveScreenshot() }
            OctetIconButton(icon: "device.send", help: agentAccess ? "Send Screenshot to Agent"
                                : "Send Screenshot to Agent (turn on Agent Access in Set Up Devices)", large: true,
                            action: sendScreenshot)
                .disabled(!agentAccess)
            Spacer(minLength: 4)
            Menu {
                if device.platform == .ios {
                    Button("Open in Simulator App") { model.openInSimulatorApp() }
                }
                Button("Float Device Over Terminal", action: float)
                Divider()
                Button("Choose Another Device") { model.choosePicker() }
                Button("Set Up Devices…") { model.setupShowing = true }
                Divider()
                Button("Power Off Device", role: .destructive) { model.powerOff() }
            } label: {
                OctetIcon("ellipsis", size: 15)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(width: 20, height: 1).padding(.vertical, 2)
    }
}
