#!/bin/sh
# Commits ahead of and behind the branch's upstream: "↑2 ↓5".
[ -n "$OCTET_REPO_ROOT" ] || exit 0
counts=$(git rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null) || exit 0
behind=${counts%%	*}
ahead=${counts##*	}
out=""
[ "$ahead" -gt 0 ] 2>/dev/null && out="↑$ahead"
[ "$behind" -gt 0 ] 2>/dev/null && out="${out:+$out }↓$behind"
[ -n "$out" ] || exit 0
echo "$out"
upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
echo "help: $ahead ahead, $behind behind $upstream"
[ "$behind" -gt 0 ] 2>/dev/null && echo "tone: warning"
exit 0
