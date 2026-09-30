#!/bin/sh
# Open issues assigned to you: Jira's (every project) and this GitHub
# repository's. The count on the chip, each issue on hover.
. "$OCTET_PLUGIN_DIR/scripts/jira-lib.sh"
lines=""
count=0
url=""
if jira_config; then
  body=$(jira_search 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' 30)
  if [ -n "$body" ]; then
    jira=$(json 'd.issues.map(function(i){ return i.key + "  " + String(i.fields.summary).replace(/\n/g, " ") }).join("\n")' "$body")
    if [ -n "$jira" ]; then
      lines="$jira"
      count=$(printf '%s\n' "$jira" | grep -c .)
      url="$JIRA_URL/issues/?jql=assignee%20%3D%20currentUser()%20AND%20statusCategory%20!%3D%20Done"
    fi
  fi
fi
if command -v gh >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  github=$(gh issue list --assignee @me --state open --limit 30 --json number,title --jq '.[] | "#\(.number)  \(.title | gsub("\n"; " "))"' 2>/dev/null)
  if [ -n "$github" ]; then
    lines=$(printf '%s\n%s' "$lines" "$github" | sed '/^$/d')
    count=$((count + $(printf '%s\n' "$github" | grep -c .)))
    [ -n "$url" ] || url=$(gh repo view --json url --jq '.url + "/issues/assigned/@me"' 2>/dev/null)
  fi
fi
[ "$count" -gt 0 ] || exit 0
[ "$count" -eq 1 ] && echo "1 issue" || echo "$count issues"
# Help is one line; \n breaks it on hover.
printf 'help: %s\n' "$(printf '%s' "$lines" | head -n 12 | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
[ -n "$url" ] && echo "url: $url"
