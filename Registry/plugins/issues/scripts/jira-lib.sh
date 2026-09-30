# Shared by the Jira scripts: where Jira is, who you are, and one request.
#
# Settings, first found wins:
#   ~/.config/octet/jira   JIRA_URL=https://acme.atlassian.net
#                          JIRA_EMAIL=you@acme.com        (Jira Cloud)
#                          JIRA_API_TOKEN=...             (or leave out, below)
#   jira-cli's ~/.config/.jira/.config.yml, for the server and login
#   The token in the Keychain (macOS):
#     security add-generic-password -s octet-jira -a you@acme.com -w
#   or the secret service (Linux):
#     secret-tool store --label "Octet Jira" service octet-jira
#   Jira Server / Data Center: leave JIRA_EMAIL empty and set a personal
#   access token; it goes as a bearer token.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

jira_config() {
  conf="${XDG_CONFIG_HOME:-$HOME/.config}/octet/jira"
  # shellcheck disable=SC1090
  [ -f "$conf" ] && . "$conf"
  cli="$HOME/.config/.jira/.config.yml"
  if [ -f "$cli" ]; then
    [ -n "$JIRA_URL" ] || JIRA_URL=$(sed -n 's/^server:[[:space:]]*//p' "$cli" | head -n 1 | tr -d "\"'")
    [ -n "$JIRA_EMAIL" ] || JIRA_EMAIL=$(sed -n 's/^login:[[:space:]]*//p' "$cli" | head -n 1 | tr -d "\"'")
  fi
  if [ -z "$JIRA_API_TOKEN" ]; then
    if command -v security >/dev/null 2>&1; then
      JIRA_API_TOKEN=$(security find-generic-password -s octet-jira -w 2>/dev/null)
    elif command -v secret-tool >/dev/null 2>&1; then
      JIRA_API_TOKEN=$(secret-tool lookup service octet-jira 2>/dev/null)
    fi
  fi
  if [ -z "$JIRA_API_TOKEN" ] && [ -n "$JIRA_EMAIL" ] && command -v security >/dev/null 2>&1; then
    JIRA_API_TOKEN=$(security find-generic-password -s jira-cli -a "$JIRA_EMAIL" -w 2>/dev/null)
  fi
  JIRA_URL=${JIRA_URL%/}
  [ -n "$JIRA_URL" ] && [ -n "$JIRA_API_TOKEN" ]
}

# GET a Jira REST path; the body on stdout, failing on an HTTP error. The
# credentials go to curl on stdin, never on its command line.
jira_get() {
  if [ -n "$JIRA_EMAIL" ]; then
    printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_API_TOKEN"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$JIRA_API_TOKEN"
  fi | curl -sf --max-time 8 -K - -H 'Accept: application/json' "$JIRA_URL$1"
}

# Issues matching a JQL query, as JSON: Jira Cloud's search, else the older
# one Server and Data Center have.
jira_search() {
  jql=$(printf '%s' "$1" | sed 's/ /%20/g; s/=/%3D/g; s/!/%21/g; s/(/%28/g; s/)/%29/g; s/,/%2C/g; s/"/%22/g')
  fields="fields=summary,status&maxResults=${2:-50}"
  jira_get "/rest/api/3/search/jql?jql=$jql&$fields" 2>/dev/null \
    || jira_get "/rest/api/2/search?jql=$jql&$fields"
}

# Runs a JavaScript expression over JSON: `d` is the parsed first argument,
# `a` all of them. Every Mac has osascript (not every Mac has jq); on Linux
# it takes Node.
json() {
  expression=$1
  shift
  if command -v osascript >/dev/null 2>&1; then
    osascript -l JavaScript -e "function run(a){var d=JSON.parse(a[0]);return String($expression)}" "$@" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e "var a=process.argv.slice(1);var d=JSON.parse(a[0]);console.log(String($expression))" "$@" 2>/dev/null
  fi
}
