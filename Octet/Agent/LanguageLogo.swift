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

    /// The logo for a service slug from `ServiceKind`.
    init?(service: String?, size: CGFloat = 13) {
        guard let service, let entry = Self.services.first(where: { $0.slug == service })
                ?? Self.lookup[service] else { return nil }
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
        // Git's own mark, for the tab bar's Git button.
        .init("git", "F05032", ["git"]),
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

    /// The services MCP servers front, by the words their names go by
    /// (`mcp__<server>__<tool>`, where the server may be "github",
    /// "claude_ai_Linear" or "plugin_stripe_stripe"). Logos are Simple Icons.
    static let mcp: [Entry] = [
        .init("github", "181717", ["github"]),
        .init("linear", "5E6AD2", ["linear"]),
        .init("figma", "F24E1E", ["figma"]),
        .init("notion", "000000", ["notion"]),
        .init("jira", "0052CC", ["jira", "atlassian"]),
        .init("confluence", "172B4D", ["confluence"]),
        .init("stripe", "635BFF", ["stripe"]),
        .init("sentry", "362D59", ["sentry"]),
        .init("vercel", "000000", ["vercel"]),
        .init("cloudflare", "F38020", ["cloudflare"]),
        .init("googledrive", "4285F4", ["drive", "gdrive"]),
        .init("gmail", "EA4335", ["gmail"]),
        .init("googlecalendar", "4285F4", ["calendar", "gcal"]),
        .init("googlechrome", "4285F4", ["chrome", "chromedevtools", "devtools"]),
        .init("firebase", "DD2C00", ["firebase"]),
        .init("shopify", "7AB55C", ["shopify"]),
        .init("asana", "F06A6A", ["asana"]),
        .init("airtable", "18BFFF", ["airtable"]),
        .init("zapier", "FF4F00", ["zapier"]),
        .init("hubspot", "FF7A59", ["hubspot"]),
        .init("datadog", "632CA6", ["datadog"]),
        .init("grafana", "F46800", ["grafana"]),
        .init("posthog", "000000", ["posthog"]),
        .init("paypal", "002991", ["paypal"]),
        .init("puppeteer", "40B5A4", ["puppeteer"]),
        .init("tradingview", "131622", ["tradingview"]),
        .init("apple", "000000", ["apple"]),
        .init("googledocs", "4285F4", []),
        .init("googlesheets", "34A853", []),
        .init("googleslides", "FBBC04", []),
        .init("googleforms", "7248B9", []),
        .init("googlemaps", "4285F4", []),
        .init("googlecloud", "4285F4", ["gcloud", "googlecloud"]),
        .init("netlify", "00C7B7", ["netlify"]),
        .init("neon", "34D59A", ["neon"]),
        .init("planetscale", "000000", ["planetscale"]),
        .init("clickhouse", "FFCC01", ["clickhouse"]),
        .init("trello", "0052CC", ["trello"]),
        .init("clickup", "7B68EE", ["clickup"]),
        .init("bitbucket", "0052CC", ["bitbucket"]),
        .init("gitlab", "FC6D26", ["gitlab"]),
        .init("huggingface", "FFD21E", ["huggingface"]),
        .init("brave", "FB542B", ["brave"]),
        .init("duckduckgo", "DE5833", ["duckduckgo"]),
        .init("perplexity", "1FB8CD", ["perplexity"]),
        .init("kubernetes", "326CE5", ["kubernetes", "k8s"]),
        .init("google", "4285F4", ["google"]),
    ]

    /// The logo for an MCP tool call's server, or nil for one with no mark.
    init?(mcpTool name: String, size: CGFloat = 13) {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        self.init(mcpServer: parts[1], size: size)
    }

    /// The logo for an MCP server by its configured name.
    init?(mcpServer name: String, size: CGFloat = 13) {
        let words = name.lowercased().components(separatedBy: CharacterSet(charactersIn: "_-:. "))
        for word in words {
            if let entry = Self.mcp.first(where: { $0.slug == word || $0.names.contains(word) }) {
                slug = entry.slug
                hex = entry.hex
                self.size = size
                return
            }
        }
        return nil
    }

    /// Servers, frameworks and runtimes behind a listening port, for its
    /// button; a language's own logo (Python, Ruby, Go…) comes from `table`.
    static let services: [Entry] = [
        .init("nodedotjs", "5FA04E", []),
        .init("bun", "000000", []),
        .init("deno", "000000", []),
        .init("vite", "9135FF", []),
        .init("nextdotjs", "000000", []),
        .init("nuxt", "00DC82", []),
        .init("remix", "000000", []),
        .init("gatsby", "663399", []),
        .init("storybook", "FF4785", []),
        .init("angular", "DD0031", []),
        .init("expo", "1C2024", []),
        .init("webpack", "8DD6F9", []),
        .init("esbuild", "FFCF00", []),
        .init("electron", "47848F", []),
        .init("django", "092E20", []),
        .init("fastapi", "009688", []),
        .init("flask", "3BABC3", []),
        .init("streamlit", "FF4B4B", []),
        .init("gradio", "F97316", []),
        .init("jupyter", "F37626", []),
        .init("gunicorn", "499848", []),
        .init("rubyonrails", "D30001", []),
        .init("laravel", "FF2D20", []),
        .init("phoenixframework", "FD4F00", []),
        .init("hugo", "FF4088", []),
        .init("jekyll", "CC0000", []),
        .init("ollama", "000000", []),
        .init("supabase", "3FCF8E", []),
        .init("prisma", "2D3748", []),
        .init("redis", "FF4438", []),
        .init("mysql", "4479A1", []),
        .init("mariadb", "003545", []),
        .init("mongodb", "47A248", []),
        .init("elasticsearch", "005571", []),
        .init("rabbitmq", "FF6600", []),
        .init("nginx", "009639", []),
        .init("caddy", "1F88C0", []),
        .init("apache", "D22128", []),
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
