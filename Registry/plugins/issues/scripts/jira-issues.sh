#!/bin/sh
# Your open Jira issues, most recently updated first, for jira issue
# view / move / assign and jira open: `KEY<TAB>summary<TAB>status`.
. "$OCTET_PLUGIN_DIR/scripts/jira-lib.sh"
jira_config || exit 0
body=$(jira_search 'assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC' 50) || exit 0
json 'd.issues.map(function(i){
  return [i.key, String(i.fields.summary).replace(/[\t\n]/g, " "), (i.fields.status || {}).name || ""].join("\t")
}).join("\n")' "$body"
