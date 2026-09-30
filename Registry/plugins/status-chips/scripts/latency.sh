#!/bin/sh
# Round-trip time to the SSH machine; amber when it's slow.
[ -n "$OCTET_SSH_HOST" ] || exit 0
host=$(ssh -G "$OCTET_SSH_HOST" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
# A two-second wait: -t on macOS, -W on Linux (where -t is the hop limit).
case "$(uname -s)" in Darwin) wait="-t 2" ;; *) wait="-W 2" ;; esac
# shellcheck disable=SC2086
ms=$(ping -c 1 $wait "${host:-$OCTET_SSH_HOST}" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
[ -n "$ms" ] || { echo "no ping"; echo "tone: muted"; echo "help: ${host:-$OCTET_SSH_HOST} doesn't answer ping"; exit 0; }
rounded=$(printf '%.0f' "$ms")
echo "$rounded ms"
[ "$rounded" -ge 150 ] && echo "tone: warning"
echo "help: Round trip to ${host:-$OCTET_SSH_HOST}"
