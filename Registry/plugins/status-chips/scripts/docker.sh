#!/bin/sh
# Docker's context, and how many of this project's compose services run.
command -v docker >/dev/null 2>&1 || exit 0
context=$(docker context show 2>/dev/null) || exit 0
out="$context"
top="${OCTET_REPO_ROOT:-$OCTET_CWD}"
for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
  if [ -f "$top/$file" ]; then
    running=$(cd "$top" && docker compose ps --quiet --status running 2>/dev/null | wc -l | tr -d ' ')
    out="$out · ${running:-0} up"
    break
  fi
done
echo "$out"
echo "help: Docker context $context"
