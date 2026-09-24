#!/bin/sh
# The SSH machine's system and uptime, asked over a fresh connection that
# never prompts (keys or an agent only).
[ -n "$OCTET_SSH_HOST" ] || exit 0
target="$OCTET_SSH_HOST"
[ -n "$OCTET_SSH_USER" ] && target="$OCTET_SSH_USER@$OCTET_SSH_HOST"
info=$(ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=yes "$target" \
  'printf "%s %s|" "$(uname -s)" "$(uname -r | cut -d- -f1)"; uptime' 2>/dev/null) || exit 0
system=${info%%|*}
up=$(echo "${info#*|}" | sed -n 's/.*up \([^,]*\),.*/\1/p' | sed 's/^ *//')
echo "$system${up:+ · up $up}"
echo "help: $(echo "${info#*|}" | sed 's/^ *//')"
