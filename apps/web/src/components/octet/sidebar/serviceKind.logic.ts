// Port of native Octet's ServiceKind: what a listening process is, for its logo.
// T3 reports the listener's process name (not its full command line), so a
// framework is found from the name, then from well-known ports, else the runtime.

const RULES: ReadonlyArray<readonly [slug: string, words: readonly string[]]> = [
  ["nextdotjs", ["next", "next-server", "next-router-worker"]],
  ["nuxt", ["nuxt", "nuxi"]],
  ["astro", ["astro"]],
  ["remix", ["remix", "remix-serve"]],
  ["svelte", ["svelte-kit", "sveltekit"]],
  ["gatsby", ["gatsby"]],
  ["storybook", ["storybook", "start-storybook"]],
  ["angular", ["ng", "@angular"]],
  ["expo", ["expo"]],
  ["vite", ["vite"]],
  ["webpack", ["webpack", "webpack-dev-server"]],
  ["esbuild", ["esbuild"]],
  ["electron", ["electron"]],
  ["django", ["manage.py", "django", "django-admin"]],
  ["fastapi", ["fastapi", "uvicorn"]],
  ["flask", ["flask"]],
  ["streamlit", ["streamlit"]],
  ["gradio", ["gradio"]],
  ["jupyter", ["jupyter", "jupyter-lab", "jupyter-notebook", "ipykernel_launcher"]],
  ["gunicorn", ["gunicorn"]],
  ["rubyonrails", ["rails", "puma"]],
  ["laravel", ["artisan"]],
  ["phoenixframework", ["phx.server", "phoenix"]],
  ["hugo", ["hugo"]],
  ["jekyll", ["jekyll"]],
  ["ollama", ["ollama"]],
  ["supabase", ["supabase"]],
  ["prisma", ["prisma"]],
  ["redis", ["redis-server"]],
  ["postgresql", ["postgres", "postmaster"]],
  ["mysql", ["mysqld"]],
  ["mariadb", ["mariadbd"]],
  ["mongodb", ["mongod"]],
  ["elasticsearch", ["elasticsearch"]],
  ["rabbitmq", ["rabbitmq-server"]],
  ["nginx", ["nginx"]],
  ["caddy", ["caddy"]],
  ["apache", ["httpd", "apache2"]],
  [
    "docker",
    [
      "com.docker.backend",
      "com.docker.vpnkit",
      "docker-proxy",
      "vpnkit-bridge",
      "orbstack",
      "colima",
    ],
  ],
];

const RUNTIMES: ReadonlyArray<readonly [slug: string, words: readonly string[]]> = [
  ["bun", ["bun"]],
  ["deno", ["deno"]],
  ["nodedotjs", ["node", "nodejs"]],
  ["python", ["python", "python3", "pythonw"]],
  ["ruby", ["ruby"]],
  ["php", ["php", "php-fpm"]],
  ["elixir", ["beam.smp", "elixir", "mix"]],
  ["openjdk", ["java"]],
  ["dotnet", ["dotnet"]],
  ["go", ["go"]],
];

/** Ports only one thing usually listens on: databases and tools. */
const WELL_KNOWN_PORTS: Readonly<Record<number, string>> = {
  5432: "postgresql",
  3306: "mysql",
  6379: "redis",
  27017: "mongodb",
  9200: "elasticsearch",
  5672: "rabbitmq",
  11434: "ollama",
  6006: "storybook",
  8888: "jupyter",
  8501: "streamlit",
};

export const SERVICE_NAMES: Readonly<Record<string, string>> = {
  nextdotjs: "Next.js", nuxt: "Nuxt", astro: "Astro", remix: "Remix", svelte: "SvelteKit",
  gatsby: "Gatsby", storybook: "Storybook", angular: "Angular", expo: "Expo", vite: "Vite",
  webpack: "webpack", esbuild: "esbuild", electron: "Electron", django: "Django",
  fastapi: "FastAPI", flask: "Flask", streamlit: "Streamlit", gradio: "Gradio",
  jupyter: "Jupyter", gunicorn: "Gunicorn", rubyonrails: "Rails", laravel: "Laravel",
  phoenixframework: "Phoenix", hugo: "Hugo", jekyll: "Jekyll", ollama: "Ollama",
  supabase: "Supabase", prisma: "Prisma", redis: "Redis", postgresql: "PostgreSQL",
  mysql: "MySQL", mariadb: "MariaDB", mongodb: "MongoDB", elasticsearch: "Elasticsearch",
  rabbitmq: "RabbitMQ", nginx: "nginx", caddy: "Caddy", apache: "Apache", docker: "Docker",
  bun: "Bun", deno: "Deno", nodedotjs: "Node.js", python: "Python", ruby: "Ruby",
  php: "PHP", elixir: "Elixir", openjdk: "Java", dotnet: ".NET", go: "Go",
};

const SCRIPT_EXTENSIONS = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".exe"];

/** Whole words of a command line: each path segment, and each file name without its script extension. */
export function commandWords(line: string): Set<string> {
  const words = new Set<string>();
  for (const token of line.toLowerCase().split(/[ /\t=:,'"()]+/)) {
    if (!token) continue;
    words.add(token);
    for (const ext of SCRIPT_EXTENSIONS) {
      if (token.endsWith(ext)) words.add(token.slice(0, -ext.length));
    }
  }
  return words;
}

function runtimeSlug(words: Set<string>): string | null {
  for (const [slug, names] of RUNTIMES) {
    for (const name of names) {
      if (words.has(name)) return slug;
      // Versioned names too: python3.12, node22.
      for (const word of words) {
        if (word.startsWith(name) && /^[0-9.]+$/.test(word.slice(name.length))) return slug;
      }
    }
  }
  return null;
}

/** The logo slug for a listener, or null when nothing is recognised. */
export function detectServiceSlug(input: {
  readonly processName: string | null;
  readonly port: number;
}): string | null {
  const words = commandWords(input.processName ?? "");
  for (const [slug, names] of RULES) {
    if (names.some((name) => words.has(name))) return slug;
  }
  return WELL_KNOWN_PORTS[input.port] ?? runtimeSlug(words);
}
