import Foundation

/// The operating systems a plugin can run on. Plugin manifests, the
/// registry and this file are plain Foundation, so Octet on any of them
/// reads the same plugins; only the commands a plugin runs differ.
enum PluginPlatform: String, CaseIterable, Codable {
    case macos, linux, windows

    static var current: PluginPlatform {
        #if os(macOS)
        .macos
        #elseif os(Windows)
        .windows
        #else
        .linux
        #endif
    }

    /// Runs POSIX `sh`: a plugin's plain-string command works here.
    var isUnix: Bool { self != .windows }

    /// Where a manifest doesn't say: its plain-string commands are `sh`.
    static let unixDefault: [PluginPlatform] = [.macos, .linux]

    /// `command` with an environment variable set first, in this
    /// platform's shell: `sh` on macOS and Linux, PowerShell on Windows.
    func settingEnvironment(_ name: String, to value: String, before command: String) -> String {
        switch self {
        case .windows:
            "$env:\(name) = '" + value.replacingOccurrences(of: "'", with: "''") + "'\n" + command
        case .macos, .linux:
            "\(name)='" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'; export \(name)\n" + command
        }
    }
}

/// What a plugin runs, per platform. In a manifest it is either a string,
/// an `sh` command for macOS and Linux:
///
///     "run": "sh \"$OCTET_PLUGIN_DIR/scripts/chip.sh\""
///
/// or one command per platform, `unix` covering macOS and Linux, and
/// `windows` a PowerShell command:
///
///     "run": { "unix": "sh \"$OCTET_PLUGIN_DIR/chip.sh\"",
///              "windows": "& \"$env:OCTET_PLUGIN_DIR\\chip.ps1\"" }
///
/// A contribution with no command for the platform Octet runs on is left
/// out there, and the rest of the plugin still works.
struct PluginCommand: Codable, Equatable {
    /// Keyed by `unix`, `macos`, `linux` or `windows`.
    private(set) var commands: [String: String]

    init(_ command: String) { commands = ["unix": command] }
    init(commands: [String: String]) { self.commands = commands }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let command = try? container.decode(String.self) {
            commands = ["unix": command]
        } else {
            commands = try container.decode([String: String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if commands.count == 1, let unix = commands["unix"] { try container.encode(unix) } else { try container.encode(commands) }
    }

    /// The command for `platform`: its own, else `unix` on macOS and Linux.
    func command(for platform: PluginPlatform = .current) -> String? {
        let own = commands[platform.rawValue] ?? (platform.isUnix ? commands["unix"] : nil)
        return own.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Platforms it has a command for.
    var platforms: [PluginPlatform] { PluginPlatform.allCases.filter { command(for: $0) != nil } }

    /// Keys it may use.
    static let keys: Set<String> = ["unix", "macos", "linux", "windows"]
}
