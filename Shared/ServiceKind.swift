import Foundation

/// What a listening process is, for its logo: the framework or server it
/// runs (Vite, Next.js, Django, Postgres…), else its runtime (Node,
/// Python…). The result is a `LanguageLogo` service slug.
enum ServiceKind {
    /// Frameworks and servers, first match wins: a framework before the
    /// runtime it runs on. Each name must be a whole word of the command
    /// line (a path segment, or a file name without its extension).
    static let rules: [(slug: String, words: [String])] = [
        ("nextdotjs", ["next", "next-server", "next-router-worker"]),
        ("nuxt", ["nuxt", "nuxi"]),
        ("astro", ["astro"]),
        ("remix", ["remix", "remix-serve"]),
        ("svelte", ["svelte-kit", "sveltekit"]),
        ("gatsby", ["gatsby"]),
        ("storybook", ["storybook", "start-storybook"]),
        ("angular", ["ng", "@angular"]),
        ("expo", ["expo"]),
        ("vite", ["vite"]),
        ("webpack", ["webpack", "webpack-dev-server"]),
        ("esbuild", ["esbuild"]),
        ("electron", ["electron"]),
        ("django", ["manage.py", "django", "django-admin"]),
        ("fastapi", ["fastapi", "uvicorn"]),
        ("flask", ["flask"]),
        ("streamlit", ["streamlit"]),
        ("gradio", ["gradio"]),
        ("jupyter", ["jupyter", "jupyter-lab", "jupyter-notebook", "ipykernel_launcher"]),
        ("gunicorn", ["gunicorn"]),
        ("rubyonrails", ["rails", "puma"]),
        ("laravel", ["artisan"]),
        ("phoenixframework", ["phx.server", "phoenix"]),
        ("hugo", ["hugo"]),
        ("jekyll", ["jekyll"]),
        ("ollama", ["ollama"]),
        ("supabase", ["supabase"]),
        ("prisma", ["prisma"]),
        ("redis", ["redis-server"]),
        ("postgresql", ["postgres", "postmaster"]),
        ("mysql", ["mysqld"]),
        ("mariadb", ["mariadbd"]),
        ("mongodb", ["mongod"]),
        ("elasticsearch", ["elasticsearch"]),
        ("rabbitmq", ["rabbitmq-server"]),
        ("nginx", ["nginx"]),
        ("caddy", ["caddy"]),
        ("apache", ["httpd", "apache2"]),
        ("docker", ["com.docker.backend", "com.docker.vpnkit", "docker-proxy", "vpnkit-bridge", "orbstack", "colima"]),
    ]

    /// Runtimes, when nothing more specific shows.
    static let runtimes: [(slug: String, words: [String])] = [
        ("bun", ["bun"]),
        ("deno", ["deno"]),
        ("nodedotjs", ["node", "nodejs"]),
        ("python", ["python", "python3", "pythonw"]),
        ("ruby", ["ruby"]),
        ("php", ["php", "php-fpm"]),
        ("elixir", ["beam.smp", "elixir", "mix"]),
        ("openjdk", ["java"]),
        ("dotnet", ["dotnet"]),
        ("go", ["go"]),
    ]

    /// A framework found on this process or up to a few of its parents (a
    /// dev server's worker is often a plain `node` under the `next` or
    /// `vite` process), else the listener's own runtime.
    static func detect(pid: Int, command: String, processes: [Int: String], parents: [Int: Int]) -> String? {
        var current = pid
        var runtimeSlug: String?
        for step in 0..<4 {
            let words = Self.words((step == 0 ? command + " " : "") + (processes[current] ?? ""))
            if let rule = rules.first(where: { $0.words.contains(where: words.contains) }) { return rule.slug }
            if step == 0 { runtimeSlug = runtime(words) }
            guard let parent = parents[current], parent > 1, parent != current else { break }
            current = parent
        }
        return runtimeSlug
    }

    private static func runtime(_ words: Set<String>) -> String? {
        // Versioned names too: python3.12, node22.
        runtimes.first { rule in
            rule.words.contains { word in words.contains(word) || words.contains { $0.hasPrefix(word) && $0.dropFirst(word.count).allSatisfy { $0.isNumber || $0 == "." } } }
        }?.slug
    }

    /// Whole words of a command line: each path segment, and each file
    /// name without its script extension.
    static func words(_ line: String) -> Set<String> {
        var result: Set<String> = []
        for token in line.lowercased().split(whereSeparator: { " /\t=:,'\"()".contains($0) }) {
            let word = String(token)
            result.insert(word)
            for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".exe"] where word.hasSuffix(ext) {
                result.insert(String(word.dropLast(ext.count)))
            }
        }
        return result
    }

    /// A slug's display name, for help text.
    static func name(_ slug: String) -> String {
        names[slug] ?? slug.prefix(1).uppercased() + slug.dropFirst()
    }

    static let names: [String: String] = [
        "nextdotjs": "Next.js", "nuxt": "Nuxt", "astro": "Astro", "remix": "Remix", "svelte": "SvelteKit",
        "gatsby": "Gatsby", "storybook": "Storybook", "angular": "Angular", "expo": "Expo", "vite": "Vite",
        "webpack": "webpack", "esbuild": "esbuild", "electron": "Electron", "django": "Django",
        "fastapi": "FastAPI", "flask": "Flask", "streamlit": "Streamlit", "gradio": "Gradio",
        "jupyter": "Jupyter", "gunicorn": "Gunicorn", "rubyonrails": "Rails", "laravel": "Laravel",
        "phoenixframework": "Phoenix", "hugo": "Hugo", "jekyll": "Jekyll", "ollama": "Ollama",
        "supabase": "Supabase", "prisma": "Prisma", "redis": "Redis", "postgresql": "PostgreSQL",
        "mysql": "MySQL", "mariadb": "MariaDB", "mongodb": "MongoDB", "elasticsearch": "Elasticsearch",
        "rabbitmq": "RabbitMQ", "nginx": "nginx", "caddy": "Caddy", "apache": "Apache", "docker": "Docker",
        "bun": "Bun", "deno": "Deno", "nodedotjs": "Node.js", "python": "Python", "ruby": "Ruby",
        "php": "PHP", "elixir": "Elixir", "openjdk": "Java", "dotnet": ".NET", "go": "Go",
    ]

    /// `ps -axo pid=,ppid=,args=` output as pid → command line.
    static func parseArguments(_ text: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]) else { continue }
            result[pid] = fields[2].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
