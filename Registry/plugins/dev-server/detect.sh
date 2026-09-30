#!/bin/sh
# How this project starts its dev server, for Start Dev Server. Prints the
# command on the first line, then `label:` and `cwd:`; nothing, with a
# `message:`, when it can't tell. Looks in the folder the menu is about,
# then up to the repository's root, so a package in a monorepo starts
# itself rather than the whole repo.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
here="${OCTET_CWD:-$PWD}"
root="${OCTET_REPO_ROOT:-$here}"

# The package manager a folder's lockfile (or a parent's) belongs to.
package_manager() {
  dir=$1
  while :; do
    [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ] && { echo bun; return; }
    [ -f "$dir/pnpm-lock.yaml" ] && { echo pnpm; return; }
    [ -f "$dir/yarn.lock" ] && { echo yarn; return; }
    [ -f "$dir/package-lock.json" ] && { echo npm; return; }
    [ "$dir" = "$root" ] || [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done
  echo npm
}

# Whether package.json in $1 has script $2. Node reads it properly; without
# Node, a line like  "dev": "…"  inside the file is close enough.
has_script() {
  if command -v node >/dev/null 2>&1; then
    node -e 'const s=(require(process.argv[1]).scripts)||{};process.exit(s[process.argv[2]]?0:1)' "$1/package.json" "$2" 2>/dev/null
  else
    grep -Eq "\"$2\"[[:space:]]*:" "$1/package.json" 2>/dev/null
  fi
}

# Whether package.json in $1 depends on package $2 (dependencies or dev).
has_dependency() {
  if command -v node >/dev/null 2>&1; then
    node -e 'const p=require(process.argv[1]);const d={...p.dependencies,...p.devDependencies};process.exit(d[process.argv[2]]?0:1)' "$1/package.json" "$2" 2>/dev/null
  else
    grep -Fq "\"$2\"" "$1/package.json" 2>/dev/null
  fi
}

# The framework a package is built on, as `Name|its dev command`, most
# specific first: SvelteKit and Qwik run on Vite, so Vite comes last.
framework() {
  dir=$1
  while read -r dependency name command; do
    [ -n "$dependency" ] || continue
    if has_dependency "$dir" "$dependency"; then
      echo "$name|$command" | tr '_' ' '
      return 0
    fi
  done <<'LIST'
next Next.js next_dev
nuxt Nuxt nuxt_dev
@sveltejs/kit SvelteKit vite_dev
astro Astro astro_dev
@remix-run/dev Remix remix_vite:dev
@solidjs/start SolidStart vinxi_dev
@builder.io/qwik Qwik vite
@angular/cli Angular ng_serve
expo Expo expo_start
gatsby Gatsby gatsby_develop
@11ty/eleventy Eleventy eleventy_--serve
react-scripts Create_React_App react-scripts_start
@vue/cli-service Vue_CLI vue-cli-service_serve
webpack-dev-server webpack webpack_serve
vite Vite vite
LIST
  return 1
}

node_project() {
  dir=$1
  [ -f "$dir/package.json" ] || return 1
  pm=$(package_manager "$dir")
  found=$(framework "$dir")
  kind=${found%%|*}
  for script in dev start serve develop; do
    if has_script "$dir" "$script"; then
      case "$pm:$script" in
        npm:start) echo "npm start" ;;
        npm:*) echo "npm run $script" ;;
        *) echo "$pm $script" ;;
      esac
      echo "label: $(basename "$dir") · ${kind:-$script}"
      echo "cwd: $dir"
      return 0
    fi
  done
  # No script: the framework's own dev command, through the package manager.
  if [ -n "$found" ]; then
    case "$pm" in
      pnpm) run="pnpm exec" ;;
      yarn) run="yarn" ;;
      bun) run="bunx" ;;
      *) run="npx" ;;
    esac
    echo "$run ${found#*|}"
    echo "label: $(basename "$dir") · $kind"
    echo "cwd: $dir"
    return 0
  fi
  return 1
}

