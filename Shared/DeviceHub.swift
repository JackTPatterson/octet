import CoreGraphics
import Foundation

// The Device plane's pure half: finding iOS Simulators and Android
// Emulators, reading their video, mapping a click in the plane onto the
// device's screen, and the exact command line for every action. Nothing
// here runs a process, so all of it is unit-tested.

// MARK: - Devices

/// A simulator or emulator the Device plane can show.
struct DeviceInfo: Identifiable, Equatable, Hashable {
    enum Platform: String, Codable { case ios, android }

    /// A simulator's UDID, or an emulator's AVD name (its serial when it
    /// has no AVD, e.g. a device that was started some other way).
    let id: String
    var name: String
    var platform: Platform
    /// "iOS 26.0", "Android 15", or empty when unknown.
    var version: String
    var booted: Bool
    /// Android: the adb serial while it's running ("emulator-5554").
    var serial: String?
    /// iOS: the device type, e.g. "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11".
    var deviceType: String?

    var isTablet: Bool { (deviceType ?? name).localizedCaseInsensitiveContains("iPad") }

    /// The row's detail line: "iOS 26.0 · Running".
    var statusLine: String {
        let state = booted ? "Running" : "Stopped"
        return version.isEmpty ? state : "\(version) · \(state)"
    }
}

