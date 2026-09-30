# Windows twin of list-repos.sh: repositories the GitHub CLI's signed-in
# account can clone, most recently pushed first, as
# `clone-url<TAB>owner/name<TAB>private|fork|`, or nothing without gh.
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { exit 0 }
$protocol = gh config get git_protocol -h github.com 2>$null
$url = if ($protocol -eq 'ssh') { '.ssh_url' } else { '.clone_url' }
gh api 'user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member' `
  --jq ".[] | [$url, .full_name, (if .private then `"private`" elif .fork then `"fork`" else `"`" end)] | @tsv" 2>$null
