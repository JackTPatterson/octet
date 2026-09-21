import Foundation

/// Runs a CLI through the user's login shell, so it sees the same PATH as a
/// terminal. Arguments are passed as "$@", never spliced into shell text,
/// so a task description with quotes can't break out.
enum LoginShell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ arguments: [String], in directory: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \"$0\" \"$@\""] + arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
