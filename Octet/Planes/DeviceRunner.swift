import AppKit
import ImageIO
import SwiftUI

// MARK: - Tools

/// Where the Device plane's command-line tools are. Octet launched from the
/// Dock doesn't see the terminal's PATH or ANDROID_HOME, so they're read
/// once from the login shell, then every command runs its tool by absolute
/// path: a login shell per tap would add a quarter second to each.
final class DeviceToolbox: @unchecked Sendable {
    static let shared = DeviceToolbox()

    private let lock = NSLock()
    private var resolved = false
    private var paths: [String: String] = [:]
    private var environment = ProcessInfo.processInfo.environment
    private var xcode = false
    private var sdkRoot: String?

    /// Reads the login shell's environment and finds each tool. Blocks, so
    /// it's only called off the main thread; later calls return at once.
    func resolve() {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        let env = LoginShell.run(["/usr/bin/env"])
        if env.status == 0 {
            for line in env.output.split(separator: "\n") {
                guard let equals = line.firstIndex(of: "=") else { continue }
                environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/xcrun") {
            paths["xcrun"] = "/usr/bin/xcrun"
            // xcrun exists with only the Command Line Tools; simctl needs Xcode.
            xcode = LoginShell.run(["/usr/bin/xcrun", "--find", "simctl"]).status == 0
        }
        paths["open"] = "/usr/bin/open"
        if let axe = ["/opt/homebrew/bin/axe", "/usr/local/bin/axe"].first(where: fm.isExecutableFile(atPath:)) {
            paths["axe"] = axe
        } else {
            let found = LoginShell.run(["which", "axe"])
            if found.status == 0, fm.isExecutableFile(atPath: found.output) { paths["axe"] = found.output }
        }
        sdkRoot = DeviceHub.androidSDKRoot(environment: environment, home: NSHomeDirectory(),
                                           exists: fm.isExecutableFile(atPath:))
        if let sdkRoot {
            paths["adb"] = (sdkRoot as NSString).appendingPathComponent("platform-tools/adb")
            let emulator = (sdkRoot as NSString).appendingPathComponent("emulator/emulator")
            if fm.isExecutableFile(atPath: emulator) { paths["emulator"] = emulator }
        }
    }

    /// Looks again next time, after something was installed.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        resolved = false
        paths = [:]
    }

    func path(_ tool: String) -> String? {
        resolve()
        lock.lock(); defer { lock.unlock() }
        return paths[tool]
    }

    var hasXcode: Bool { resolve(); lock.lock(); defer { lock.unlock() }; return xcode }
    var hasAxe: Bool { path("axe") != nil }
    var hasAndroid: Bool { path("adb") != nil }

    var processEnvironment: [String: String] {
        resolve()
        lock.lock(); defer { lock.unlock() }
        return environment
    }
}

// MARK: - Running commands

/// Runs DeviceCommands' argv with each tool's absolute path.
enum DeviceRunner {
    struct Output {
        var status: Int32
        var data: Data
        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        var ok: Bool { status == 0 }
    }

    /// Builds a process for `argv`; nil when its tool isn't installed.
    static func process(_ argv: [String]) -> Process? {
        guard let tool = argv.first, let path = DeviceToolbox.shared.path(tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        process.environment = DeviceToolbox.shared.processEnvironment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Runs to completion. Blocks: call it off the main thread. Errors are
    /// merged into the output unless `binary`, where stdout is the payload
    /// (a PNG from `screencap`). A `timeout` stops it and fails.
    static func run(_ argv: [String], binary: Bool = false, timeout: TimeInterval? = nil) -> Output {
        guard let process = process(argv) else {
            return Output(status: -1, data: Data("\(argv.first ?? "The tool") isn't installed.".utf8))
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = binary ? FileHandle.nullDevice : pipe
        do { try process.run() } catch { return Output(status: -1, data: Data(error.localizedDescription.utf8)) }
        DeviceProcesses.shared.add(process)
        defer { DeviceProcesses.shared.remove(process) }
        let started = Date()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminate()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let timeout, process.terminationReason == .uncaughtSignal, Date().timeIntervalSince(started) >= timeout {
            return Output(status: -2, data: Data("Timed out after \(Int(timeout)) seconds.".utf8))
        }
        return Output(status: process.terminationStatus, data: data)
    }

    static func runIfPresent(_ argv: [String]?, binary: Bool = false, timeout: TimeInterval? = nil) async -> Output? {
        guard let argv else { return nil }
        return await run(argv, binary: binary, timeout: timeout)
    }

    static func run(_ argv: [String], binary: Bool = false, timeout: TimeInterval? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(argv, binary: binary, timeout: timeout))
            }
        }
    }

    /// Starts a process that outlives the plane (an Android emulator).
    static func launchDetached(_ argv: [String]) -> Bool {
        guard let process = process(argv) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}

/// The plane's own running processes (video streams, waits), stopped when
/// Octet quits so no `axe stream-video` is left behind.
final class DeviceProcesses: @unchecked Sendable {
    static let shared = DeviceProcesses()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]
    private var observer: NSObjectProtocol?

