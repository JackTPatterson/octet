#!/bin/sh
# TCP ports the pane's programs are listening on, e.g. a dev server.
# Clicking the chip opens the first one.
[ -n "$OCTET_SHELL_PID" ] || exit 0
pids=""
queue="$OCTET_SHELL_PID"
while [ -n "$queue" ]; do
  next=""
  for pid in $queue; do
    children=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
    pids="$pids $children"
    next="$next $children"
  done
  queue=$(echo $next)
done
pids=$(echo $pids | tr ' ' ',')
[ -n "$pids" ] || exit 0
ports=$(lsof -a -p "$pids" -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1{n=split($9,a,":"); print a[n]}' | sort -un)
[ -n "$ports" ] || exit 0
echo "$ports" | sed 's/^/:/' | head -n 4 | tr '\n' ' ' | sed 's/ $//'
echo
echo "url: http://localhost:$(echo "$ports" | head -n 1)"
echo "help: Listening on $(echo $ports) · Click to open"
