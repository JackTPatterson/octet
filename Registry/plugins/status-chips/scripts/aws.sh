#!/bin/sh
# The AWS profile commands would use, and its region.
config="$HOME/.aws/config"
[ -f "$config" ] || exit 0
profile="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}"
if [ "$profile" = "default" ]; then section="default"; else section="profile $profile"; fi
region=$(awk -v s="[$section]" '$0==s{f=1;next} /^\[/{f=0} f && $1=="region"{print $3; exit}' "$config")
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$region}}"
echo "aws $profile${region:+ · $region}"
case "$profile" in *prod*|*prd*) echo "tone: danger" ;; esac
echo "help: AWS profile $profile from $config"