enum DeviceHub {
    // MARK: - iOS discovery

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0". Only
    /// iOS runtimes (iPads run them too); watchOS, tvOS and visionOS are
    /// left out, so nil.
    static func runtimeName(_ identifier: String) -> String? {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return nil }
        let rest = identifier.dropFirst(prefix.count)
        guard rest.hasPrefix("iOS-") else { return nil }
        let version = rest.dropFirst("iOS-".count).split(separator: "-").joined(separator: ".")
        return version.isEmpty ? nil : "iOS \(version)"
    }

    /// `xcrun simctl list devices available -j`: devices keyed by runtime.
    static func parseSimctl(_ data: Data) -> [DeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: Any] else { return [] }
        var devices: [DeviceInfo] = []
        for (runtime, list) in runtimes {
            guard let version = runtimeName(runtime), let entries = list as? [[String: Any]] else { continue }
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                if let available = entry["isAvailable"] as? Bool, !available { continue }
                devices.append(DeviceInfo(id: udid, name: name, platform: .ios, version: version,
                                          booted: (entry["state"] as? String) == "Booted",
                                          deviceType: entry["deviceTypeIdentifier"] as? String))
            }
        }
        return sorted(devices)
    }

    /// Running devices first, then by name, then newest runtime first so
    /// two "iPhone 17 Pro"s read in a stable order.
    static func sorted(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.sorted { a, b in
            if a.booted != b.booted { return a.booted }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            if a.version != b.version { return a.version.localizedStandardCompare(b.version) == .orderedDescending }
            return a.id < b.id
        }
    }

    /// The root element's frame in `axe describe-ui` output: the screen's
    /// size in points, which is what AXe's taps take.
    static func parseScreenPoints(_ data: Data) -> CGSize? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let frame = root.first?["frame"] as? [String: Any],
              let width = (frame["width"] as? NSNumber)?.doubleValue,
              let height = (frame["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The newest iOS runtime and the newest iPhone it runs, from `xcrun
    /// simctl list runtimes available -j`, for setup's "Create iPhone
    /// Simulator". simctl lists device types newest first.
    static func newestIPhone(_ data: Data) -> (deviceType: String, runtime: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else { return nil }
        let candidates = runtimes.compactMap { runtime -> (version: String, id: String, type: String)? in
            guard (runtime["platform"] as? String) == "iOS", (runtime["isAvailable"] as? Bool) != false,
                  let id = runtime["identifier"] as? String, let version = runtime["version"] as? String,
                  let types = runtime["supportedDeviceTypes"] as? [[String: Any]],
                  let phone = types.first(where: { ($0["productFamily"] as? String) == "iPhone" }),
                  let type = phone["identifier"] as? String else { return nil }
            return (version, id, type)
        }
        guard let newest = candidates.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending })
        else { return nil }
        return (newest.type, newest.id)
    }

    // MARK: - Android discovery

    /// Where the Android SDK is: ANDROID_HOME, then ANDROID_SDK_ROOT, then
    /// Android Studio's default. nil when none of them has adb.
    static func androidSDKRoot(environment: [String: String], home: String,
                               exists: (String) -> Bool) -> String? {
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                          (home as NSString).appendingPathComponent("Library/Android/sdk")]
        for case let root? in candidates where !root.isEmpty {
            if exists((root as NSString).appendingPathComponent("platform-tools/adb")) { return root }
        }
        return nil
    }

    /// One line of `adb devices -l`.
    struct AdbDevice: Equatable {
        let serial: String
        /// "device" when ready; "offline", "unauthorized", … otherwise.
        let state: String
        var model: String?

        var isEmulator: Bool { serial.hasPrefix("emulator-") }
        var ready: Bool { state == "device" }
    }

    /// `adb devices -l`: "emulator-5554  device product:sdk_gphone64 model:sdk_gphone64_arm64 …".
    static func parseAdbDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            return AdbDevice(serial: fields[0], state: fields[1], model: model)
        }
    }

    /// `emulator -list-avds`: one name per line, among the occasional
    /// "INFO |" or warning line the emulator prints first.
    static func parseAvds(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && !$0.contains(" ") && !$0.contains("|") && !$0.hasPrefix("WARNING") && !$0.hasPrefix("ERROR")
        }
    }

    /// `adb -s S emu avd name`: "Pixel_8\r\nOK".
    static func parseAvdName(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" && !$0.hasPrefix("KO") }
        return line
    }

    /// An AVD's name as people read it: "Pixel_8_API_35" → "Pixel 8 API 35".
    static func avdDisplayName(_ avd: String) -> String { avd.replacingOccurrences(of: "_", with: " ") }

    /// The Android rows: every AVD, running or not, and any running
    /// emulator that isn't one of them. `running` maps serial → AVD name.
    static func androidDevices(avds: [String], adb: [AdbDevice], running: [String: String],
                               versions: [String: String] = [:]) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        var claimed = Set<String>()
        for avd in avds {
            let serial = running.first { $0.value == avd }?.key
            let ready = serial.flatMap { s in adb.first { $0.serial == s } }?.ready ?? false
            if let serial { claimed.insert(serial) }
            result.append(DeviceInfo(id: avd, name: avdDisplayName(avd), platform: .android,
                                     version: serial.flatMap { versions[$0] } ?? "", booted: ready && serial != nil,
                                     serial: serial))
        }
        for device in adb where device.isEmulator && device.ready && !claimed.contains(device.serial) {
            let name = running[device.serial].map(avdDisplayName) ?? device.model?.replacingOccurrences(of: "_", with: " ") ?? device.serial
            result.append(DeviceInfo(id: running[device.serial] ?? device.serial, name: name, platform: .android,
                                     version: versions[device.serial] ?? "", booted: true, serial: device.serial))
        }
        return sorted(result)
    }

    /// `adb shell wm size`: "Physical size: 1080x2400", and an "Override
    /// size:" line after it when the display was resized, which wins.
    static func parseWmSize(_ output: String) -> CGSize? {
        var size: CGSize?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let parts = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).split(separator: "x")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { continue }
            if line.contains("Override") || size == nil { size = CGSize(width: w, height: h) }
        }
        return size
    }

    /// The focused window's component from `dumpsys window`:
    /// "mCurrentFocus=Window{1a2b u0 com.android.chrome/org.chromium.Main}".
    static func parseAndroidFocus(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("mCurrentFocus=") }),
              let open = line.lastIndex(of: " ") else { return nil }
        let value = line[line.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "} "))
        return value.isEmpty || value == "null" ? nil : value
    }

    // MARK: - Geometry

    /// The largest rect at `content`'s aspect that fits `container`, centered.
    static func fit(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Where a point in the view falls on the screen, from 0 to 1 on each
    /// axis (top-left origin), with the screen letterboxed into the view.
    /// nil in the bars around it.
    static func normalized(_ point: CGPoint, in viewSize: CGSize, screen: CGSize) -> CGPoint? {
        let rect = fit(screen, in: viewSize)
        guard rect.width > 0, (rect.minX...rect.maxX).contains(point.x), (rect.minY...rect.maxY).contains(point.y)
        else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    /// A normalized point in the device's own units: points on iOS (what
    /// AXe takes), pixels on Android (what `input tap` takes), rounded.
    static func devicePoint(_ normalized: CGPoint, screen: CGSize) -> (x: Int, y: Int) {
        let x = Int((min(1, max(0, normalized.x)) * screen.width).rounded())
        let y = Int((min(1, max(0, normalized.y)) * screen.height).rounded())
        return (min(x, max(0, Int(screen.width) - 1)), min(y, max(0, Int(screen.height) - 1)))
    }

    /// A scroll as a swipe: the finger moves the way the content should,
    /// from `origin`, by the scroll's distance as a fraction of the screen
    /// (at most 40% so one flick can't fling a whole list). Deltas are
    /// macOS's, where a positive y moves content down.
    static func scrollSwipe(delta: CGSize, from origin: CGPoint, viewSize: CGSize) -> (from: CGPoint, to: CGPoint)? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let dx = max(-0.4, min(0.4, delta.width / viewSize.width))
        let dy = max(-0.4, min(0.4, delta.height / viewSize.height))
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return nil }
        let to = CGPoint(x: min(0.98, max(0.02, origin.x + dx)), y: min(0.98, max(0.02, origin.y + dy)))
        return (origin, to)
    }

    /// Screen corners: phones round about 14% of their short side, iPads
    /// and tablets less.
    static func cornerRadius(for size: CGSize, tablet: Bool) -> CGFloat {
        min(size.width, size.height) * (tablet ? 0.045 : 0.14)
    }
}

