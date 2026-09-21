import SwiftUI

/// A language's real logo in its brand color, for code blocks and the
/// files agents touch. Logos are Simple Icons (CC0); see
/// scripts/import-language-logos.py.
struct LanguageLogo: View {
    let slug: String
    let hex: String
    var size: CGFloat = 13

    /// The logo for a code block's language tag or a file's extension.
    init?(language: String?, size: CGFloat = 13) {
        guard let key = language?.lowercased(), let entry = Self.lookup[key] else { return nil }
        slug = entry.slug
        hex = entry.hex
        self.size = size
    }

    init?(path: String?, size: CGFloat = 13) {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        self.init(language: Self.fileNames[name] ?? (ext.isEmpty ? nil : ext), size: size)
    }

    var body: some View {
        // Brand colors that vanish on the theme (Rust, JSON and Markdown are
        // black) move toward the text color until they read.
        let palette = Theme.palette
        let color = ThemePalette.readable(hex, on: palette.background, toward: palette.textPrimary, minimum: 3)
        Image("Languages/" + slug)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Color(hex: color))
            .accessibilityHidden(true)
    }

    struct Entry {
        let slug: String
        let hex: String
        let names: [String]
        init(_ slug: String, _ hex: String, _ names: [String]) {
            self.slug = slug
            self.hex = hex
            self.names = names
        }
    }

    /// Slug, brand color (from Simple Icons), and the language tags and file
    /// extensions that mean it.
    static let table: [Entry] = [
        .init("typescript", "3178C6", ["typescript", "ts", "tsx", "mts", "cts"]),
        .init("javascript", "F7DF1E", ["javascript", "js", "jsx", "mjs", "cjs", "node"]),
        .init("python", "3776AB", ["python", "py", "pyi", "python3"]),
        .init("swift", "F05138", ["swift"]),
        .init("rust", "000000", ["rust", "rs"]),
        .init("go", "00ADD8", ["go", "golang"]),
        .init("ruby", "CC342D", ["ruby", "rb", "erb", "gemspec"]),
        .init("php", "777BB4", ["php"]),
        .init("openjdk", "000000", ["java"]),
        .init("kotlin", "7F52FF", ["kotlin", "kt", "kts"]),
        .init("c", "A8B9CC", ["c", "h"]),
        .init("cplusplus", "00599C", ["cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx"]),
        .init("dotnet", "512BD4", ["csharp", "cs", "c#", "fsharp", "fs", "vb"]),
        .init("html5", "E34F26", ["html", "htm", "xhtml"]),
        .init("css", "663399", ["css", "scss", "sass", "less"]),
        .init("json", "000000", ["json", "jsonc", "json5", "jsonl"]),
        .init("yaml", "CB171E", ["yaml", "yml"]),
        .init("toml", "9C4121", ["toml"]),
        .init("xml", "005FAD", ["xml", "plist", "xib", "storyboard", "svg"]),
        .init("markdown", "000000", ["markdown", "md", "mdx"]),
        .init("gnubash", "4EAA25", ["bash", "sh", "shell", "zsh", "console", "fish", "ksh"]),
        .init("postgresql", "4169E1", ["sql", "postgres", "postgresql", "psql", "pgsql"]),
        .init("sqlite", "003B57", ["sqlite", "db"]),
        .init("docker", "2496ED", ["docker", "dockerfile"]),
        .init("react", "61DAFB", ["react"]),
        .init("vuedotjs", "4FC08D", ["vue"]),
        .init("svelte", "FF3E00", ["svelte"]),
        .init("astro", "BC52EE", ["astro"]),
        .init("dart", "0175C2", ["dart"]),
        .init("lua", "000080", ["lua"]),
        .init("elixir", "4B275F", ["elixir", "ex", "exs"]),
        .init("haskell", "5D4F85", ["haskell", "hs"]),
        .init("scala", "DC322F", ["scala", "sc"]),
        .init("zig", "F7A41D", ["zig"]),
        .init("nixos", "5277C3", ["nix"]),
        .init("graphql", "E10098", ["graphql", "gql"]),
        .init("terraform", "844FBA", ["terraform", "tf", "hcl"]),
        .init("r", "276DC3", ["r"]),
        .init("perl", "0073A1", ["perl", "pl", "pm"]),
        .init("clojure", "5881D8", ["clojure", "clj", "cljs", "edn"]),
        .init("ocaml", "EC6813", ["ocaml", "ml", "mli"]),
        .init("julia", "9558B2", ["julia", "jl"]),
        .init("solidity", "363636", ["solidity", "sol"]),
        .init("latex", "008080", ["latex", "tex"]),
    ]

    /// Files known by name rather than extension.
    static let fileNames: [String: String] = [
        "dockerfile": "docker", "makefile": "bash", "gemfile": "ruby", "rakefile": "ruby",
        "package.json": "json", "cargo.toml": "toml", "go.mod": "go", "podfile": "ruby",
    ]

    private static let lookup: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in table { for name in entry.names { map[name] = entry } }
        return map
    }()
}
