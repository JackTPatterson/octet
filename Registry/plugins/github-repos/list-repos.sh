#!/bin/sh
# Repositories the GitHub CLI's signed-in account can clone: its own,
# collaborations and organisation repos, most recently pushed first.
# Prints `clone-url<TAB>owner/name<TAB>private|fork|` per line, or nothing
# when gh is missing or signed out.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v gh >/dev/null 2>&1 || exit 0
protocol=$(gh config get git_protocol -h github.com 2>/dev/null)
gh api 'user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member' \
  --jq ".[] | [(if \"$protocol\" == \"ssh\" then .ssh_url else .clone_url end), .full_name, (if .private then \"private\" elif .fork then \"fork\" else \"\" end)] | @tsv" 2>/dev/null
