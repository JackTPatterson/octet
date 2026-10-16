import XCTest

final class DeviceHubTests: XCTestCase {
    // MARK: - Discovery

    func testRuntimeNamesKeepOnlyIOS() {
        XCTAssertEqual(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-0"), "iOS 26.0")
        XCTAssertEqual(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-17-5"), "iOS 17.5")
        XCTAssertEqual(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-18"), "iOS 18")
        XCTAssertNil(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"))
        XCTAssertNil(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.tvOS-18-0"))
        XCTAssertNil(DeviceHub.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"))
        XCTAssertNil(DeviceHub.runtimeName("garbage"))
    }

    func testParsesSimctlBootedFirstThenByName() {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[
            {"udid":"B","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
            {"udid":"C","name":"iPad Air","state":"Booted","isAvailable":true,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3"},
            {"udid":"D","name":"Broken","state":"Shutdown","isAvailable":false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[
            {"udid":"W","name":"Apple Watch","state":"Booted","isAvailable":true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"A","name":"Alpha","state":"Shutdown","isAvailable":true}
          ]
        }}
        """
        let devices = DeviceHub.parseSimctl(Data(json.utf8))
        XCTAssertEqual(devices.map(\.id), ["C", "A", "B"])
        XCTAssertEqual(devices[0].version, "iOS 26.2")
        XCTAssertTrue(devices[0].booted)
        XCTAssertTrue(devices[0].isTablet)
        XCTAssertFalse(devices[2].isTablet)
        XCTAssertEqual(devices[0].statusLine, "iOS 26.2 · Running")
        XCTAssertEqual(devices[1].statusLine, "iOS 27.0 · Stopped")
        XCTAssertEqual(DeviceHub.parseSimctl(Data("not json".utf8)), [])
    }

    func testReadsScreenPointsFromDescribeUI() {
        let json = #"[{"frame":{"height":874,"x":0,"width":402,"y":0},"children":[]}]"#
        XCTAssertEqual(DeviceHub.parseScreenPoints(Data(json.utf8)), CGSize(width: 402, height: 874))
        XCTAssertNil(DeviceHub.parseScreenPoints(Data("[]".utf8)))
    }

    func testFindsTheAndroidSDK() {
        let home = "/Users/me"
        let studio = "/Users/me/Library/Android/sdk/platform-tools/adb"
        XCTAssertEqual(DeviceHub.androidSDKRoot(environment: [:], home: home) { $0 == studio },
                       "/Users/me/Library/Android/sdk")
        XCTAssertEqual(DeviceHub.androidSDKRoot(environment: ["ANDROID_HOME": "/sdk"], home: home) {
            $0 == "/sdk/platform-tools/adb" || $0 == studio
        }, "/sdk")
        XCTAssertEqual(DeviceHub.androidSDKRoot(environment: ["ANDROID_HOME": "/missing", "ANDROID_SDK_ROOT": "/root"],
                                                home: home) { $0 == "/root/platform-tools/adb" }, "/root")
        XCTAssertNil(DeviceHub.androidSDKRoot(environment: [:], home: home) { _ in false })
    }

    func testParsesAdbDevicesAndAvds() {
        let adb = """
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        emulator-5556          offline transport_id:2
        R5CT1234               device usb:1-1 product:x model:SM_S918B transport_id:3

        """
        let devices = DeviceHub.parseAdbDevices(adb)
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "emulator-5556", "R5CT1234"])
        XCTAssertEqual(devices[0].model, "sdk_gphone64_arm64")
        XCTAssertTrue(devices[0].isEmulator && devices[0].ready)
        XCTAssertFalse(devices[1].ready)
        XCTAssertFalse(devices[2].isEmulator)

        XCTAssertEqual(DeviceHub.parseAvds("INFO    | Storing crashdata in: /tmp\nPixel_8_API_35\nTablet\n\n"),
                       ["Pixel_8_API_35", "Tablet"])
        XCTAssertEqual(DeviceHub.parseAvdName("Pixel_8_API_35\r\nOK\r\n"), "Pixel_8_API_35")
        XCTAssertNil(DeviceHub.parseAvdName("OK"))
    }

    func testMergesAvdsWithRunningEmulators() {
        let adb = [DeviceHub.AdbDevice(serial: "emulator-5554", state: "device", model: "sdk_gphone64"),
                   DeviceHub.AdbDevice(serial: "emulator-5556", state: "device", model: "Other_Phone")]
        let devices = DeviceHub.androidDevices(avds: ["Pixel_8", "Tablet"], adb: adb,
                                               running: ["emulator-5554": "Pixel_8"],
                                               versions: ["emulator-5554": "15"])
        // Both running ones first, by name; then the stopped AVD.
        XCTAssertEqual(devices.map(\.id), ["emulator-5556", "Pixel_8", "Tablet"])
        XCTAssertEqual(devices[1].name, "Pixel 8")
        XCTAssertEqual(devices[1].serial, "emulator-5554")
        XCTAssertEqual(devices[1].version, "15")
        XCTAssertTrue(devices[1].booted)
        XCTAssertEqual(devices[0].name, "Other Phone")
        XCTAssertFalse(devices[2].booted)
        XCTAssertNil(devices[2].serial)
    }

    func testParsesAndroidScreenAndFocus() {
        XCTAssertEqual(DeviceHub.parseWmSize("Physical size: 1080x2400"), CGSize(width: 1080, height: 2400))
        XCTAssertEqual(DeviceHub.parseWmSize("Physical size: 1080x2400\nOverride size: 720x1600"),
                       CGSize(width: 720, height: 1600))
        XCTAssertNil(DeviceHub.parseWmSize("error: no devices"))
        let dump = "  mCurrentFocus=Window{1a2b3c u0 com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity}\n  mFocusedApp=x"
        XCTAssertEqual(DeviceHub.parseAndroidFocus(dump),
                       "com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity")
        XCTAssertNil(DeviceHub.parseAndroidFocus("mCurrentFocus=null"))
    }

    // MARK: - MJPEG

    private func part(_ body: Data) -> Data {
        var data = Data("\r\n--mjpegstream\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private var syntheticStream: (stream: Data, frames: [Data]) {
        let frames = [Data([0xFF, 0xD8, 1, 2, 3, 0x0D, 0x0A, 0x0D, 0x0A, 0xFF, 0xD9]),
                      Data([0xFF, 0xD8] + Array(repeating: 7, count: 300) + [0xFF, 0xD9]),
                      Data([0xFF, 0xD8, 0xFF, 0xD9])]
        var stream = Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=--mjpegstream\r\n\r\n".utf8)
        for frame in frames { stream.append(part(frame)) }
        return (stream, frames)
    }

    func testMJPEGParsesAWholeStream() {
        var parser = MJPEGParser()
        let (stream, frames) = syntheticStream
        XCTAssertEqual(parser.append(stream), frames)
        XCTAssertEqual(parser.append(Data()), [])
    }

    func testMJPEGHandlesEveryChunkBoundary() {
        let (stream, frames) = syntheticStream
        // One byte at a time, then every two-chunk split.
        var parser = MJPEGParser()
        var got: [Data] = []
        for byte in stream { got += parser.append(Data([byte])) }
        XCTAssertEqual(got, frames)
        for split in stride(from: 1, to: stream.count, by: 7) {
            var parser = MJPEGParser()
            let out = parser.append(stream.prefix(split)) + parser.append(stream.suffix(from: split))
            XCTAssertEqual(out, frames, "split at \(split)")
        }
    }

    func testMJPEGWaitsForTheRestOfAFrame() {
        var parser = MJPEGParser()
        let body = Data(repeating: 9, count: 100)
        let whole = part(body)
        XCTAssertEqual(parser.append(whole.prefix(whole.count - 1)), [])
        XCTAssertEqual(parser.append(whole.suffix(1)), [body])
        XCTAssertEqual(MJPEGParser.contentLength("--b\r\ncontent-length: 42"), 42)
        XCTAssertNil(MJPEGParser.contentLength("HTTP/1.1 200 OK"))
    }

    // MARK: - Geometry

    func testFitsAndLetterboxes() {
        let rect = DeviceHub.fit(CGSize(width: 400, height: 800), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect, CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertEqual(DeviceHub.fit(.zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testMapsViewPointsOntoTheScreen() {
        let view = CGSize(width: 400, height: 400), screen = CGSize(width: 402, height: 804)
        // The screen sits in x 100…300; the bars around it aren't the screen.
        XCTAssertNil(DeviceHub.normalized(CGPoint(x: 50, y: 200), in: view, screen: screen))
        let center = DeviceHub.normalized(CGPoint(x: 200, y: 200), in: view, screen: screen)!
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.001)
        let corner = DeviceHub.normalized(CGPoint(x: 100, y: 0), in: view, screen: screen)!
        XCTAssertEqual(corner, .zero)
        let p = DeviceHub.devicePoint(center, screen: screen)
        XCTAssertEqual(p.x, 201)
        XCTAssertEqual(p.y, 402)
        // The far edge stays on the screen.
        let edge = DeviceHub.devicePoint(CGPoint(x: 1, y: 1), screen: CGSize(width: 1080, height: 2400))
        XCTAssertEqual(edge.x, 1079)
        XCTAssertEqual(edge.y, 2399)
    }

    func testScrollBecomesASwipeTheWayContentMoves() {
        let view = CGSize(width: 200, height: 400)
        let swipe = DeviceHub.scrollSwipe(delta: CGSize(width: 0, height: -100), from: CGPoint(x: 0.5, y: 0.5), viewSize: view)!
        XCTAssertEqual(swipe.to.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(swipe.to.x, 0.5, accuracy: 0.001)
        let big = DeviceHub.scrollSwipe(delta: CGSize(width: 0, height: 4000), from: CGPoint(x: 0.5, y: 0.5), viewSize: view)!
        XCTAssertEqual(big.to.y, 0.9, accuracy: 0.001)
        XCTAssertNil(DeviceHub.scrollSwipe(delta: CGSize(width: 0.1, height: 0.1), from: .zero, viewSize: view))
    }

    func testCornerRadii() {
        XCTAssertEqual(DeviceHub.cornerRadius(for: CGSize(width: 100, height: 200), tablet: false), 14, accuracy: 0.001)
        XCTAssertLessThan(DeviceHub.cornerRadius(for: CGSize(width: 100, height: 200), tablet: true), 14)
    }

    // MARK: - Commands

    private let iphone = DeviceInfo(id: "U1", name: "iPhone", platform: .ios, version: "iOS 26.0", booted: true)
    private let pixel = DeviceInfo(id: "Pixel_8", name: "Pixel 8", platform: .android, version: "15", booted: true,
                                   serial: "emulator-5554")

    func testIOSInputCommands() {
        let screen = CGSize(width: 402, height: 874)
        XCTAssertEqual(DeviceCommands.input(.tap(CGPoint(x: 0.5, y: 0.5)), device: iphone, screen: screen),
                       ["axe", "tap", "-x", "201", "-y", "437", "--udid", "U1"])
        XCTAssertEqual(DeviceCommands.input(.swipe(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2), duration: 0.3),
                                            device: iphone, screen: screen),
                       ["axe", "swipe", "--start-x", "201", "--start-y", "699", "--end-x", "201", "--end-y", "175",
                        "--duration", "0.30", "--udid", "U1"])
        XCTAssertEqual(DeviceCommands.input(.text("hi there"), device: iphone, screen: screen),
                       ["axe", "type", "hi there", "--udid", "U1"])
        XCTAssertNil(DeviceCommands.input(.text(""), device: iphone, screen: screen))
        XCTAssertEqual(DeviceCommands.input(.key(.enter), device: iphone, screen: screen), ["axe", "key", "40", "--udid", "U1"])
        XCTAssertEqual(DeviceCommands.input(.key(.delete), device: iphone, screen: screen), ["axe", "key", "42", "--udid", "U1"])
        XCTAssertEqual([DeviceKey.right, .left, .down, .up].map(\.hid), [79, 80, 81, 82])
        XCTAssertEqual(DeviceCommands.input(.button(.home), device: iphone, screen: screen), ["axe", "button", "home", "--udid", "U1"])
        XCTAssertEqual(DeviceCommands.input(.button(.lock), device: iphone, screen: screen), ["axe", "button", "lock", "--udid", "U1"])
        XCTAssertNil(DeviceCommands.input(.button(.back), device: iphone, screen: screen))
    }

    func testAndroidInputCommands() {
        let screen = CGSize(width: 1080, height: 2400)
        XCTAssertEqual(DeviceCommands.input(.tap(CGPoint(x: 0.5, y: 0.25)), device: pixel, screen: screen),
                       ["adb", "-s", "emulator-5554", "shell", "input", "tap", "540", "600"])
        XCTAssertEqual(DeviceCommands.input(.swipe(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0.5, y: 0.5), duration: 0.25),
                                            device: pixel, screen: screen),
                       ["adb", "-s", "emulator-5554", "shell", "input", "swipe", "0", "0", "540", "1200", "250"])
        XCTAssertEqual(DeviceCommands.input(.key(.enter), device: pixel, screen: screen),
                       ["adb", "-s", "emulator-5554", "shell", "input", "keyevent", "66"])
        XCTAssertEqual([DeviceKey.delete, .up, .down, .left, .right].map(\.android), [67, 19, 20, 21, 22])
        let buttons: [DeviceButton] = [.home, .back, .recents, .power]
        XCTAssertEqual(buttons.map { DeviceCommands.input(.button($0), device: pixel, screen: screen)?.last },
                       ["3", "4", "187", "26"])
        XCTAssertEqual(DeviceCommands.input(.text("a b&c's"), device: pixel, screen: screen)?.last, "a%sb\\&c\\'s")
        var stopped = pixel
        stopped.serial = nil
        XCTAssertNil(DeviceCommands.input(.tap(.zero), device: stopped, screen: screen))
    }

    func testPowerAndVideoCommands() {
        XCTAssertEqual(DeviceCommands.boot(iphone), ["xcrun", "simctl", "boot", "U1"])
        XCTAssertEqual(DeviceCommands.bootStatus(udid: "U1"), ["xcrun", "simctl", "bootstatus", "U1", "-b"])
        XCTAssertEqual(DeviceCommands.boot(pixel), ["emulator", "-avd", "Pixel_8", "-no-snapshot-save"])
        XCTAssertEqual(DeviceCommands.shutdown(iphone), ["xcrun", "simctl", "shutdown", "U1"])
        XCTAssertEqual(DeviceCommands.shutdown(pixel), ["adb", "-s", "emulator-5554", "emu", "kill"])
        XCTAssertEqual(DeviceCommands.stream(udid: "U1"),
                       ["axe", "stream-video", "--udid", "U1", "--format", "mjpeg", "--fps", "15",
                        "--quality", "70", "--scale", "0.5"])
        XCTAssertEqual(DeviceCommands.frame(iphone, to: "/t.jpg"),
                       ["xcrun", "simctl", "io", "U1", "screenshot", "--type=jpeg", "/t.jpg"])
        XCTAssertEqual(DeviceCommands.frame(pixel, to: "/t"), ["adb", "-s", "emulator-5554", "exec-out", "screencap", "-p"])
        XCTAssertEqual(DeviceCommands.screenshot(iphone, to: "/s.png"),
                       ["xcrun", "simctl", "io", "U1", "screenshot", "--type=png", "/s.png"])
        XCTAssertEqual(DeviceCommands.bootCompleted(serial: "emulator-5554"),
                       ["adb", "-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"])
    }

    func testAppearanceCommands() {
        XCTAssertEqual(DeviceCommands.setAppearance(iphone, dark: true), ["xcrun", "simctl", "ui", "U1", "appearance", "dark"])
        XCTAssertEqual(DeviceCommands.setAppearance(pixel, dark: false),
                       ["adb", "-s", "emulator-5554", "shell", "cmd", "uimode", "night", "no"])
        XCTAssertEqual(DeviceCommands.parseDark("dark"), true)
        XCTAssertEqual(DeviceCommands.parseDark("Night mode: no"), false)
        XCTAssertNil(DeviceCommands.parseDark("unsupported"))
        XCTAssertEqual(DeviceCommands.setTextSize(iphone, .extraLarge),
                       ["xcrun", "simctl", "ui", "U1", "content_size", "accessibility-large"])
        XCTAssertEqual(DeviceCommands.setTextSize(pixel, .small)?.last, "0.85")
        XCTAssertEqual(DeviceTextSize(iosCategory: "large"), .standard)
        XCTAssertEqual(DeviceTextSize.allCases.map(\.title), ["Small", "Default", "Large", "Extra Large"])
        XCTAssertEqual(DeviceCommands.increaseContrast(udid: "U1", true),
                       ["xcrun", "simctl", "ui", "U1", "increase_contrast", "enabled"])
        XCTAssertEqual(DeviceCommands.rotate(serial: "e", to: 5).map { $0.last }, ["0", "1"])
    }

    func testToolCommands() {
        XCTAssertEqual(DeviceCommands.openURL(iphone, "myapp://x"), ["xcrun", "simctl", "openurl", "U1", "myapp://x"])
        XCTAssertEqual(DeviceCommands.openURL(pixel, "https://a.b/?x=1&y='2'")?.last, "'https://a.b/?x=1&y='\\''2'\\'''")
        XCTAssertEqual(DeviceCommands.launch(iphone, "com.a"), ["xcrun", "simctl", "launch", "U1", "com.a"])
        XCTAssertEqual(DeviceCommands.launch(pixel, "com.a"),
                       ["adb", "-s", "emulator-5554", "shell", "monkey", "-p", "com.a", "-c",
                        "android.intent.category.LAUNCHER", "1"])
        XCTAssertEqual(DeviceCommands.terminate(pixel, "com.a"), ["adb", "-s", "emulator-5554", "shell", "am", "force-stop", "com.a"])
        XCTAssertEqual(DeviceCommands.setLocation(iphone, latitude: 37.7749, longitude: -122.4194),
                       ["xcrun", "simctl", "location", "U1", "set", "37.7749,-122.4194"])
        XCTAssertEqual(DeviceCommands.setLocation(pixel, latitude: 1.5, longitude: 2.5),
                       ["adb", "-s", "emulator-5554", "emu", "geo", "fix", "2.5", "1.5"])
        XCTAssertEqual(DeviceCommands.clearLocation(udid: "U1"), ["xcrun", "simctl", "location", "U1", "clear"])
        XCTAssertNotNil(DeviceCommands.parseCoordinate(latitude: " 59.3293", longitude: "18.0686 "))
        XCTAssertNil(DeviceCommands.parseCoordinate(latitude: "91", longitude: "0"))
        XCTAssertNil(DeviceCommands.parseCoordinate(latitude: "x", longitude: "0"))
        XCTAssertEqual(DeviceLocationPreset.all.count, 5)
        XCTAssertEqual(DeviceCommands.permission(iphone, .grant, service: "photos", app: "com.a"),
                       ["xcrun", "simctl", "privacy", "U1", "grant", "photos", "com.a"])
        XCTAssertEqual(DeviceCommands.permission(pixel, .revoke, service: "CAMERA", app: "com.a"),
                       ["adb", "-s", "emulator-5554", "shell", "pm", "revoke", "com.a", "android.permission.CAMERA"])
        XCTAssertEqual(DeviceCommands.permission(pixel, .reset, service: "CAMERA", app: "com.a"),
                       ["adb", "-s", "emulator-5554", "shell", "pm", "reset-permissions", "-p", "com.a"])
        XCTAssertEqual(DeviceCommands.push(udid: "U1", bundle: "com.a", payloadPath: "/p.json"),
                       ["xcrun", "simctl", "push", "U1", "com.a", "/p.json"])
        XCTAssertEqual(String(decoding: DeviceCommands.pushPayload(alert: "Hi \"you\""), as: UTF8.self),
                       #"{"aps":{"alert":"Hi \"you\""}}"#)
        XCTAssertEqual(DeviceCommands.cleanStatusBar(udid: "U1").prefix(5), ["xcrun", "simctl", "status_bar", "U1", "override"])
        XCTAssertEqual(DeviceCommands.resetStatusBar(udid: "U1"), ["xcrun", "simctl", "status_bar", "U1", "clear"])
        XCTAssertEqual(DeviceCommands.openInSimulatorApp(udid: "U1"),
                       ["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", "U1"])
    }

    // MARK: - Setup

    func testPicksTheNewestIPhoneOnTheNewestRuntime() {
        let json = """
        {"runtimes":[
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","version":"26.4.1","platform":"iOS","isAvailable":true,
           "supportedDeviceTypes":[{"identifier":"T.iPhone-17","productFamily":"iPhone"}]},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","version":"27.0","platform":"iOS","isAvailable":true,
           "supportedDeviceTypes":[{"identifier":"T.iPad","productFamily":"iPad"},
                                   {"identifier":"T.iPhone-18-Pro","productFamily":"iPhone"},
                                   {"identifier":"T.iPhone-11","productFamily":"iPhone"}]},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-10","version":"26.10","platform":"iOS","isAvailable":false,
           "supportedDeviceTypes":[{"identifier":"T.x","productFamily":"iPhone"}]},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-12-0","version":"30.0","platform":"watchOS","isAvailable":true,
           "supportedDeviceTypes":[{"identifier":"T.w","productFamily":"iPhone"}]}
        ]}
        """
        let newest = DeviceHub.newestIPhone(Data(json.utf8))
        XCTAssertEqual(newest?.deviceType, "T.iPhone-18-Pro")
        XCTAssertEqual(newest?.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertNil(DeviceHub.newestIPhone(Data(#"{"runtimes":[]}"#.utf8)))
        XCTAssertEqual(DeviceCommands.createIPhone(deviceType: "T", runtime: "R"),
                       ["xcrun", "simctl", "create", "iPhone (Octet)", "T", "R"])
    }

    func testSetupStatusesAndWhenItShows() {
        XCTAssertEqual(DeviceSetup.iosStatus(xcode: false, devices: 3), .missing)
        XCTAssertEqual(DeviceSetup.iosStatus(xcode: true, devices: 0), .noDevices)
        XCTAssertEqual(DeviceSetup.iosStatus(xcode: true, devices: 1), .ready)
        XCTAssertEqual(DeviceSetup.androidStatus(sdk: true, devices: 0), .noDevices)
        XCTAssertEqual(DeviceSetup.iosMessage(.missing), "iOS Simulators need Xcode.")
        XCTAssertTrue(DeviceSetup.androidMessage(.missing).hasPrefix("Android SDK was not found."))
        XCTAssertEqual(DeviceSetup.Step.allCases.map(\.title), ["Simulators", "Touch & Keys", "Agent Access"])
        XCTAssertTrue(DeviceSetup.needed(done: false, deviceCount: 4))
        XCTAssertTrue(DeviceSetup.needed(done: true, deviceCount: 0))
        XCTAssertFalse(DeviceSetup.needed(done: true, deviceCount: 1))
    }

    func testScreenshotNamesAndFailureDetail() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 16; parts.hour = 9; parts.minute = 41; parts.second = 5
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(DeviceCommands.screenshotName(device: "iPhone 17/Pro", date: date), "iPhone 17-Pro-20261016-094105.png")
        XCTAssertEqual(DeviceCommands.failureDetail("  "), "The command failed with no output.")
        XCTAssertEqual(DeviceCommands.failureDetail(String(repeating: "x", count: 300), limit: 10), "xxxxxxxxxx…")
    }
}
