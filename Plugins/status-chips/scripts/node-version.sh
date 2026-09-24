#!/bin/sh
# Warns when the Node version the project asks for (.nvmrc, .node-version)
# isn't the one that runs here. Silent when they agree.
dir="$OCTET_CWD"
top="${OCTET_REPO_ROOT:-$OCTET_CWD}"
wanted=""
while :; do
  for file in .nvmrc .node-version; do
    if [ -f "$dir/$file" ]; then wanted=$(head -n 1 "$dir/$file" | tr -d ' v\r'); break 2; fi
  done
  [ "$dir" = "$top" ] || [ "$dir" = "/" ] && break
  dir=$(dirname "$dir")
done
[ -n "$wanted" ] || exit 0
case "$wanted" in lts*|node|stable|latest) exit 0 ;; esac
command -v node >/dev/null 2>&1 || { echo "wants v$wanted"; echo "tone: warning"; echo "help: node isn't on PATH"; exit 0; }
have=$(node --version 2>/dev/null | tr -d 'v')
case "$have" in "$wanted"|"$wanted".*) exit 0 ;; esac
echo "wants v$wanted · has v$have"
echo "tone: warning"
echo "help: The project asks for Node $wanted; run nvm use or fnm use"
