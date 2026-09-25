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
            return (processName(name, argv0: raw["argv0"] as? String), pid)
        }
        return ProcessInfo(shellPid: info["shell_pid"] as? Int, foreground: processes)
    }

    /// What a process is, by name. Claude Code retitles its process to its
    /// version ("2.1.282"), which names nothing; the command it was started
    /// as still says what it is.
    static func processName(_ name: String, argv0: String?) -> String {
        guard let argv0, !argv0.isEmpty,
              !name.isEmpty, name.allSatisfy({ $0.isNumber || $0 == "." }) else { return name }
        return (argv0 as NSString).lastPathComponent
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

    /// Whether the terminal the shell is on is asking for a secret right now:
    /// echo off with line mode on, which is how `sudo`, `ssh`, `passwd` and
    /// `read -s` read a password. Checked live on the shell's tty, so it
    /// holds whichever program in the pane is asking. nil when it can't tell.
    static func secretPrompt(shellPid pid: Int) -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let fd = open("/dev/" + String(cString: name), O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return nil }
        return isSecretMode(mode.c_lflag)
    }

    /// Echo off and canonical (line) mode on.
    static func isSecretMode(_ flags: tcflag_t) -> Bool {
        flags & tcflag_t(ECHO) == 0 && flags & tcflag_t(ICANON) != 0
    }

    /// Whether the shell's line goes on past the cursor, from the text on the
    /// cursor's row from the cursor rightward. Only the first two cells
    /// count: the cursor sits on a character, or on the space before the
    /// next word, while a right-side prompt sits far off at the edge.
    static func lineContinues(afterCursor text: String) -> Bool {
        text.prefix(2).contains { !$0.isWhitespace }
    }

    /// The shell's own name, for history and quoting decisions.
    static func shellName(_ info: ProcessInfo?) -> String? {
        guard let name = info?.foreground.first?.name else { return nil }
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
