#!/usr/bin/env python3
"""Builds Plugins/dev-runtimes: the bundled Octet plugin that marks a tab with
the framework, runtime or language running in it. Icons and brand colours
come from Simple Icons (CC0 1.0, simpleicons.org).

Usage: scripts/build-runtimes-plugin.py <extracted simple-icons package dir>
  (npm pack simple-icons && tar xzf simple-icons-*.tgz gives ./package)

Rules are tried in order and the first match wins, so frameworks come before
the runtimes they run on, and runtimes before plain languages. Patterns see
each process's arguments with paths cut to their last component, so
`node /app/node_modules/.bin/vite --port 3` reads `node vite --port 3`.
"""
import json, os, shutil, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
package = sys.argv[1] if len(sys.argv) > 1 else "package"
out = os.path.join(root, "Plugins/dev-runtimes")


def word(text):
    """`text` as whole words anywhere in the command."""
    return rf"(^| ){text}( |$)"


def first(text):
    """`text` as the executable (optionally versioned, like python3.12)."""
    return rf"^{text}( |$)"


# (id, name, simple-icons slug, patterns, refinements by package dependency)
RULES = [
    # Web frameworks and their dev servers.
    ("next", "Next.js", "nextdotjs", [word(r"next (dev|start|build|lint)"), r"^next-server", r"^next-router-worker"], None),
    ("nuxt", "Nuxt", "nuxt", [word(r"nuxi? (dev|start|build|preview|generate)")], None),
    ("remix", "Remix", "remix", [word(r"remix (dev|vite:dev|vite:build)")], None),
    ("reactrouter", "React Router", "reactrouter", [word(r"react-router (dev|build)")], None),
    ("astro", "Astro", "astro", [word(r"astro (dev|preview|build)")], None),
    ("gatsby", "Gatsby", "gatsby", [word(r"gatsby (develop|serve|build)")], None),
    ("expo", "Expo", "expo", [word(r"expo (start|run:ios|run:android|export)"), word(r"expo-cli")], None),
    ("reactnative", "React Native", "react", [word(r"react-native (start|run-ios|run-android)")], None),
    ("angular", "Angular", "angular", [word(r"ng (serve|build|test)"), word(r"@angular/cli")], None),
    ("sveltekit", "SvelteKit", "svelte", [word(r"svelte-kit (dev|build|preview)")], None),
    ("storybook", "Storybook", "storybook", [word(r"storybook (dev|start|build)"), word(r"start-storybook")], None),
    ("docusaurus", "Docusaurus", "docusaurus", [word(r"docusaurus (start|serve|build)")], None),
    ("react", "React", "react", [word(r"react-scripts (start|build|test)")], None),
    ("vue", "Vue", "vuedotjs", [word(r"vue-cli-service (serve|build)")], None),
    ("solid", "SolidStart", "solid", [word(r"solid-start (dev|start)"), word(r"vinxi (dev|start)")], None),
    ("qwik", "Qwik", "qwik", [word(r"qwik (build|serve)")], None),
    # Reached through Vite, when the project depends on Svelte.
    ("svelte", "Svelte", "svelte", [r"(?!)"], None),
    ("vite", "Vite", "vite", [word(r"vite"), word(r"vite (dev|serve|build|preview)")],
     [["@sveltejs/kit", "sveltekit"], ["svelte", "svelte"], ["@builder.io/qwik", "qwik"], ["solid-js", "solid"],
      ["@react-router/dev", "reactrouter"], ["@remix-run/dev", "remix"], ["nuxt", "nuxt"], ["vue", "vue"],
      ["react", "react"]]),
    ("webpack", "webpack", "webpack", [word(r"webpack(-dev-server)?"), word(r"webpack (serve|watch)")], None),
    ("turborepo", "Turborepo", "turborepo", [word(r"turbo (run|dev|build|watch)")], None),
    ("electron", "Electron", "electron", [first(r"electron"), word(r"electron-forge (start|make)")], None),
    ("tauri", "Tauri", "tauri", [word(r"tauri (dev|build)")], None),
    ("nestjs", "NestJS", "nestjs", [word(r"nest (start|build)")], None),
    ("vitest", "Vitest", "vitest", [word(r"vitest")], None),
    ("jest", "Jest", "jest", [word(r"jest")], None),
    ("mocha", "Mocha", "mocha", [word(r"mocha")], None),
    ("cypress", "Cypress", "cypress", [word(r"cypress (run|open)")], None),
    ("nodemon", "nodemon", "nodemon", [word(r"nodemon")], None),
    ("hugo", "Hugo", "hugo", [first(r"hugo"), word(r"hugo (server|serve)")], None),
    ("jekyll", "Jekyll", "jekyll", [word(r"jekyll (serve|build)")], None),
    ("eleventy", "Eleventy", "eleventy", [word(r"(eleventy|@11ty/eleventy)")], None),
    # Server frameworks in other languages.
    ("django", "Django", "django", [word(r"manage\.py (runserver|test|shell|migrate)"), word(r"django-admin")], None),
    ("fastapi", "FastAPI", "fastapi", [word(r"fastapi (dev|run)"), word(r"uvicorn")], None),
    ("flask", "Flask", "flask", [word(r"flask (run|shell)"), word(r"-m flask")], None),
    ("streamlit", "Streamlit", "streamlit", [word(r"streamlit run")], None),
    ("gradio", "Gradio", "gradio", [word(r"gradio")], None),
    ("jupyter", "Jupyter", "jupyter", [word(r"jupyter(-lab|-notebook|-server)?"), word(r"jupyter (lab|notebook)")], None),
    ("gunicorn", "Gunicorn", "gunicorn", [word(r"gunicorn")], None),
    ("rails", "Rails", "rubyonrails", [word(r"rails (s|server|c|console|test)"), word(r"puma")], None),
    ("laravel", "Laravel", "laravel", [word(r"artisan (serve|tinker|queue:work)")], None),
    ("phoenix", "Phoenix", "phoenixframework", [word(r"mix phx\.server")], None),
    ("springboot", "Spring Boot", "springboot", [word(r"(bootRun|spring-boot:run)")], None),
    ("flutter", "Flutter", "flutter", [first(r"flutter")], None),
    # Services and platform CLIs.
    ("docker", "Docker", "docker", [word(r"docker (run|compose|build)"), first(r"docker-compose")], None),
    ("kubernetes", "Kubernetes", "kubernetes", [word(r"kubectl (port-forward|logs|exec|apply)"), first(r"(k9s|minikube|kind)")], None),
    ("wrangler", "Cloudflare Workers", "cloudflare", [word(r"wrangler (dev|deploy|tail)")], None),
    ("vercel", "Vercel", "vercel", [word(r"vercel (dev|deploy)")], None),
    ("netlify", "Netlify", "netlify", [word(r"netlify (dev|deploy)")], None),
    ("firebase", "Firebase", "firebase", [word(r"firebase (emulators:start|serve|deploy)")], None),
    ("supabase", "Supabase", "supabase", [word(r"supabase (start|functions serve|db)")], None),
    ("prisma", "Prisma", "prisma", [word(r"prisma (studio|migrate|db|generate)")], None),
    ("ollama", "Ollama", "ollama", [first(r"ollama")], None),
    ("redis", "Redis", "redis", [first(r"redis-(server|cli)")], None),
    ("postgresql", "PostgreSQL", "postgresql", [first(r"(postgres|psql|pg_ctl)")], None),
    ("mysql", "MySQL", "mysql", [first(r"mysqld?")], None),
    ("mongodb", "MongoDB", "mongodb", [first(r"(mongod|mongos|mongosh)")], None),
    ("sqlite", "SQLite", "sqlite", [first(r"sqlite3?")], None),
    ("nginx", "nginx", "nginx", [first(r"nginx")], None),
    ("terraform", "Terraform", "terraform", [first(r"(terraform|tofu)")], None),
    ("ansible", "Ansible", "ansible", [first(r"ansible(-playbook)?")], None),
    # Runtimes.
    ("bun", "Bun", "bun", [first(r"bunx?")], None),
    ("deno", "Deno", "deno", [first(r"deno")], None),
    ("typescript", "TypeScript", "typescript",
     [first(r"(tsx|ts-node|ts-node-esm|ts-node-dev|tsc)"), r"^node .*\.(ts|mts|cts)( |$)"], None),
    ("node", "Node.js", "nodedotjs", [first(r"node(js)?"), first(r"npx")], None),
    # Languages, by interpreter, compiler or build tool.
    ("python", "Python", "python",
     [first(r"python[0-9.]*"), first(r"(ipython|pytest|uv|uvx|poetry|pipenv|pdm|hatch|rye|pip[0-9.]*)")], None),
    ("rust", "Rust", "rust", [first(r"(cargo|rustc|rustup|cargo-watch|bacon)")], None),
    ("go", "Go", "go", [first(r"go"), first(r"(air|gopls-run|goreleaser)")], None),
    ("ruby", "Ruby", "ruby", [first(r"(ruby|irb|rake|rspec|bundle|bundler|pry)")], None),
    ("gradle", "Gradle", "gradle", [first(r"gradlew?")], None),
    ("maven", "Maven", "apachemaven", [first(r"mvnw?")], None),
    ("kotlin", "Kotlin", "kotlin", [first(r"(kotlin|kotlinc|kotlinc-jvm)")], None),
    ("scala", "Scala", "scala", [first(r"(scala|scala-cli|sbt|amm|mill)")], None),
    ("groovy", "Groovy", "apachegroovy", [first(r"groovy")], None),
    ("clojure", "Clojure", "clojure", [first(r"(clj|clojure|lein|bb)")], None),
    ("java", "Java", "openjdk", [first(r"(java|javac|jshell|jbang)")], None),
    ("php", "PHP", "php", [first(r"(php|composer|phpunit)")], None),
    ("dotnet", ".NET", "dotnet", [first(r"(dotnet|dotnet-script|csi|fsi)")], None),
    ("elixir", "Elixir", "elixir", [first(r"(elixir|iex|mix)")], None),
    ("erlang", "Erlang", "erlang", [first(r"(erl|rebar3|escript)")], None),
    ("gleam", "Gleam", "gleam", [first(r"gleam")], None),
    ("swift", "Swift", "swift", [first(r"(swift|swiftc|swift-frontend)")], None),
    ("dart", "Dart", "dart", [first(r"dart")], None),
    ("zig", "Zig", "zig", [first(r"zig")], None),
    ("haskell", "Haskell", "haskell", [first(r"(ghc|ghci|runghc|stack|cabal)")], None),
    ("ocaml", "OCaml", "ocaml", [first(r"(ocaml|ocamlfind|dune|utop|opam)")], None),
    ("reason", "Reason", "reason", [first(r"(refmt|rescript)")], None),
    ("purescript", "PureScript", "purescript", [first(r"(purs|spago)")], None),
    ("elm", "Elm", "elm", [first(r"(elm|elm-live|elm-land)")], None),
    ("racket", "Racket", "racket", [first(r"(racket|raco)")], None),
    ("commonlisp", "Common Lisp", "commonlisp", [first(r"(sbcl|clisp|ecl|ccl)")], None),
    ("lua", "Lua", "lua", [first(r"(lua|luajit|lua5\.[0-9])")], None),
    ("perl", "Perl", "perl", [first(r"perl[0-9.]*")], None),
    ("r", "R", "r", [first(r"(R|Rscript)")], None),
    ("julia", "Julia", "julia", [first(r"julia")], None),
    ("nim", "Nim", "nim", [first(r"(nim|nimble)")], None),
    ("crystal", "Crystal", "crystal", [first(r"(crystal|shards)")], None),
    ("v", "V", "v", [first(r"v")], None),
    ("d", "D", "d", [first(r"(dmd|ldc2|rdmd|dub)")], None),
    ("odin", "Odin", "odin", [first(r"odin")], None),
    ("ada", "Ada", "ada", [first(r"(gnat|gprbuild|alr)")], None),
    ("fortran", "Fortran", "fortran", [first(r"(gfortran|ifort|fpm)")], None),
    ("solidity", "Solidity", "solidity", [first(r"(solc|forge|anvil|hardhat)")], None),
    ("webassembly", "WebAssembly", "webassembly", [first(r"(wasmtime|wasmer|wasm-pack)")], None),
    ("cmake", "CMake", "cmake", [first(r"(cmake|ctest)")], None),
    ("cplusplus", "C++", "cplusplus", [first(r"(g\+\+|clang\+\+|c\+\+)")], None),
    ("c", "C", "c", [first(r"(gcc|clang|cc)")], None),
    ("gnubash", "Shell script", "gnubash", [r"^(bash|zsh|sh|dash) [^-][^ ]*\.(sh|bash|zsh)( |$)"], None),
]

