import Foundation

/// Runs a CLI through the user's login shell, so it sees the same PATH as a
/// terminal. Arguments are passed as "$@", never spliced into shell text,
/// so a task description with quotes can't break out.
enum LoginShell {
    struct Result {
        let status: Int32
        let output: String
    }

    /// `input` goes to the command's stdin (e.g. `gh api --input -`, so a
    /// request body never touches a temporary file); without it stdin is
    /// empty, so nothing can stop to ask.
    static func run(_ arguments: [String], in directory: String? = nil, input: Data? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \"$0\" \"$@\""] + arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        if let stdin, let input {
            // Written off this thread: a body bigger than the pipe's buffer
            // would block until the output below is drained.
            // A command that exits without reading it must fail the write,
            // not raise SIGPIPE and take Octet with it.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
