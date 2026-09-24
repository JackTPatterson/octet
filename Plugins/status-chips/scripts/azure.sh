#!/bin/sh
# The Azure subscription the CLI is signed in to.
command -v az >/dev/null 2>&1 || exit 0
[ -f "$HOME/.azure/azureProfile.json" ] || exit 0
name=$(az account show --query name --output tsv 2>/dev/null) || exit 0
[ -n "$name" ] || exit 0
echo "az $name"
case "$name" in *prod*|*Prod*|*PROD*) echo "tone: danger" ;; esac
echo "help: Azure subscription $name"
