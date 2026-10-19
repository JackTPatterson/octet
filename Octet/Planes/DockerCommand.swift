import Foundation

/// Docker commands use argv, bounded output and a deadline. Cancelling a hidden
/// pane stops its read request; action tasks live independently until completion.
enum DockerCommand {
    struct Output: Sendable {
        var status: Int32
        var text: String
        var error: String
        var truncated = false
        var failure: String { error.isEmpty ? text : error }
    }

    static func arguments(context: String, command: [String]) -> [String] {
        ["docker"] + (context.isEmpty ? [] : ["--context", context]) + command
    }

    static func run(context: String = "", _ command: [String], timeout: TimeInterval = 20,
                    mergeErrors: Bool = false) async -> Output {
        let job = Job()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: job.run(arguments(context: context, command: command), timeout: timeout, mergeErrors: mergeErrors))
                }
            }
        } onCancel: { job.stop() }
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func stop() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running, running.isRunning { running.terminate() }
        }

        func run(_ argv: [String], timeout: TimeInterval, mergeErrors: Bool) -> Output {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            task.arguments = ["-l", "-c", "exec \"$0\" \"$@\""] + argv
            task.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = mergeErrors ? stdout : stderr
            lock.lock()
            if cancelled { lock.unlock(); return Output(status: -1, text: "", error: "Cancelled") }
            process = task
            do { try task.run() } catch {
                process = nil
                lock.unlock()
                return Output(status: -1, text: "", error: error.localizedDescription)
            }
            lock.unlock()
            let deadline = DispatchWorkItem { [weak self] in self?.stop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let errors = Buffer()
            let group = DispatchGroup()
            if !mergeErrors {
                group.enter()
                DispatchQueue.global().async {
                    errors.read(stderr.fileHandleForReading)
                    group.leave()
                }
            }
            let output = Buffer()
            output.read(stdout.fileHandleForReading)
            task.waitUntilExit()
            group.wait()
            deadline.cancel()
            lock.lock()
            process = nil
            let stopped = cancelled
            lock.unlock()
            return Output(status: stopped ? -1 : task.terminationStatus,
                          text: output.text, error: stopped ? "Docker request cancelled or timed out. Try refreshing." : errors.text,
                          truncated: output.truncated || errors.truncated)
        }
    }

    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private(set) var truncated = false
        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
        func read(_ handle: FileHandle) {
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                let remaining = max(0, 1_048_576 - data.count)
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { truncated = true }
            }
        }
    }
}
