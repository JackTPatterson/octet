import AppKit
import SwiftUI

// MARK: - Model

/// One Device plane's state: the device list, the device on screen, its
/// video, the input sent to it, and the tools.
@MainActor
final class DeviceHubModel: ObservableObject {
    enum Phase: Equatable {
        /// Choosing a device.
        case picker
        /// The chosen device isn't running.
        case stopped
        /// Booting it.
        case starting
        /// Running, waiting for the first frame.
        case connecting
        case live
        case failed(String)
    }

    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var listing = false
    @Published private(set) var listedOnce = false
    @Published private(set) var androidMissing = false
    @Published private(set) var xcodeMissing = false
    @Published private(set) var axeMissing = false
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var phase: Phase
    @Published private(set) var current: DeviceInfo?
    @Published private(set) var noVideo = false
    @Published private(set) var dark: Bool?
    @Published private(set) var textSize: DeviceTextSize?
    @Published private(set) var rotation = 0
    @Published var toolsOpen = false
    /// The screen in the units input takes: points on iOS, pixels on Android.
    @Published private(set) var screen: CGSize?

    let frames = DeviceFrameStore()
    private(set) var currentId: String?
    private var stream: DeviceVideoStream?
    private var visible = false
    private let inputQueue = DispatchQueue(label: "octet.device.input")
    private var typed = ""
    private var typeFlush: DispatchWorkItem?

    init(deviceId: String?) {
        currentId = deviceId
        phase = deviceId == nil ? .picker : .connecting
    }

    deinit { stream?.stop() }

    var iosDevices: [DeviceInfo] { devices.filter { $0.platform == .ios } }
    var androidDevices: [DeviceInfo] { devices.filter { $0.platform == .android } }

    /// iOS without AXe can show video (polled) but not take input.
    var inputAvailable: Bool { current?.platform == .android || !axeMissing }

    // MARK: Lifecycle

    func appear(visible: Bool) {
        self.visible = visible
        Task { await refresh(opening: true) }
    }

