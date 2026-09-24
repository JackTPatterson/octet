#!/bin/sh
# How long ago the last commit was, with its subject on hover.
[ -n "$OCTET_REPO_ROOT" ] || exit 0
when=$(git log -1 --format='%cr' 2>/dev/null) || exit 0
[ -n "$when" ] || exit 0
echo "$when" | sed -e 's/ ago$//' -e 's/ seconds\{0,1\}/s/' -e 's/ minutes\{0,1\}/m/' -e 's/ hours\{0,1\}/h/' -e 's/ days\{0,1\}/d/' -e 's/ weeks\{0,1\}/w/' -e 's/ months\{0,1\}/mo/' -e 's/ years\{0,1\}/y/' -e 's/$/ ago/'
echo "help: $(git log -1 --format='%h %s — %an' 2>/dev/null)"
