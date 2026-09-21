import Foundation

/// Runs the session server's `plugin …` commands in the background for install/uninstall,
/// through an interactive login shell so plugin build steps see the user's
/// PATH (nvm, Homebrew).
enum PluginCLI {
    struct Result {
        let exitCode: Int32
        let output: String
    }

    static let previewMarker = "Plugin install preview:"
    static let promptMarker = "Install this plugin? [y/N]"

    /// Fetches a GitHub plugin and returns the session server's install preview without
    /// installing. The session server only prints the preview on a terminal, so this runs
    /// under `script` (a pty) and answers the prompt with "n".
    static func preview(repo: String, enginePath: String, completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let command = "exec \(shellQuote(enginePath)) --session \(EngineSession.name) plugin install \(shellQuote(repo))"
        run(
            executable: "/usr/bin/script",
            arguments: ["-q", "/dev/null", "/bin/zsh", "-lic", command],
            answer: (promptMarker, "n\n"),
            timeout: 180
        ) { result in
            let text = result.output.replacingOccurrences(of: "\r", with: "")
            if let start = text.range(of: previewMarker),
               let end = text.range(of: promptMarker, range: start.upperBound..<text.endIndex) {
                completion(.success(String(text[start.lowerBound..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                completion(.failure(PluginCLIError(message: lastLines(text))))
            }
        }
    }

    static func install(repo: String, enginePath: String, completion: @escaping (Result) -> Void) {
        shell("\(shellQuote(enginePath)) --session \(EngineSession.name) plugin install \(shellQuote(repo)) --yes", completion: completion)
    }

    static func uninstall(pluginId: String, enginePath: String, completion: @escaping (Result) -> Void) {
        shell("\(shellQuote(enginePath)) --session \(EngineSession.name) plugin uninstall \(shellQuote(pluginId))", completion: completion)
    }

    /// Parses `name:` and `version:` out of an install preview.
    static func previewField(_ field: String, in preview: String) -> String? {
        preview.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(field + ":") }
            .map { String($0.dropFirst(field.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    static func quote(_ value: String) -> String { shellQuote(value) }

    static func lastLines(_ text: String, count: Int = 3) -> String {
        text.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }

    /// Runs any command in an interactive login shell (the agent CLIs live
    /// on the user's PATH), off the main thread.
    static func runShell(_ command: String, timeout: TimeInterval = 600, completion: @escaping (Result) -> Void) {
        run(executable: "/bin/zsh", arguments: ["-lic", command + " </dev/null"], answer: nil, timeout: timeout, completion: completion)
    }

    private static func shell(_ command: String, completion: @escaping (Result) -> Void) {
        run(executable: "/bin/zsh", arguments: ["-lic", command + " </dev/null"], answer: nil, timeout: 600, completion: completion)
    }

    private static func run(
        executable: String,
        arguments: [String],
        answer: (marker: String, text: String)?,
        timeout: TimeInterval,
        completion: @escaping (Result) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            let input = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input

            let lock = NSLock()
            var collected = Data()
            var answered = false
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                collected.append(chunk)
                let text = String(decoding: collected, as: UTF8.self)
                let shouldAnswer = !answered && answer.map { text.contains($0.marker) } == true
                if shouldAnswer { answered = true }
                lock.unlock()
                if shouldAnswer, let answer {
                    input.fileHandleForWriting.write(Data(answer.text.utf8))
                }
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(Result(exitCode: -1, output: String(describing: error))) }
                return
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            collected.append(output.fileHandleForReading.readDataToEndOfFile())
            let text = String(decoding: collected, as: UTF8.self)
            lock.unlock()
            let status = process.terminationStatus
            DispatchQueue.main.async { completion(Result(exitCode: status, output: text)) }
        }
    }
}

struct PluginCLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message.isEmpty ? "No install preview was returned" : message }
}