// MARK: - Floating preview

/// The floating device window's geometry, after T3 Code's mini-player: a
/// card about 300pt wide at the device's aspect, the screen inset by a
/// thin margin that drags the window.
enum DeviceFloatGeometry {
    static let width: CGFloat = 300
    static let minWidth: CGFloat = 160
    /// The draggable margin around the screen.
    static let inset: CGFloat = 6
    static let cornerRadius: CGFloat = 16
    /// Gap kept from the screen's edges when placing it.
    static let margin: CGFloat = 20
    /// A phone held upright, for before the first frame says otherwise.
    static let fallbackScreen = CGSize(width: 9, height: 19.5)

    /// The card at `width` for a screen of `screen`'s aspect, margin
    /// included.
    static func size(screen: CGSize, width: CGFloat) -> CGSize {
        let screen = screen.width > 0 && screen.height > 0 ? screen : fallbackScreen
        let width = max(minWidth, width)
        let inner = width - 2 * inset
        return CGSize(width: width, height: (inner * screen.height / screen.width + 2 * inset).rounded())
    }

    /// What a live resize from `current` toward `proposed` becomes with
    /// the aspect kept: the edge that moved more leads, so dragging only
    /// the bottom edge still resizes.
    static func resize(from current: CGSize, to proposed: CGSize, screen: CGSize) -> CGSize {
        let screen = screen.width > 0 && screen.height > 0 ? screen : fallbackScreen
        let byWidth = size(screen: screen, width: proposed.width)
        guard abs(proposed.height - current.height) > abs(proposed.width - current.width) else { return byWidth }
        let inner = max(0, proposed.height - 2 * inset)
        return size(screen: screen, width: (inner * screen.width / screen.height + 2 * inset).rounded())
    }

    /// Where the window opens: the saved frame's width and top-left when it
    /// still lands on `visible` (the screen's usable area), else 300pt wide
    /// in the bottom-right corner. Always at the screen's aspect and inside
    /// `visible`, shrinking to fit a short screen.
    static func frame(saved: CGRect?, screen: CGSize, visible: CGRect) -> CGRect {
        let usable = saved.map { $0.width > 0 && $0.height > 0 && $0.intersects(visible) } ?? false
        var size = size(screen: screen, width: usable ? saved!.width : width)
        let room = CGSize(width: max(minWidth, visible.width - 2 * margin), height: max(1, visible.height - 2 * margin))
        if size.height > room.height || size.width > room.width {
            let screen = screen.width > 0 && screen.height > 0 ? screen : fallbackScreen
            let byHeight = ((room.height - 2 * inset) * screen.width / screen.height + 2 * inset).rounded(.down)
            size = self.size(screen: screen, width: min(room.width, byHeight))
        }
        var origin: CGPoint
        if usable, let saved {
            // AppKit's origin is bottom-left; the top edge stays put.
            origin = CGPoint(x: saved.minX, y: saved.maxY - size.height)
        } else {
            origin = CGPoint(x: visible.maxX - margin - size.width, y: visible.minY + margin)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// The card's corners: Android's screen has square corners, so the card
    /// rounds like a phone (14% of the short side) where that's more.
    static func cornerRadius(size: CGSize, platform: DeviceInfo.Platform) -> CGFloat {
        switch platform {
        case .ios: cornerRadius
        case .android: max(cornerRadius, min(size.width, size.height) * 0.14)
        }
    }
}

// MARK: - MJPEG

/// Reads `axe stream-video --format mjpeg` as it arrives: an HTTP response
/// header, then parts of `--mjpegstream` / `Content-Type: image/jpeg` /
/// `Content-Length: N`, a blank line, and N bytes of JPEG. Chunks can end
/// anywhere, so what's incomplete waits for the next one.
struct MJPEGParser {
    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)
    /// A runaway stream (no headers for this long) is dropped rather than
    /// kept growing.
    static let maxBuffer = 64 << 20

    /// Feeds bytes in; returns every whole JPEG they finished.
    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let end = buffer.range(of: Self.separator) {
            let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(header) else {
                // The HTTP response header, or a boundary with no length.
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                continue
            }
            let bodyStart = end.upperBound
            guard buffer.endIndex - bodyStart >= length else { break }
            frames.append(Data(buffer[bodyStart..<bodyStart + length]))
            buffer.removeSubrange(buffer.startIndex..<bodyStart + length)
        }
        if buffer.count > Self.maxBuffer { buffer.removeAll() }
        // Rebase so indices start at zero again; Data slices keep theirs.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        return frames
    }

