import Darwin
import Foundation

/// Whether a pane is sitting at its shell's prompt, which is the only time
/// Octet takes the keyboard to edit the command line itself. The moment any
/// program runs — an agent, an editor, a pager — typing goes straight
/// through, so nothing can be trapped behind Octet's editor.
enum ShellPrompt {
    /// Shells Octet recognises; anything else running is a program.
    static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "-zsh", "-bash", "-fish",
    ]

    /// What `pane.process_info` reports, trimmed to what matters here.
    struct ProcessInfo: Equatable {
        var shellPid: Int?
        /// name and pid of each foreground process.
        var foreground: [(name: String, pid: Int)]
        /// Descendants kept alive behind the foreground command. Populated by
        /// the runtime inspector, not required for prompt detection.
        var background: [(name: String, pid: Int)] = []

        static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool {
            lhs.shellPid == rhs.shellPid
                && lhs.foreground.map(\.pid) == rhs.foreground.map(\.pid)
                && lhs.foreground.map(\.name) == rhs.foreground.map(\.name)
                && lhs.background.map(\.pid) == rhs.background.map(\.pid)
                && lhs.background.map(\.name) == rhs.background.map(\.name)
        }
    }

    static func parse(_ result: [String: Any]) -> ProcessInfo? {
        guard let info = result["process_info"] as? [String: Any] else { return nil }
        let processes = (info["foreground_processes"] as? [[String: Any]] ?? []).compactMap { raw -> (String, Int)? in
            guard let name = raw["name"] as? String, let pid = raw["pid"] as? Int else { return nil }
            return (name, pid)
        }
        return ProcessInfo(shellPid: info["shell_pid"] as? Int, foreground: processes)
    }

    /// True when the only thing in the foreground is the pane's own shell.
    static func isAtPrompt(_ info: ProcessInfo?) -> Bool {
        guard let info, !info.foreground.isEmpty else { return false }
        return info.foreground.allSatisfy { process in
            let name = process.name.hasPrefix("-") ? String(process.name.dropFirst()) : process.name
            let isShell = shells.contains(name) || shells.contains(process.name)
            return isShell && (info.shellPid == nil || process.pid == info.shellPid)
        }
    }

    /// Whether the shell's line editor (zsh's ZLE, readline, fish) owns the
    /// terminal right now. Line editors switch the tty to non-canonical mode
    /// and echo keys themselves; `read`, and `read -s` for a password, keep
    /// canonical mode. So a shell in the foreground is not enough to know
    /// it's safe to take the keyboard: this is the check that keeps a secret
    /// out of Octet's line and history. nil when the tty can't be read.
    static func lineEditorActive(shellPid pid: Int) -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A program started from the prompt (a REPL, ssh, a password
        // prompt) shares the tty and may set the same mode; only the shell
        // owning the tty's foreground process group means it's the shell's
        // line editor. Checked live, so it can't lag behind like a snapshot.
        guard info.e_tpgid == info.pbi_pgid else { return false }
        guard info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let fd = open("/dev/" + String(cString: name), O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return nil }
        return mode.c_lflag & tcflag_t(ICANON) == 0
    }

    /// The shell's own name, for history and quoting decisions.
    static func shellName(_ info: ProcessInfo?) -> String? {
        guard let name = info?.foreground.first?.name else { return nil }
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
