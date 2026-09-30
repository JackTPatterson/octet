#!/bin/sh
# The active gcloud configuration's project.
dir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
[ -f "$dir/active_config" ] || exit 0
name=$(cat "$dir/active_config")
project=$(awk '$1=="project"{print $3; exit}' "$dir/configurations/config_$name" 2>/dev/null)
[ -n "$project" ] || exit 0
echo "gcp $project"
case "$project" in *prod*|*prd*) echo "tone: danger" ;; esac
echo "help: gcloud configuration $name"
