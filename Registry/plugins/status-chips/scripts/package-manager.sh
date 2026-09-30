#!/bin/sh
# The package manager a project's lockfile belongs to, from the pane's
# folder up to the repository root.
dir="$OCTET_CWD"
top="${OCTET_REPO_ROOT:-$OCTET_CWD}"
while :; do
  for pair in pnpm-lock.yaml:pnpm yarn.lock:yarn bun.lockb:bun bun.lock:bun package-lock.json:npm \
              uv.lock:uv poetry.lock:poetry Pipfile.lock:pipenv Cargo.lock:cargo Gemfile.lock:bundler \
              composer.lock:composer go.sum:go; do
    file=${pair%%:*}
    if [ -e "$dir/$file" ]; then
      echo "${pair##*:}"
      echo "help: $dir/$file"
      exit 0
    fi
  done
  [ "$dir" = "$top" ] || [ "$dir" = "/" ] && exit 0
  dir=$(dirname "$dir")
done