IGNORE = [
    # Editors and pagers start language servers and helpers of their own.
    "vim", "nvim", "vi", "view", "emacs", "emacsclient", "nano", "micro", "hx", "helix", "kak", "less", "more",
    "man", "code", "cursor", "zed", "subl",
    # Remote and multiplexed sessions run someone else's processes.
    "ssh", "mosh", "tmux", "screen", "zellij",
    # Agents: their tabs show the agent's own mark, and their MCP servers
    # would otherwise read as Python or Node.
    "claude", "codex", "opencode", "gemini", "aider", "cursor-agent", "amp", "goose", "crush", "droid", "kiro",
    "qwen", "pi", "copilot", "cline", "kilo", "devin", "grok",
]

hexes = json.loads(subprocess.check_output([
    "node", "-e",
    "const si=require(process.argv[1]);const o={};for(const k in si){o[si[k].slug]=si[k].hex};"
    "process.stdout.write(JSON.stringify(o))",
    os.path.abspath(package),
]))

shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "icons"))
runtimes = []
for rule_id, name, slug, patterns, refine in RULES:
    shutil.copy(os.path.join(package, "icons", slug + ".svg"), os.path.join(out, "icons", slug + ".svg"))
    entry = {"id": rule_id, "name": name, "icon": f"icons/{slug}.svg", "color": hexes[slug], "match": patterns}
    if refine:
        entry["refineByDependency"] = refine
    runtimes.append(entry)

manifest = {
    "id": "dev-runtimes",
    "name": "Runtime Icons",
    "version": "1.0.0",
    "description": "Marks a tab with what's running in it: dev servers like Next, Vite and Expo, "
                   "runtimes like Node, Bun and Deno, and languages like Python, Rust, TypeScript and Go.",
    "author": "Octet",
    "octet": 1,
    "contributes": {"runtimes": runtimes, "runtimeIgnore": IGNORE},
}
with open(os.path.join(out, "plugin.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
with open(os.path.join(out, "ICONS.md"), "w") as f:
    f.write("Icons are from Simple Icons (https://simpleicons.org), released under CC0 1.0.\n"
            "They are trademarks of their respective owners; see Simple Icons' DISCLAIMER.md.\n")
print(f"{len(runtimes)} runtimes -> {out}")
