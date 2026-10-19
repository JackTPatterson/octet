import Foundation
import Darwin

/// Executes an archive/precheck in its own process group. Timeout always fails,
/// even if a termination handler exits zero; descendants in the group are stopped.
enum ArchiveHook {
    static func run(_ config: ProjectConfiguration, checkout: String, root: String, label: String = "Archive") async throws {
        guard let command = config.archive, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await Task.detached {
            let logs = EngineSession.supportDirectory.appendingPathComponent("archive-logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent(UUID().uuidString + ".log")
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            func check(_ code: Int32) throws {
                guard code == 0 else { throw HookError(message: String(cString: strerror(code))) }
            }
            try check(posix_spawn_file_actions_addchdir_np(&actions, checkout))
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_EXCL, 0o600))
            try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            var env = ProcessInfo.processInfo.environment
            env["OCTET_ROOT_PATH"] = root; env["OCTET_WORKTREE_PATH"] = checkout
            var argv = ["/bin/zsh", "-l", "-c", command].map { strdup($0) } + [nil]
            var envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            try check(posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, &envp))
            let deadline = ProcessInfo.processInfo.systemUptime + Double(config.archiveTimeoutSeconds ?? 120)
            var status: Int32 = 0
            while true {
                let observed = waitpid(pid, &status, WNOHANG)
                if observed == pid { break }
                if observed < 0 {
                    if errno == EINTR { continue }
                    throw HookError(message: "\(label) completion could not be observed. Log: \(log.path)")
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    kill(-pid, SIGTERM)
                    // Keep the leader unreaped until the group kill, preventing PID reuse.
                    usleep(200_000)
                    kill(-pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    throw HookError(message: "\(label) timed out. Log: \(log.path)")
                }
                usleep(20_000)
            }
            guard status == 0 else { throw HookError(message: "\(label) failed (exit \((status >> 8) & 255), signal \(status & 127)). Log: \(log.path)") }
        }.value
    }
    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
