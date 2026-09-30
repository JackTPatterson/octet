#!/bin/sh
# The current Kubernetes context and namespace; red when it looks like
# production.
command -v kubectl >/dev/null 2>&1 || exit 0
context=$(kubectl config current-context 2>/dev/null) || exit 0
[ -n "$context" ] || exit 0
namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
echo "$context${namespace:+/$namespace}"
case "$context" in *prod*|*prd*|*live*) echo "tone: danger" ;; esac
echo "help: kubectl context $context, namespace ${namespace:-default}"