    func add(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = process
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: nil) { [weak self] _ in
                self?.terminateAll()
            }
        }
    }

    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(process)] = nil
    }

    func terminateAll() {
        lock.lock()
        let all = Array(running.values)
        running.removeAll()
        lock.unlock()
        for process in all where process.isRunning { process.terminate() }
        // A stream blocked on a full pipe ignores SIGTERM; Octet is quitting,
        // so whatever's left after a moment is killed.
        let deadline = Date().addingTimeInterval(0.5)
        while all.contains(where: \.isRunning) && Date() < deadline { usleep(20_000) }
        for process in all where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

// MARK: - Video

/// The latest frame, apart from the model so a new frame redraws only the
/// screen and not the whole plane.
@MainActor
final class DeviceFrameStore: ObservableObject {
    @Published var image: CGImage?
    /// The frame's size in pixels.
    var size: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
}

/// One device's live picture: `axe stream-video` read as MJPEG while AXe
/// is installed, otherwise a screenshot polled every so often. Frames
/// decode off the main thread; one that arrives mid-decode replaces the one
/// waiting rather than queueing behind it.
final class DeviceVideoStream: @unchecked Sendable {
    enum Source {
        case mjpeg(udid: String)
        case poll(DeviceInfo, interval: TimeInterval)
    }

    private let source: Source
    private let onFrame: @MainActor (CGImage) -> Void
    private let onStall: @MainActor () -> Void
    private let queue = DispatchQueue(label: "octet.device.video")
    private let decodeQueue = DispatchQueue(label: "octet.device.decode", qos: .userInteractive)
    // Everything below is touched only on `queue`.
    private var process: Process?
    private var stopped = true
    private var parser = MJPEGParser()
    private var backoff: TimeInterval = 1
    private var decoding = false
    private var waiting: Data?
    private var frames = 0
    private var generation = 0
    private var failures = 0

    /// How long without a first frame before the plane says so.
    static let stallAfter: TimeInterval = 10

    init(_ source: Source, onFrame: @escaping @MainActor (CGImage) -> Void, onStall: @escaping @MainActor () -> Void) {
        self.source = source
        self.onFrame = onFrame
        self.onStall = onStall
    }

    deinit {
        let process = self.process
        if let process { Self.end(process) }
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            frames = 0
            generation += 1
            let current = generation
            queue.asyncAfter(deadline: .now() + Self.stallAfter) { [weak self] in
                guard let self, !self.stopped, self.generation == current, self.frames == 0 else { return }
                let stall = self.onStall
                DispatchQueue.main.async { MainActor.assumeIsolated { stall() } }
            }
            switch source {
            case .mjpeg: spawn()
            case .poll: poll(current)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            generation += 1
            guard let process else { return }
            self.process = nil
            Self.end(process)
        }
    }

    /// Stops an `axe stream-video`. It handles SIGTERM by finishing its
    /// current write, so with nobody reading, a full pipe would hold it
    /// forever: the read end is closed (the write then fails) and a
    /// SIGKILL follows if it's still there a second later.
    static func end(_ process: Process) {
        let reader = (process.standardOutput as? Pipe)?.fileHandleForReading
        reader?.readabilityHandler = nil
        DispatchQueue.global(qos: .utility).async {
            if process.isRunning { process.terminate() }
            try? reader?.close()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            DeviceProcesses.shared.remove(process)
        }
    }

    // MARK: MJPEG

    private func spawn() {
        guard case .mjpeg(let udid) = source, !stopped,
              let process = DeviceRunner.process(DeviceCommands.stream(udid: udid)) else { return }
        parser = MJPEGParser()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let current = generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.received(data, generation: current) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.exited(generation: current) }
        }
        do {
            try process.run()
            self.process = process
            DeviceProcesses.shared.add(process)
        } catch {
            exited(generation: current)
        }
    }

    private func received(_ data: Data, generation current: Int) {
        guard current == generation, !stopped else { return }
        for jpeg in parser.append(data) { enqueue(jpeg) }
    }

    /// The stream ended without being asked: start it again, waiting a
    /// little longer each time (1s up to 8s) so a broken device isn't spun on.
    private func exited(generation current: Int) {
        guard current == generation, !stopped else { return }
        if let process { DeviceProcesses.shared.remove(process) }
        process = nil
        let delay = backoff
        backoff = min(backoff * 2, 8)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, current == self.generation else { return }
            self.spawn()
        }
    }

    // MARK: Polling

    private func poll(_ current: Int) {
        guard case .poll(let device, let interval) = source, current == generation, !stopped else { return }
        let path = NSTemporaryDirectory() + "octet-device-\(device.id).jpg"
        guard let argv = DeviceCommands.frame(device, to: path) else { return }
        let output = DeviceRunner.run(argv, binary: device.platform == .android, timeout: 10)
        if output.ok, let data = device.platform == .android ? output.data : try? Data(contentsOf: URL(fileURLWithPath: path)) {
            failures = 0
            enqueue(data)
        } else {
            failures += 1
        }
        let wait = failures > 0 ? min(interval * Double(1 << min(failures, 3)), 8) : interval
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.poll(current) }
    }

    // MARK: Decoding

    private func enqueue(_ data: Data) {
        if decoding { waiting = data; return }
        decoding = true
        decode(data)
    }

    private func decode(_ data: Data) {
        let onFrame = self.onFrame
        decodeQueue.async { [weak self] in
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            let image = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
            guard let self else { return }
            self.queue.async {
                if let image, !self.stopped {
                    self.frames += 1
                    self.backoff = 1
                    DispatchQueue.main.async { MainActor.assumeIsolated { onFrame(image) } }
                }
                if let next = self.waiting {
                    self.waiting = nil
                    self.decode(next)
                } else {
                    self.decoding = false
                }
            }
        }
    }
}