    func disappear() {
        stopStream()
        flushTyping()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            if phase == .connecting || phase == .live { startStream() }
        } else {
            stopStream()
        }
    }

    /// The host changed the plane's device (a restored tab, say).
    func show(id: String?) {
        guard id != currentId else { return }
        stopStream()
        currentId = id
        current = nil
        guard id != nil else { phase = .picker; return }
        resolveCurrent()
    }

    // MARK: Listing

    /// Lists every device. `opening` is the plane's first look, which shows
    /// setup until it's been finished once; the picker finding nothing at
    /// all shows it any time.
    func refresh(opening: Bool = false) async {
        listing = true
        defer { listing = false; listedOnce = true }
        let found = await Self.discover()
        devices = found.devices
        androidMissing = !found.android
        xcodeMissing = !found.xcode
        axeMissing = !found.axe
        if phase != .picker && phase != .starting { resolveCurrent() }
        let done = UserDefaults.standard.bool(forKey: DeviceSetup.doneKey)
        if (opening && DeviceSetup.needed(done: done, deviceCount: devices.count))
            || (phase == .picker && devices.isEmpty) {
            setupShowing = true
        }
    }

    // MARK: Setup

    @Published var setupShowing = false
    @Published private(set) var checking = false
    @Published private(set) var creatingIPhone = false
    @Published private(set) var installingAxe = false

    var iosStatus: DeviceSetup.Status { DeviceSetup.iosStatus(xcode: !xcodeMissing, devices: iosDevices.count) }
    var androidStatus: DeviceSetup.Status { DeviceSetup.androidStatus(sdk: !androidMissing, devices: androidDevices.count) }

    /// Looks for the tools again (they may have just been installed), then
    /// lists devices.
    func checkAgain() async {
        checking = true
        defer { checking = false }
        DeviceToolbox.shared.invalidate()
        await refresh()
    }

    /// Creates "iPhone (Octet)" from the newest iPhone on the newest iOS runtime.
    func createIPhone() {
        guard !creatingIPhone else { return }
        creatingIPhone = true
        Task {
            defer { creatingIPhone = false }
            let runtimes = await DeviceRunner.run(DeviceCommands.listRuntimes, binary: true, timeout: 30)
            guard runtimes.ok, let newest = DeviceHub.newestIPhone(runtimes.data) else {
                ToastCenter.shared.fail(nil, "Couldn't create an iPhone Simulator",
                                        detail: "No iOS runtime is installed. Install one in Xcode Settings → Components.")
                return
            }
            let out = await DeviceRunner.run(DeviceCommands.createIPhone(deviceType: newest.deviceType, runtime: newest.runtime),
                                             timeout: 120)
            if out.ok {
                ToastCenter.shared.info("Created iPhone (Octet)")
            } else {
                ToastCenter.shared.fail(nil, "Couldn't create an iPhone Simulator", detail: DeviceCommands.failureDetail(out.text))
            }
            await refresh()
        }
    }

    /// `brew install cameroncooke/axe/axe` through the login shell, where
    /// Homebrew is on the PATH.
    func installAxe() {
        guard !installingAxe else { return }
        installingAxe = true
        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: LoginShell.run(DeviceCommands.installAxe))
                }
            }
            installingAxe = false
            if result.status == 0 {
                ToastCenter.shared.info("AXe installed")
            } else {
                ToastCenter.shared.fail(nil, "Couldn't install AXe", detail: DeviceCommands.failureDetail(result.output))
            }
            await checkAgain()
        }
    }

    private struct Discovery: Sendable {
        var devices: [DeviceInfo] = []
        var xcode = false, android = false, axe = false
    }

    private nonisolated static func discover() async -> Discovery {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tools = DeviceToolbox.shared
                var result = Discovery(xcode: tools.hasXcode, android: tools.hasAndroid, axe: tools.hasAxe)
                if result.xcode {
                    let out = DeviceRunner.run(DeviceCommands.listSimulators, binary: true, timeout: 30)
                    if out.ok { result.devices += DeviceHub.parseSimctl(out.data) }
                }
                if result.android {
                    result.devices += androidDevices()
                }
                result.devices = DeviceHub.sorted(result.devices)
                continuation.resume(returning: result)
            }
        }
    }

    /// AVDs and running emulators, with each running one's AVD and version.
    private nonisolated static func androidDevices() -> [DeviceInfo] {
        let adb = DeviceHub.parseAdbDevices(DeviceRunner.run(DeviceCommands.listAdbDevices, timeout: 15).text)
        let avds = DeviceToolbox.shared.path("emulator") == nil ? []
            : DeviceHub.parseAvds(DeviceRunner.run(DeviceCommands.listAvds, timeout: 15).text)
        var running: [String: String] = [:], versions: [String: String] = [:]
        for device in adb where device.isEmulator && device.ready {
            if let name = DeviceHub.parseAvdName(DeviceRunner.run(DeviceCommands.avdName(serial: device.serial), timeout: 5).text) {
                running[device.serial] = name
            }
            let version = DeviceRunner.run(DeviceCommands.androidVersion(serial: device.serial), timeout: 5)
            if version.ok, !version.text.isEmpty { versions[device.serial] = "Android \(version.text)" }
        }
        return DeviceHub.androidDevices(avds: avds, adb: adb, running: running, versions: versions)
    }

    /// Finds the plane's device in the list and shows it as it is.
    private func resolveCurrent() {
        guard let id = currentId else { phase = .picker; return }
        guard let device = devices.first(where: { $0.id == id }) else {
            if listedOnce || !devices.isEmpty {
                current = nil
                phase = .failed("This device is no longer on this Mac.")
            }
            return
        }
        let wasRunning = current?.booted == true && current?.serial == device.serial
        current = device
        if !device.booted {
            stopStream()
            // A boot that failed keeps saying why.
            if !phase.isFailure { phase = .stopped }
        } else if !wasRunning || phase == .stopped || phase.isFailure {
            connect()
        }
    }

    // MARK: Opening and power

    /// Picks a device: shows it, starting it first if it's stopped.
    func open(_ device: DeviceInfo, onOpen: (DeviceInfo) -> Void) {
        stopStream()
        currentId = device.id
        current = device
        onOpen(device)
        if device.booted { connect() } else { start() }
    }

    func choosePicker() {
        stopStream()
        phase = .picker
        toolsOpen = false
        Task { await refresh() }
    }

    func start() {
        guard let device = current, !pending.contains(device.id) else { return }
        pending.insert(device.id)
        phase = .starting
        Task {
            let failure = await Self.boot(device)
            pending.remove(device.id)
            guard currentId == device.id else { await refresh(); return }
            if let failure {
                phase = .failed("\(device.name) failed to boot: \(failure)")
                ToastCenter.shared.fail(nil, "\(device.name) failed to boot", detail: failure)
                await refresh()
                return
            }
            phase = .connecting
            await refresh()
        }
    }

    /// Boots and waits until it's usable; the failure's text, or nil.
    private nonisolated static func boot(_ device: DeviceInfo) async -> String? {
        switch device.platform {
        case .ios:
            let boot = await DeviceRunner.run(DeviceCommands.boot(device), timeout: 60)
            // "Unable to boot device in current state: Booted" is fine.
            if !boot.ok && !boot.text.contains("current state: Booted") {
                return DeviceCommands.failureDetail(boot.text)
            }
            let status = await DeviceRunner.run(DeviceCommands.bootStatus(udid: device.id), timeout: 180)
            return status.ok ? nil : DeviceCommands.failureDetail(status.text)
        case .android:
            let before = Set(DeviceHub.parseAdbDevices(await DeviceRunner.run(DeviceCommands.listAdbDevices).text).map(\.serial))
            guard DeviceRunner.launchDetached(DeviceCommands.boot(device)) else {
                return "The Android emulator isn't installed."
            }
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let adb = DeviceHub.parseAdbDevices(await DeviceRunner.run(DeviceCommands.listAdbDevices, timeout: 10).text)
                for candidate in adb where candidate.isEmulator && candidate.ready && !before.contains(candidate.serial) {
                    let name = DeviceHub.parseAvdName(await DeviceRunner.run(DeviceCommands.avdName(serial: candidate.serial), timeout: 5).text)
                    guard name == nil || name == device.id else { continue }
                    let done = await DeviceRunner.run(DeviceCommands.bootCompleted(serial: candidate.serial), timeout: 5)
                    if done.text == "1" { return nil }
                }
            }
            return "It didn't finish starting within 3 minutes."
        }
    }

    func powerOff() {
        guard let device = current, let argv = DeviceCommands.shutdown(device) else { return }
        ConfirmCenter.shared.ask(title: "Power off \(device.name)?",
                                 message: "Apps running on it are closed. You can start it again from the Device plane.",
                                 confirmTitle: "Power Off", destructive: true) { [weak self] _ in
            guard let self else { return }
            self.stopStream()
            Task {
                let out = await DeviceRunner.run(argv, timeout: 60)
                if !out.ok {
                    ToastCenter.shared.fail(nil, "Couldn't power off \(device.name)", detail: DeviceCommands.failureDetail(out.text))
                }
                await self.refresh()
            }
        }
    }

    // MARK: Video

    private func connect() {
        guard let device = current, device.booted else { return }
        noVideo = false
        inputFailureShown = false
        if phase != .live { phase = .connecting }
        screen = nil
        loadDetails(device)
        if visible { startStream() }
    }

    func reconnect() {
        stopStream()
        noVideo = false
        phase = .connecting
        Task { await refresh(); if visible { startStream() } }
    }

    private func startStream() {
        guard stream == nil, let device = current, device.booted else { return }
        let source: DeviceVideoStream.Source
        switch device.platform {
        case .ios: source = axeMissing ? .poll(device, interval: 1) : .mjpeg(udid: device.id)
        case .android: source = .poll(device, interval: 0.3)
        }
        let id = device.id
        let stream = DeviceVideoStream(source, onFrame: { [weak self] image in
            guard let self, self.currentId == id, self.stream != nil else { return }
            self.frames.image = image
            self.noVideo = false
            if self.phase == .connecting { self.phase = .live }
            self.frameArrived(image)
        }, onStall: { [weak self] in
            guard let self, self.currentId == id else { return }
            self.noVideo = true
        })
        self.stream = stream
        stream.start()
    }

    private func stopStream() {
        stream?.stop()
        stream = nil
    }

    /// The screen size for input when describe-ui hasn't given one: Android
    /// frames are the screen in pixels, in its current rotation; an iOS
    /// stream frame is half the pixels, at 3x on phones and 2x on iPads.
    private func frameArrived(_ image: CGImage) {
        guard let device = current else { return }
        let pixels = CGSize(width: image.width, height: image.height)
        switch device.platform {
        case .android:
            if screen != pixels { screen = pixels }
        case .ios:
            guard screen == nil else { return }
            let factor: CGFloat = axeMissing ? 1 : 2
            let scale: CGFloat = device.isTablet ? 2 : 3
            screen = CGSize(width: (pixels.width * factor / scale).rounded(), height: (pixels.height * factor / scale).rounded())
        }
    }

    /// The screen-size command's output. A simulator that has just booted
    /// can't describe its UI for several seconds ("Timed out creating the
    /// simulator remote automation session"), so iOS tries a few times.
    private nonisolated static func readScreen(_ argv: [String]?, ios: Bool) async -> DeviceRunner.Output? {
        guard let argv else { return nil }
        for attempt in 0..<(ios ? 4 : 1) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            let out = await DeviceRunner.run(argv, binary: ios, timeout: 20)
            if out.ok, !ios || DeviceHub.parseScreenPoints(out.data) != nil { return out }
        }
        return nil
    }

    /// Screen size, appearance and text size, read once per connection.
    private func loadDetails(_ device: DeviceInfo) {
        let axe = !axeMissing
        let screenArgv: [String]? = switch device.platform {
        case .ios: axe ? DeviceCommands.describeUI(udid: device.id) : nil
        case .android: device.serial.map { DeviceCommands.wmSize(serial: $0) }
        }
        Task {
            async let screenOutput = Self.readScreen(screenArgv, ios: device.platform == .ios)
            async let appearance = DeviceRunner.runIfPresent(DeviceCommands.appearance(device), timeout: 10)
            async let size = DeviceRunner.runIfPresent(DeviceCommands.textSize(device), timeout: 10)
            let (screenOut, appearanceOut, sizeOut) = await (screenOutput, appearance, size)
            guard currentId == device.id else { return }
            if let screenOut, screenOut.ok {
                // Frames win on Android once they arrive (they follow rotation).
                switch device.platform {
                case .ios: if let points = DeviceHub.parseScreenPoints(screenOut.data) { screen = points }
                case .android: if screen == nil, let pixels = DeviceHub.parseWmSize(screenOut.text) { screen = pixels }
                }
            }
            dark = appearanceOut.flatMap { DeviceCommands.parseDark($0.text) }
            if let sizeOut, sizeOut.ok {
                textSize = device.platform == .ios ? DeviceTextSize(iosCategory: sizeOut.text)
                    : DeviceTextSize.allCases.first { Double($0.androidScale) == Double(sizeOut.text) }
            }
        }
    }

    // MARK: Input

    /// Sends one input, in order with the rest.
    func send(_ input: DeviceInput) {
        if case .text = input {} else { flushTyping() }
        guard let device = current, inputAvailable,
              let argv = DeviceCommands.input(input, device: device, screen: screen ?? .zero) else { return }
        if screen == nil, case .tap = input { return }
        if screen == nil, case .swipe = input { return }
        let name = device.name
        inputQueue.async { [weak self] in
            var out = DeviceRunner.run(argv, timeout: 15)
            // A session still warming up: try again shortly, twice at most.
            for _ in 0..<2 where !out.ok && DeviceCommands.isAutomationWarmup(out.text) {
                Thread.sleep(forTimeInterval: 1)
                out = DeviceRunner.run(argv, timeout: 15)
            }
            guard !out.ok else { return }
            let detail = DeviceCommands.failureDetail(out.text)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.inputFailed(name, detail) } }
        }
    }

    /// Says once per connection that input isn't arriving, with what the
    /// tool printed (AXe's swipes need an automation session some
    /// simulators refuse), rather than on every tap.
    private var inputFailureShown = false

    private func inputFailed(_ name: String, _ detail: String) {
        guard !inputFailureShown else { return }
        inputFailureShown = true
        ToastCenter.shared.fail(nil, "Input isn't reaching \(name)", detail: detail)
    }

    /// Typed characters go out together once typing pauses for 120ms, so
    /// a word is one `axe type` rather than one per letter.
    func type(_ text: String) {
        typed += text
        typeFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushTyping() }
        typeFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func flushTyping() {
        typeFlush?.cancel()
        typeFlush = nil
        guard !typed.isEmpty else { return }
        let text = typed
        typed = ""
        send(.text(text))
    }

    // MARK: Controls

    func setDark(_ dark: Bool) {
        guard let device = current else { return }
        self.dark = dark
        run(DeviceCommands.setAppearance(device, dark: dark), failure: "Couldn't change the appearance")
    }

    func setTextSize(_ size: DeviceTextSize) {
        guard let device = current else { return }
        textSize = size
        run(DeviceCommands.setTextSize(device, size), failure: "Couldn't change the text size")
    }

    func rotate() {
        guard let serial = current?.serial else { return }
        rotation = (rotation + 1) % 4
        let commands = DeviceCommands.rotate(serial: serial, to: rotation)
        inputQueue.async { for argv in commands { _ = DeviceRunner.run(argv, timeout: 10) } }
    }

    func openInSimulatorApp() {
        guard let device = current, device.platform == .ios else { return }
        run(DeviceCommands.openInSimulatorApp(udid: device.id), failure: "Couldn't open Simulator")
    }

    /// Saves a full-resolution screenshot to the Desktop.
    func saveScreenshot() {
        guard let device = current else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let url = desktop.appendingPathComponent(DeviceCommands.screenshotName(device: device.name, date: Date()))
        Task {
            if let failure = await Self.capture(device, to: url) {
                ToastCenter.shared.fail(nil, "Couldn't save the screenshot", detail: failure)
                return
            }
            ToastCenter.shared.info("Screenshot saved", detail: url.lastPathComponent,
                                    action: .init(title: "Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    })
        }
    }

    /// Saves a screenshot to Octet's caches and hands its path to the agent.
    func sendScreenshot(to askAgent: @escaping (String) -> Void) {
        guard let device = current else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = caches.appendingPathComponent("Octet/device-shots", isDirectory: true)
        let url = folder.appendingPathComponent(DeviceCommands.screenshotName(device: device.name, date: Date()))
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let failure = await Self.capture(device, to: url) {
                ToastCenter.shared.fail(nil, "Couldn't take the screenshot", detail: failure)
                return
            }
            askAgent("Here's the current screen of \(device.name): \(url.path)")
        }
    }

    /// Writes a PNG of the screen to `url`; the failure's text, or nil.
    private nonisolated static func capture(_ device: DeviceInfo, to url: URL) async -> String? {
        guard let argv = DeviceCommands.screenshot(device, to: url.path) else { return "The device isn't running." }
        let out = await DeviceRunner.run(argv, binary: device.platform == .android, timeout: 30)
        guard out.ok else { return DeviceCommands.failureDetail(out.text) }
        if device.platform == .android {
            do { try out.data.write(to: url) } catch { return error.localizedDescription }
        }
        return nil
    }

    // MARK: Tools

    /// Runs a tool's command, toasting a failure with what it printed and,
    /// when given, a success. `then` gets the output either way.
    func run(_ argv: [String]?, success: String? = nil, failure: String,
             then: ((DeviceRunner.Output) -> Void)? = nil) {
        guard let argv else {
            ToastCenter.shared.fail(nil, failure, detail: "The device isn't running.")
            return
        }
        Task {
            let out = await DeviceRunner.run(argv, timeout: 60)
            if out.ok {
                if let success { ToastCenter.shared.info(success) }
            } else {
                ToastCenter.shared.fail(nil, failure, detail: DeviceCommands.failureDetail(out.text))
            }
            then?(out)
        }
    }

    func openURL(_ url: String) {
        guard let device = current, !url.isEmpty else { return }
        run(DeviceCommands.openURL(device, url), failure: "Couldn't open \(url)")
    }

    func launch(_ app: String) {
        guard let device = current, !app.isEmpty else { return }
        run(DeviceCommands.launch(device, app), success: "Launched \(app)", failure: "Couldn't launch \(app)")
    }

    func terminate(_ app: String) {
        guard let device = current, !app.isEmpty else { return }
        run(DeviceCommands.terminate(device, app), success: "Terminated \(app)", failure: "Couldn't terminate \(app)")
    }

    /// Android only: the focused app's component, for the App section.
    func foregroundApp(_ done: @escaping (String?) -> Void) {
        guard let serial = current?.serial else { done(nil); return }
        Task {
            let out = await DeviceRunner.run(DeviceCommands.foregroundApp(serial: serial), timeout: 15)
            done(out.ok ? DeviceHub.parseAndroidFocus(out.text) : nil)
        }
    }

    func setIncreaseContrast(_ enabled: Bool) {
        guard let device = current, device.platform == .ios else { return }
        run(DeviceCommands.increaseContrast(udid: device.id, enabled), failure: "Couldn't change Increase Contrast")
    }

    func setLocation(latitude: Double, longitude: Double) {
        guard let device = current else { return }
        run(DeviceCommands.setLocation(device, latitude: latitude, longitude: longitude),
            success: "Location set", failure: "Couldn't set the location")
    }

    func clearLocation() {
        guard let device = current, device.platform == .ios else { return }
        run(DeviceCommands.clearLocation(udid: device.id), success: "Location cleared", failure: "Couldn't clear the location")
    }

    func permission(_ action: DeviceCommands.PermissionAction, service: String, app: String) {
        guard let device = current, !app.isEmpty else { return }
        let done = switch action {
        case .grant: "Granted \(service)"
        case .revoke: "Revoked \(service)"
        case .reset: "Reset permissions"
        }
        run(DeviceCommands.permission(device, action, service: service, app: app), success: done,
            failure: "Couldn't change the permission")
    }

    func push(bundle: String, alert: String) {
        guard let device = current, device.platform == .ios, !bundle.isEmpty else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("octet-push-\(UUID().uuidString).json")
        do { try DeviceCommands.pushPayload(alert: alert).write(to: url) } catch {
            ToastCenter.shared.fail(nil, "Couldn't send the notification", detail: error.localizedDescription)
            return
        }
        run(DeviceCommands.push(udid: device.id, bundle: bundle, payloadPath: url.path),
            success: "Notification sent", failure: "Couldn't send the notification") { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanStatusBar(_ clean: Bool) {
        guard let device = current, device.platform == .ios else { return }
        run(clean ? DeviceCommands.cleanStatusBar(udid: device.id) : DeviceCommands.resetStatusBar(udid: device.id),
            failure: "Couldn't change the status bar")
    }
}

private extension DeviceHubModel.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
