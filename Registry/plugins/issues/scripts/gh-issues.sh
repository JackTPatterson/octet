#!/bin/sh
# The repository's open issues for gh issue view / develop / close /
# comment / edit: `number<TAB>title<TAB>labels`, newest first.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v gh >/dev/null 2>&1 || exit 0
gh issue list --state open --limit 100 --json number,title,labels \
  --jq '.[] | [(.number | tostring), (.title | gsub("\t"; " ")), ([.labels[].name] | join(", "))] | @tsv' 2>/dev/null
