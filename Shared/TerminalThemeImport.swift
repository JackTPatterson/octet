import Foundation

/// Reads the colours your terminal already uses, so Herd can follow them
/// instead of imposing its own. Ghostty-style `key = value` config is the
/// format: the same shape covers a config file, a theme file it points at,
/// and most hand-written theme files people keep around.
enum TerminalThemeImport {
    /// Files worth looking in, in the order a terminal would read them.
    static func searchPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/.config/alacritty/alacritty.toml",
        ]
    }

    /// Where a named theme might live, for `theme = name`.
    static func themePaths(named name: String, home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.config/ghostty/themes/\(name)",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)",
            "/opt/homebrew/share/ghostty/themes/\(name)",
        ]
    }

    /// The first terminal config Herd can read colours from.
    static func importFromConfig(home: String = NSHomeDirectory()) -> TerminalTheme? {
        for path in searchPaths(home: home) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let name = (path as NSString).lastPathComponent
            if let theme = parse(text, name: "Terminal") { return theme }
            // The config may only name a theme; follow it.
            if let named = themeName(in: text) {
                for candidate in themePaths(named: named, home: home) {
                    guard let themeText = try? String(contentsOfFile: candidate, encoding: .utf8),
                          let theme = parse(themeText, name: named) else { continue }
                    return theme
                }
            }
            _ = name
        }
        return nil
    }

    /// `theme = tokyonight`, including the `dark:x,light:y` form.
    static func themeName(in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "theme" else { continue }
            let value = parts[1]
            if let dark = value.split(separator: ",").first(where: { $0.hasPrefix("dark:") }) {
                return String(dark.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            }
            return value
        }
        return nil
    }

    /// Builds a theme from `background`, `foreground`, `palette = N=#rgb`
    /// and friends. Returns nil when the file carries no colours.
    static func parse(_ text: String, name: String) -> TerminalTheme? {
        var background: String?
        var foreground: String?
        var cursor: String?
        var palette = [String?](repeating: nil, count: 16)

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = hex(value)
            case "foreground": foreground = hex(value)
            case "cursor-color", "cursor_color": cursor = hex(value)
            case "palette":
                // `palette = 4=#7aa2f7`
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      index >= 0, index < 16, let colour = hex(parts[1]) else { continue }
                palette[index] = colour
            default:
                continue
            }
        }

        guard let background, let foreground else { return nil }
        let filled = defaults(background: background, foreground: foreground)
        let ansi = (0..<16).map { palette[$0] ?? filled[$0] }
        return TerminalTheme(
            name: name,
            background: background,
            foreground: foreground,
            // Blue is what terminals use for the things Herd accents.
            accent: cursor ?? palette[4] ?? filled[4],
            ansi: ansi,
            isLight: isLight(background)
        )
    }

    /// `#rrggbb`, `rrggbb`, or `rgb` — all become six digits, no hash.
    static func hex(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return text.lowercased()
    }

    /// A light background wants dark chrome; measured the way terminals do.
    static func isLight(_ background: String) -> Bool {
        guard let value = Int(background, radix: 16) else { return false }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.5
    }

    /// Sensible ANSI colours for a file that only sets background and
    /// foreground, so an import is never half a theme.
    private static func defaults(background: String, foreground: String) -> [String] {
        let dark = !isLight(background)
        let base = dark
            ? ["1d1f21", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "c5c8c6"]
            : ["2d2d2d", "c82829", "718c00", "eab700", "4271ae", "8959a8", "3e999f", "d6d6d6"]
        let bright = dark
            ? ["666666", "d54e53", "b9ca4a", "e7c547", "7aa6da", "c397d8", "70c0b1", "eaeaea"]
            : ["8e908c", "f5871f", "718c00", "eab700", "4271ae", "8959a8", "3e999f", "ffffff"]
        return base + bright
    }
}
