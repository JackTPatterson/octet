#!/bin/sh
# CPU and memory used by what the pane is running, shown while it's busy.
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
ps -o %cpu=,rss= -p "$pids" 2>/dev/null | awk '
  { cpu += $1; mem += $2 }
  END {
    if (cpu < 1 && mem < 51200) exit
    if (mem >= 1048576) m = sprintf("%.1f GB", mem / 1048576); else m = sprintf("%d MB", mem / 1024)
    printf "%d%% · %s\n", cpu, m
    if (cpu >= 90) print "tone: warning"
    print "help: CPU and memory of the programs running in this pane"
  }'
