import Foundation

/// One pane's terminal over the engine's `pane.stream`: a replay of where the
/// pane is now, then its raw output as it comes, and the bytes typed into it
/// going back the same way. A stream that ends (the engine restarted, or the
/// view fell too far behind) starts again with a fresh replay.
final class PaneStream: @unchecked Sendable {
    struct Size: Equatable {
        var cols: Int
        var rows: Int
        var widthPx: Int
        var heightPx: Int
    }

    let paneId: String
    private let socketPath: String
    /// Called on the main thread. `replay` follows a reset: what to draw
    /// from nothing. `output` is everything after it, in order.
    var onReplay: (@MainActor (Data) -> Void)?
    var onOutput: (@MainActor (Data) -> Void)?
    /// The pane is gone; the stream won't start again.
    var onClosed: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var connection: EngineSocketConnection?
    private var size: Size
    private var stopped = false
    private var pending = Data()
    private var deliveryScheduled = false
    /// Input and resizes go out in order, off the main thread.
    private let writes = DispatchQueue(label: "com.jpxsoftware.octet.pane-stream.write", qos: .userInteractive)

    init(paneId: String, socketPath: String, size: Size) {
        self.paneId = paneId
        self.socketPath = socketPath
        self.size = size
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "pane-stream \(paneId)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let connection = self.connection
        lock.unlock()
        connection?.shutdownNow()
    }

    func send(input: Data) {
        guard !input.isEmpty else { return }
        write(["input": input.base64EncodedString()])
    }

    func resize(_ size: Size) {
        lock.lock()
        let changed = self.size != size
        self.size = size
        lock.unlock()
        guard changed else { return }
        write(["resize": ["cols": size.cols, "rows": size.rows, "width_px": size.widthPx, "height_px": size.heightPx]])
    }

    private func write(_ line: [String: Any]) {
        writes.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let connection = self.connection
            self.lock.unlock()
            try? connection?.send(line)
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var retry = 0.1
        while !isStopped {
            switch stream() {
            case .closed:
                DispatchQueue.main.async { [weak self] in self?.onClosed?() }
                return
            case .restart:
                retry = 0.1
            case .failed:
                // The engine may be starting or restarting.
                Thread.sleep(forTimeInterval: retry)
                retry = min(retry * 2, 2)
            }
        }
    }

    private enum Ending { case closed, restart, failed }

    /// One stream from start to end.
    private func stream() -> Ending {
        guard let connection = try? EngineSocketConnection(path: socketPath) else { return .failed }
        lock.lock()
        let size = self.size
        self.connection = connection
        lock.unlock()
        defer {
            lock.lock()
            if self.connection === connection { self.connection = nil }
            lock.unlock()
        }
        var params: [String: Any] = ["pane_id": paneId]
        if size.cols > 0, size.rows > 0 {
            params["cols"] = size.cols
            params["rows"] = size.rows
            params["width_px"] = size.widthPx
            params["height_px"] = size.heightPx
        }
        do {
            try connection.send(["id": "octet-pane-\(paneId)", "method": "pane.stream", "params": params])
            let first = try connection.readLine()
            guard let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any] else { return .failed }
            if let error = object["error"] as? [String: Any] {
                // No such pane: it closed between the snapshot and now.
                return error["code"] as? String == "pane_not_found" ? .closed : .failed
            }
            guard let result = object["result"] as? [String: Any],
                  let replay = (result["replay"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return .failed }
            deliver(replay: replay)
            while true {
                let line = try connection.readLine()
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch object["event"] as? String {
                case "pane.output":
                    if let data = (object["data"] as? String).flatMap({ Data(base64Encoded: $0) }) { deliver(output: data) }
                case "pane.stream_ended":
                    let reason = object["reason"] as? String
                    if reason == "pane_closed" { return .closed }
                    return reason == "overflow" ? .restart : .failed
                default:
                    continue
                }
            }
        } catch {
            return .failed
        }
    }

    /// A replay replaces whatever was drawn, and anything still waiting.
    private func deliver(replay: Data) {
        lock.lock()
        pending.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onReplay?(replay) }
    }

    /// Output read while the main thread is busy goes over in one piece.
    private func deliver(output: Data) {
        lock.lock()
        pending.append(output)
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let bytes = self.pending
            self.pending.removeAll(keepingCapacity: true)
            self.deliveryScheduled = false
            self.lock.unlock()
            if !bytes.isEmpty { self.onOutput?(bytes) }
        }
    }
}
