#!/bin/sh
# The GitHub issue the branch is named for (123-fix-login, fix/123-login,
# issue-123, gh-123): its number and state, its title on hover, a link.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v gh >/dev/null 2>&1 || exit 0
branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
number=$(printf '%s' "$branch" | grep -oE '(^|/)(issues?-|gh-)?[0-9]+([-_]|$)' | head -n 1 | grep -oE '[0-9]+' | head -n 1)
[ -n "$number" ] || exit 0
gh issue view "$number" --json number,title,state,url,assignees --jq '
  "#\(.number) · \(.state | ascii_downcase)",
  "tone: \(if .state == "OPEN" then "normal" else "success" end)",
  "help: \(.title | gsub("\n"; " "))\\n\(if (.assignees | length) > 0 then ([.assignees[].login] | join(", ")) else "Unassigned" end)",
  "url: \(.url)"' 2>/dev/null