# Deno's dev task, when deno.json(c) has one.
deno_project() {
  dir=$1
  for file in deno.json deno.jsonc; do
    if [ -f "$dir/$file" ] && grep -Eq '"dev"[[:space:]]*:' "$dir/$file"; then
      echo "deno task dev"; echo "label: $(basename "$dir") · deno"; echo "cwd: $dir"
      return 0
    fi
  done
  return 1
}

# FastAPI, Flask or Streamlit, from what the project depends on and its
# usual entry file.
python_project() {
  dir=$1
  deps=$(cat "$dir/pyproject.toml" "$dir/requirements.txt" "$dir/Pipfile" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -n "$deps" ] || return 1
  python=$(python_for "$dir")
  for entry in main.py app.py app/main.py src/main.py; do
    [ -f "$dir/$entry" ] || continue
    module=$(echo "${entry%.py}" | tr '/' '.')
    case "$deps" in
      *fastapi*) echo "$python -m uvicorn $module:app --reload"; echo "label: $(basename "$dir") · FastAPI"; echo "cwd: $dir"; return 0 ;;
      *streamlit*) echo "$python -m streamlit run $entry"; echo "label: $(basename "$dir") · Streamlit"; echo "cwd: $dir"; return 0 ;;
      *flask*) echo "$python -m flask --app $module run --debug"; echo "label: $(basename "$dir") · Flask"; echo "cwd: $dir"; return 0 ;;
    esac
  done
  return 1
}

python_for() {
  for venv in .venv venv env; do
    [ -x "$1/$venv/bin/python" ] && { echo "$venv/bin/python"; return; }
  done
  echo python3
}

other_project() {
  dir=$1
  name=$(basename "$dir")
  if [ -x "$dir/bin/dev" ]; then echo "bin/dev"; echo "label: $name · bin/dev"
  elif [ -f "$dir/Gemfile" ] && [ -x "$dir/bin/rails" ]; then echo "bin/rails server"; echo "label: $name · rails"
  elif [ -f "$dir/manage.py" ]; then echo "$(python_for "$dir") manage.py runserver"; echo "label: $name · django"
  elif [ -f "$dir/mix.exs" ] && grep -q ":phoenix" "$dir/mix.exs" 2>/dev/null; then echo "mix phx.server"; echo "label: $name · phoenix"
  elif [ -f "$dir/artisan" ]; then echo "php artisan serve"; echo "label: $name · laravel"
  elif [ -f "$dir/hugo.toml" ] || [ -f "$dir/hugo.yaml" ] || { [ -f "$dir/config.toml" ] && [ -d "$dir/content" ]; }; then echo "hugo server"; echo "label: $name · hugo"
  elif [ -f "$dir/_config.yml" ] && [ -f "$dir/Gemfile" ]; then echo "bundle exec jekyll serve"; echo "label: $name · jekyll"
  elif [ -f "$dir/go.mod" ]; then echo "go run ."; echo "label: $name · go"
  elif [ -f "$dir/Cargo.toml" ]; then echo "cargo run"; echo "label: $name · cargo"
  else
    for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
      if [ -f "$dir/$file" ]; then echo "docker compose up"; echo "label: $name · compose"; echo "cwd: $dir"; return 0; fi
    done
    return 1
  fi
  echo "cwd: $dir"
}

dir=$here
while :; do
  node_project "$dir" && exit 0
  deno_project "$dir" && exit 0
  other_project "$dir" && exit 0
  python_project "$dir" && exit 0
  [ "$dir" = "$root" ] || [ "$dir" = "/" ] && break
  dir=$(dirname "$dir")
done
echo "message: No dev server found: no dev or start script, no JavaScript framework, and no Deno, Rails, Django, FastAPI, Flask, Streamlit, Phoenix, Laravel, Go, Cargo, Hugo, Jekyll or Compose project"
