import Foundation

/// What a pane's repository is built with, read from the files at its root,
/// so the context bar can show the toolchain version a command there would
/// run. `id` names a runtime in the Runtime Icons plugin, for its icon.
struct ProjectRuntime: Equatable {
    let id: String
    let name: String
    /// Run in a login shell at the repo root, so version managers apply.
    let versionCommand: [String]

    /// Marker files in priority order: a lockfile names the JavaScript
    /// runtime before package.json falls back to Node.
    private static let markers: [(files: [String], runtime: ProjectRuntime)] = [
        (["bun.lockb", "bun.lock", "bunfig.toml"], .init(id: "bun", name: "Bun", versionCommand: ["bun", "--version"])),
        (["deno.json", "deno.jsonc"], .init(id: "deno", name: "Deno", versionCommand: ["deno", "--version"])),
        (["package.json", ".nvmrc", ".node-version"], .init(id: "node", name: "Node", versionCommand: ["node", "--version"])),
        (["Cargo.toml"], .init(id: "rust", name: "Rust", versionCommand: ["rustc", "--version"])),
        (["go.mod"], .init(id: "go", name: "Go", versionCommand: ["go", "version"])),
        (["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", ".python-version"],
         .init(id: "python", name: "Python", versionCommand: ["python3", "--version"])),
        (["Package.swift"], .init(id: "swift", name: "Swift", versionCommand: ["swift", "--version"])),
        (["Gemfile", ".ruby-version"], .init(id: "ruby", name: "Ruby", versionCommand: ["ruby", "--version"])),
        (["mix.exs"], .init(id: "elixir", name: "Elixir", versionCommand: ["elixir", "--short-version"])),
        (["pubspec.yaml"], .init(id: "dart", name: "Dart", versionCommand: ["dart", "--version"])),
        (["build.zig"], .init(id: "zig", name: "Zig", versionCommand: ["zig", "version"])),
        (["composer.json"], .init(id: "php", name: "PHP", versionCommand: ["php", "--version"])),
    ]

    /// The runtime for the nearest marker between `directory` and `root`,
    /// so a Node package inside a Rust repo reads as Node.
    static func detect(from directory: String, root: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> ProjectRuntime? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let top = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        while url.path.hasPrefix(top) {
            for marker in markers where marker.files.contains(where: { exists(url.appendingPathComponent($0).path) }) {
                return marker.runtime
            }
            if url.path == top || url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The first version number in a tool's output: `v25.6.1` from node,
    /// `3.12.4` from "Python 3.12.4", `1.83.0` from "rustc 1.83.0 (…)", and
    /// `1.23.2` from "go version go1.23.2 darwin/arm64". Swift leads with
    /// its driver's version, so its own is read after "Swift version".
    static func version(fromOutput output: String) -> String? {
        let text = output.range(of: "Swift version ").map { output[$0.upperBound...] } ?? output[...]
        guard let range = text.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