    static func contentLength(_ header: String) -> Int? {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

// MARK: - Input

/// What the plane asks a device to do with its screen.
enum DeviceInput: Equatable {
    case tap(CGPoint)
    case swipe(from: CGPoint, to: CGPoint, duration: TimeInterval)
    case text(String)
    case key(DeviceKey)
    case button(DeviceButton)
}

enum DeviceKey: Equatable {
    case enter, delete, tab, escape, up, down, left, right

    /// USB HID usage, which `axe key` takes.
    var hid: Int {
        switch self {
        case .enter: 40
        case .escape: 41
        case .delete: 42
        case .tab: 43
        case .right: 79
        case .left: 80
        case .down: 81
        case .up: 82
        }
    }

    /// Android KEYCODE_*, which `input keyevent` takes.
    var android: Int {
        switch self {
        case .enter: 66
        case .delete: 67
        case .tab: 61
        case .escape: 111
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        }
    }
}

enum DeviceButton: Equatable {
    case home, lock, back, recents, power
}

/// The four text sizes the plane offers, after T3 Code's.
enum DeviceTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// `simctl ui … content_size` categories.
    var iosCategory: String {
        switch self {
        case .small: "small"
        case .standard: "large"
        case .large: "extra-extra-large"
        case .extraLarge: "accessibility-large"
        }
    }

    var androidScale: String {
        switch self {
        case .small: "0.85"
        case .standard: "1.0"
        case .large: "1.15"
        case .extraLarge: "1.3"
        }
    }

    init?(iosCategory: String) {
        guard let match = Self.allCases.first(where: { $0.iosCategory == iosCategory }) else { return nil }
        self = match
    }
}

/// A preset place for the Location tool.
struct DeviceLocationPreset: Identifiable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name }

    static let all: [DeviceLocationPreset] = [
        .init(name: "San Francisco", latitude: 37.7749, longitude: -122.4194),
        .init(name: "New York", latitude: 40.7128, longitude: -74.0060),
        .init(name: "London", latitude: 51.5074, longitude: -0.1278),
        .init(name: "Stockholm", latitude: 59.3293, longitude: 18.0686),
        .init(name: "Tokyo", latitude: 35.6762, longitude: 139.6503),
    ]
}

// MARK: - Commands

/// Every command line the Device plane runs, as argv. The first element is
/// the tool by name ("xcrun", "axe", "adb", "emulator", "open"); the runner
/// swaps in its absolute path. Kept pure so tests can read them.
enum DeviceCommands {
    // MARK: Discovery and power

    static let listSimulators = ["xcrun", "simctl", "list", "devices", "available", "-j"]
    static let listAdbDevices = ["adb", "devices", "-l"]
    static let listAvds = ["emulator", "-list-avds"]

    static let listRuntimes = ["xcrun", "simctl", "list", "runtimes", "available", "-j"]
    static let installAxe = ["brew", "install", "cameroncooke/axe/axe"]

    static func createIPhone(deviceType: String, runtime: String) -> [String] {
        ["xcrun", "simctl", "create", "iPhone (Octet)", deviceType, runtime]
    }

