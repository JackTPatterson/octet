#!/bin/sh
# The Terraform workspace selected in this folder.
[ -d "$OCTET_CWD/.terraform" ] || exit 0
workspace=$(cat "$OCTET_CWD/.terraform/environment" 2>/dev/null)
workspace="${TF_WORKSPACE:-${workspace:-default}}"
echo "tf $workspace"
case "$workspace" in *prod*|*prd*) echo "tone: danger" ;; esac
echo "help: Terraform workspace $workspace"
