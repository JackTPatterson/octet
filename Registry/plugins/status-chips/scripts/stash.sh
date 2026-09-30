#!/bin/sh
# How many stashes the repository holds.
[ -n "$OCTET_REPO_ROOT" ] || exit 0
count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
[ "${count:-0}" -gt 0 ] || exit 0
echo "$count stashed"
echo "help: $(git stash list -1 --format='Latest: %s' 2>/dev/null)"