    static func adb(_ serial: String, _ rest: [String]) -> [String] { ["adb", "-s", serial] + rest }
    static func avdName(serial: String) -> [String] { adb(serial, ["emu", "avd", "name"]) }
    static func androidVersion(serial: String) -> [String] { adb(serial, ["shell", "getprop", "ro.build.version.release"]) }
    static func bootCompleted(serial: String) -> [String] { adb(serial, ["shell", "getprop", "sys.boot_completed"]) }

    static func boot(_ device: DeviceInfo) -> [String] {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "boot", device.id]
        case .android: ["emulator", "-avd", device.id, "-no-snapshot-save"]
        }
    }

    /// Waits for an iOS boot to finish (`-b` boots it first if needed).
    static func bootStatus(udid: String) -> [String] { ["xcrun", "simctl", "bootstatus", udid, "-b"] }

    static func shutdown(_ device: DeviceInfo) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "shutdown", device.id]
        case .android: device.serial.map { adb($0, ["emu", "kill"]) }
        }
    }

    static func describeUI(udid: String) -> [String] { ["axe", "describe-ui", "--udid", udid] }
    static func wmSize(serial: String) -> [String] { adb(serial, ["shell", "wm", "size"]) }

    // MARK: Video

    static func stream(udid: String, fps: Int = 15, quality: Int = 70, scale: Double = 0.5) -> [String] {
        ["axe", "stream-video", "--udid", udid, "--format", "mjpeg", "--fps", String(fps),
         "--quality", String(quality), "--scale", String(scale)]
    }

    /// One frame, for polling when AXe isn't installed (iOS) or always
    /// (Android, whose PNG comes on stdout).
    static func frame(_ device: DeviceInfo, to path: String) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "io", device.id, "screenshot", "--type=jpeg", path]
        case .android: device.serial.map { adb($0, ["exec-out", "screencap", "-p"]) }
        }
    }

    /// A full-resolution PNG: written to `path` on iOS; on stdout on Android.
    static func screenshot(_ device: DeviceInfo, to path: String) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "io", device.id, "screenshot", "--type=png", path]
        case .android: device.serial.map { adb($0, ["exec-out", "screencap", "-p"]) }
        }
    }

    // MARK: Input

    /// The command for one input, given the screen in device units
    /// (points on iOS, pixels on Android). nil when the device can't take it
    /// (an Android button on iOS, a stopped emulator).
    static func input(_ input: DeviceInput, device: DeviceInfo, screen: CGSize) -> [String]? {
        switch device.platform {
        case .ios: iosInput(input, udid: device.id, screen: screen)
        case .android: device.serial.flatMap { androidInput(input, serial: $0, screen: screen) }
        }
    }

    static func iosInput(_ input: DeviceInput, udid: String, screen: CGSize) -> [String]? {
        switch input {
        case .tap(let point):
            let p = DeviceHub.devicePoint(point, screen: screen)
            return ["axe", "tap", "-x", String(p.x), "-y", String(p.y), "--udid", udid]
        case .swipe(let from, let to, let duration):
            let a = DeviceHub.devicePoint(from, screen: screen), b = DeviceHub.devicePoint(to, screen: screen)
            return ["axe", "swipe", "--start-x", String(a.x), "--start-y", String(a.y),
                    "--end-x", String(b.x), "--end-y", String(b.y),
                    "--duration", String(format: "%.2f", max(0.05, duration)), "--udid", udid]
        case .text(let text):
            return text.isEmpty ? nil : ["axe", "type", text, "--udid", udid]
        case .key(let key):
            return ["axe", "key", String(key.hid), "--udid", udid]
        case .button(.home): return ["axe", "button", "home", "--udid", udid]
        case .button(.lock), .button(.power): return ["axe", "button", "lock", "--udid", udid]
        case .button(.back), .button(.recents): return nil
        }
    }

    static func androidInput(_ input: DeviceInput, serial: String, screen: CGSize) -> [String]? {
        switch input {
        case .tap(let point):
            let p = DeviceHub.devicePoint(point, screen: screen)
            return adb(serial, ["shell", "input", "tap", String(p.x), String(p.y)])
        case .swipe(let from, let to, let duration):
            let a = DeviceHub.devicePoint(from, screen: screen), b = DeviceHub.devicePoint(to, screen: screen)
            return adb(serial, ["shell", "input", "swipe", String(a.x), String(a.y), String(b.x), String(b.y),
                                String(Int((max(0.05, duration) * 1000).rounded()))])
        case .text(let text):
            return text.isEmpty ? nil : adb(serial, ["shell", "input", "text", androidText(text)])
        case .key(let key):
            return adb(serial, ["shell", "input", "keyevent", String(key.android)])
        case .button(let button):
            let code = switch button {
            case .home: 3
            case .back: 4
            case .recents: 187
            case .power, .lock: 26
            }
            return adb(serial, ["shell", "input", "keyevent", String(code)])
        }
    }

    /// `input text` runs through the device's shell, which splits on
    /// spaces and reads quotes and metacharacters; spaces become `%s` and
    /// the rest are backslash-escaped.
    static func androidText(_ text: String) -> String {
        let special = Set("\\'\"`$&|;<>()*?~#!{}[]%^")
        var result = ""
        for character in text {
            if character == " " { result += "%s" }
            else if special.contains(character) { result += "\\" + String(character) }
            else { result.append(character) }
        }
        return result
    }

    // MARK: Appearance

    static func appearance(_ device: DeviceInfo) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "ui", device.id, "appearance"]
        case .android: device.serial.map { adb($0, ["shell", "cmd", "uimode", "night"]) }
        }
    }

    static func setAppearance(_ device: DeviceInfo, dark: Bool) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "ui", device.id, "appearance", dark ? "dark" : "light"]
        case .android: device.serial.map { adb($0, ["shell", "cmd", "uimode", "night", dark ? "yes" : "no"]) }
        }
    }

    /// "dark"/"light" from simctl, or "Night mode: yes" from Android.
    static func parseDark(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("dark") || text.contains("night mode: yes") { return true }
        if text.contains("light") || text.contains("night mode: no") { return false }
        return nil
    }

    static func textSize(_ device: DeviceInfo) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "ui", device.id, "content_size"]
        case .android: device.serial.map { adb($0, ["shell", "settings", "get", "system", "font_scale"]) }
        }
    }

    static func setTextSize(_ device: DeviceInfo, _ size: DeviceTextSize) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "ui", device.id, "content_size", size.iosCategory]
        case .android: device.serial.map { adb($0, ["shell", "settings", "put", "system", "font_scale", size.androidScale]) }
        }
    }

    static func increaseContrast(udid: String, _ enabled: Bool) -> [String] {
        ["xcrun", "simctl", "ui", udid, "increase_contrast", enabled ? "enabled" : "disabled"]
    }

    /// Android rotation: turn the accelerometer off, then fix the rotation
    /// (0–3, quarter turns).
    static func rotate(serial: String, to rotation: Int) -> [[String]] {
        [adb(serial, ["shell", "settings", "put", "system", "accelerometer_rotation", "0"]),
         adb(serial, ["shell", "settings", "put", "system", "user_rotation", String(((rotation % 4) + 4) % 4)])]
    }

    // MARK: Apps

    static func openURL(_ device: DeviceInfo, _ url: String) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "openurl", device.id, url]
        case .android: device.serial.map { adb($0, ["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", shellQuoted(url)]) }
        }
    }

    /// One argument for the device's shell, which adb joins its arguments into.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launch(_ device: DeviceInfo, _ app: String) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "launch", device.id, app]
        case .android: device.serial.map { adb($0, ["shell", "monkey", "-p", app, "-c", "android.intent.category.LAUNCHER", "1"]) }
        }
    }

    static func terminate(_ device: DeviceInfo, _ app: String) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "terminate", device.id, app]
        case .android: device.serial.map { adb($0, ["shell", "am", "force-stop", app]) }
        }
    }

    static func foregroundApp(serial: String) -> [String] { adb(serial, ["shell", "dumpsys", "window"]) }

    // MARK: Location

    static func setLocation(_ device: DeviceInfo, latitude: Double, longitude: Double) -> [String]? {
        switch device.platform {
        case .ios: ["xcrun", "simctl", "location", device.id, "set", "\(latitude),\(longitude)"]
        // geo fix takes longitude first.
        case .android: device.serial.map { adb($0, ["emu", "geo", "fix", String(longitude), String(latitude)]) }
        }
    }

    static func clearLocation(udid: String) -> [String] { ["xcrun", "simctl", "location", udid, "clear"] }

    /// "37.7749, -122.4194" or two fields; nil unless both are in range.
    static func parseCoordinate(latitude: String, longitude: String) -> (Double, Double)? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    // MARK: Permissions

    static let iosPermissions = ["all", "calendar", "contacts", "location", "location-always", "photos", "photos-add",
                                 "media-library", "microphone", "motion", "reminders", "siri"]
    static let androidPermissions = ["CAMERA", "ACCESS_FINE_LOCATION", "POST_NOTIFICATIONS", "READ_CONTACTS", "RECORD_AUDIO"]

    enum PermissionAction: String { case grant, revoke, reset }

    static func permission(_ device: DeviceInfo, _ action: PermissionAction, service: String, app: String) -> [String]? {
        switch device.platform {
        case .ios:
            return ["xcrun", "simctl", "privacy", device.id, action.rawValue, service, app]
        case .android:
            guard let serial = device.serial else { return nil }
            let permission = service.contains(".") ? service : "android.permission.\(service)"
            switch action {
            case .grant, .revoke: return adb(serial, ["shell", "pm", action.rawValue, app, permission])
            case .reset: return adb(serial, ["shell", "pm", "reset-permissions", "-p", app])
            }
        }
    }

    // MARK: Push and status bar (iOS)

    static func push(udid: String, bundle: String, payloadPath: String) -> [String] {
        ["xcrun", "simctl", "push", udid, bundle, payloadPath]
    }

    /// `{"aps":{"alert":"…"}}`, escaped by JSONSerialization.
    static func pushPayload(alert: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["aps": ["alert": alert]], options: [.sortedKeys])) ?? Data()
    }

    static func cleanStatusBar(udid: String) -> [String] {
        ["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
         "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"]
    }

    static func resetStatusBar(udid: String) -> [String] { ["xcrun", "simctl", "status_bar", udid, "clear"] }

    // MARK: Elsewhere

    static func openInSimulatorApp(udid: String) -> [String] {
        ["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
    }

    /// "iPhone 17 Pro-20261016-094100.png": a name Finder sorts by time.
    static func screenshotName(device: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe)-\(formatter.string(from: date)).png"
    }

    /// Trims a failed command's output to what fits in a toast.
    /// AXe on iOS 27 times out creating its automation session the first
    /// time a gesture needs one after boot or an app launch; the next try
    /// finds it ready. Worth a retry, not an error.
    static func isAutomationWarmup(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("remote automation session")
    }

    static func failureDetail(_ output: String, limit: Int = 240) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "The command failed with no output." }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

