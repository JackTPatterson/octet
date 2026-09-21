// Built-in solid-color terminal themes (no image or gradient themes).

/// A terminal color theme: background, foreground, accent, and the 16 ANSI colors.
struct TerminalTheme: Identifiable, Equatable, Codable {
    let name: String
    let background: String
    let foreground: String
    let accent: String
    let ansi: [String]
    let isLight: Bool

    var id: String { name }

    /// A theme read from the user's own terminal config, when they asked
    /// Octet to follow it. Set once at launch and on import.
    nonisolated(unsafe) static var imported: TerminalTheme?

    static func named(_ name: String) -> TerminalTheme {
        if let imported, imported.name == name { return imported }
        return all.first { $0.name == name } ?? all[0]
    }

    /// Everything selectable: the imported one first, since it is the user's.
    static var selectable: [TerminalTheme] {
        imported.map { [$0] + all } ?? all
    }

    static let all: [TerminalTheme] = [
        TerminalTheme(name: "Dark", background: "050505", foreground: "ffffff", accent: "19aad8", ansi: [
            "616161", "ff8272", "b4fa72", "fefdc2", "a5d5fe", "ff8ffd", "d0d1fe", "f1f1f1",
            "8e8e8e", "ffc4bd", "d6fcb9", "fefdd5", "c1e3fe", "ffb1fe", "e5e6fe", "feffff",
        ], isLight: false),
        TerminalTheme(name: "Light", background: "ffffff", foreground: "111111", accent: "00c2ff", ansi: [
            "212121", "c30771", "10a778", "a89c14", "008ec4", "523c79", "20a5ba", "e0e0e0",
            "212121", "fb007a", "5fd7af", "f3e430", "20bbfc", "6855de", "4fb8cc", "f1f1f1",
        ], isLight: true),
        TerminalTheme(name: "Dracula", background: "282a36", foreground: "f8f8f2", accent: "ff79c6", ansi: [
            "000000", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "bbbbbb",
            "555555", "ff5555", "50fa7b", "f1fa8c", "caa9fa", "ff79c6", "8be9fd", "ffffff",
        ], isLight: false),
        TerminalTheme(name: "Solarized Light", background: "fdf6e3", foreground: "586e75", accent: "66b5a9", ansi: [
            "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
        ], isLight: true),
        TerminalTheme(name: "Solarized Dark", background: "002b36", foreground: "f8f8f2", accent: "cb4b16", ansi: [
            "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
        ], isLight: false),
        TerminalTheme(name: "Gruvbox Dark", background: "282828", foreground: "ebdbb2", accent: "fc802d", ansi: [
            "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
            "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
        ], isLight: false),
        TerminalTheme(name: "Gruvbox Light", background: "fbf1c7", foreground: "3c3836", accent: "ad3b14", ansi: [
            "fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
            "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836",
        ], isLight: true),
        TerminalTheme(name: "Phenomenon", background: "121212", foreground: "faf9f6", accent: "2e5d9e", ansi: [
            "121212", "d22d1e", "1ca05a", "e5a01a", "3780e9", "bf409d", "799c92", "faf9f6",
            "292929", "ae756f", "789b88", "bd9f65", "6f839f", "a57899", "bfc5c3", "ffffff",
        ], isLight: false),
        TerminalTheme(name: "Solar Flare", background: "1b1c18", foreground: "dde6ee", accent: "34895c", ansi: [
            "2e333d", "d66060", "64af86", "caa358", "5c80b2", "b766a1", "8069a1", "f0f4f7",
            "37404a", "eb8282", "64af86", "caa358", "5c80b2", "b766a1", "8069a1", "ffffff",
        ], isLight: false),
        TerminalTheme(name: "Adeberry", background: "1d2022", foreground: "e4eef5", accent: "6c96b4", ansi: [
            "121212", "c76156", "57c78a", "c8a35a", "5785c7", "c756a9", "57c7c3", "eeedeb",
            "292929", "d22d1e", "1ca05a", "e5a01a", "1458b8", "a43787", "4d9989", "ffffff",
        ], isLight: false),
    ]
}
