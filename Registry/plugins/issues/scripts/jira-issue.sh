#!/bin/sh
# The Jira issue the branch is named for (ENG-142-retry, feature/eng-142):
# its key and status, its summary on hover, and a link to it.
. "$OCTET_PLUGIN_DIR/scripts/jira-lib.sh"
branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
key=$(printf '%s' "$branch" | grep -oE '[A-Za-z][A-Za-z0-9]{1,9}-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]')
[ -n "$key" ] || exit 0
# Standards that look like keys: utf-8, iso-8601, sha-256.
case "${key%%-*}" in UTF|ISO|SHA|RFC|MD|HTTP|IPV|WCAG|ES|PEP) exit 0 ;; esac
if ! jira_config; then
  echo "$key"
  echo "tone: muted"
  echo "help: Connect Jira to see this issue: put JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN in ~/.config/octet/jira"
  exit 0
fi
body=$(jira_get "/rest/api/2/issue/$key?fields=summary,status,assignee") || exit 0
json '(function(){
  var f = d.fields, s = f.status || {}, cat = (s.statusCategory || {}).key;
  var tone = cat === "done" ? "success" : cat === "new" ? "muted" : "normal";
  var who = f.assignee ? f.assignee.displayName : "Unassigned";
  return d.key + " · " + s.name + "\ntone: " + tone
    + "\nhelp: " + String(f.summary).replace(/\n/g, " ") + "\\n" + who
    + "\nurl: " + a[1] + "/browse/" + d.key;
})()' "$body" "$JIRA_URL"