// MARK: - Setup

/// The "Set up devices" checklist, after T3 Code's: whether each platform
/// can run here, and when the setup sheet should show itself.
enum DeviceSetup {
    static let doneKey = "octet.devices.setupDone"
    static let agentAccessKey = "octet.devices.agentAccess"

    enum Status: Equatable {
        case ready, noDevices, missing

        var title: String {
            switch self {
            case .ready: "Ready"
            case .noDevices: "No devices"
            case .missing: "Missing"
            }
        }
    }

    enum Step: Int, CaseIterable {
        case simulators, touch, agent

        var title: String {
            switch self {
            case .simulators: "Simulators"
            case .touch: "Touch & Keys"
            case .agent: "Agent Access"
            }
        }

        var heading: String {
            switch self {
            case .simulators: "Check simulator support"
            case .touch: "Smooth video and touch"
            case .agent: "Allow agent control"
            }
        }
    }

    static func iosStatus(xcode: Bool, devices: Int) -> Status {
        !xcode ? .missing : devices == 0 ? .noDevices : .ready
    }

    static func androidStatus(sdk: Bool, devices: Int) -> Status {
        !sdk ? .missing : devices == 0 ? .noDevices : .ready
    }

    static func iosMessage(_ status: Status) -> String {
        switch status {
        case .ready: "Xcode and iOS Simulator are available."
        case .noDevices: "Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components."
        case .missing: "iOS Simulators need Xcode."
        }
    }

    static func androidMessage(_ status: Status) -> String {
        switch status {
        case .ready: "The Android SDK and Emulator are available."
        case .noDevices: "The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager."
        case .missing: "Android SDK was not found. Install it with Android Studio or set ANDROID_HOME to your SDK directory."
        }
    }

    /// Shows until it's finished once, and again whenever a look finds no
    /// simulator or emulator at all.
    static func needed(done: Bool, deviceCount: Int) -> Bool { !done || deviceCount == 0 }
}
