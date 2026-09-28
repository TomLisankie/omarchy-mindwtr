#!/usr/bin/env bash
# Mindwtr Cloud API client for the Omarchy bar plugin.
#
# Reads the server URL and bearer token from the first source that has them:
#   1. MINDWTR_CLOUD_URL / MINDWTR_CLOUD_TOKEN environment variables
#   2. ~/.config/omarchy/mindwtr.json  ({"baseUrl": "...", "token": "...",
#      "insecureSkipVerify": false})
#
# Every subcommand prints a single JSON object on stdout and exits 0 for
# expected failures, so the QML side only ever has to parse JSON. The token is
# never written to a command line or a log; only curl argv holds the header.
#
# Subcommands:
#   summary            Fetch tasks + projects and emit grouped buckets
#   capture <text>     Quick-add a task to the Inbox (POST /v1/tasks)
#   complete <id>      Mark a task done (POST /v1/tasks/:id/complete)
#   ping               Verify URL + token with a tiny request

set -uo pipefail

CONFIG_FILE="${MINDWTR_CONFIG:-$HOME/.config/omarchy/mindwtr.json}"
TIMEOUT="${MINDWTR_TIMEOUT:-8}"
PAGE_LIMIT="${MINDWTR_PAGE_LIMIT:-200}"
MAX_TASKS="${MINDWTR_MAX_TASKS:-1000}"

base_url="${MINDWTR_CLOUD_URL:-}"
token="${MINDWTR_CLOUD_TOKEN:-}"
insecure=""

if [[ -r $CONFIG_FILE ]]; then
  cfg_url=$(jq -r '.baseUrl // .url // empty' "$CONFIG_FILE" 2>/dev/null)
  cfg_token=$(jq -r '.token // empty' "$CONFIG_FILE" 2>/dev/null)
  cfg_insecure=$(jq -r 'if .insecureSkipVerify == true then "1" else "" end' "$CONFIG_FILE" 2>/dev/null)
  [[ -z $base_url ]] && base_url="$cfg_url"
  [[ -z $token ]] && token="$cfg_token"
  [[ -n $cfg_insecure ]] && insecure="1"
fi

emit_error() { jq -cn --arg e "$1" '{ok:false,error:$e}'; exit 0; }

[[ -n $base_url ]] || emit_error "no_server_url"
[[ -n $token ]] || emit_error "no_token"

# Trim a trailing slash so paths concatenate cleanly.
base_url="${base_url%/}"
# Accept a bare host too ("mindwtr.example.com"), defaulting to https.
[[ $base_url == http://* || $base_url == https://* ]] || base_url="https://$base_url"

server_host="${base_url#*://}"
server_host="${server_host%%/*}"

resp_body=""
resp_code=""

request() { # method path [json-data]
  local method="$1" path="$2" data="${3:-}"
  local -a args=(-sS --max-time "$TIMEOUT" -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/json"
    -w $'\n%{http_code}')
  [[ -n $insecure ]] && args+=(-k)
  if [[ -n $data ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "$data")
  fi
  local out
  out=$(curl "${args[@]}" "$base_url$path" 2>/dev/null)
  resp_code="${out##*$'\n'}"
  resp_body="${out%$'\n'*}"
}

http_error() { # code -> stable error token
  case "${1:-}" in
    000 | "") echo "unreachable" ;;
    401 | 403) echo "unauthorized" ;;
    *) echo "http_${1:-000}" ;;
  esac
}

cmd_summary() {
  local tmp
  tmp=$(mktemp -d) || emit_error "tmpdir"
  trap 'rm -rf "${tmp:-}"' EXIT
  : > "$tmp/tasks.ndjson"
  : > "$tmp/projects.ndjson"

  # Projects give task rows a human title instead of a bare id.
  request GET "/v1/projects?limit=500"
  if [[ $resp_code == 200 ]]; then
    jq -c '.projects[]?' <<<"$resp_body" >> "$tmp/projects.ndjson" 2>/dev/null
  fi

  # Tasks: the default list already excludes completed/archived. Page through
  # while the server reports more than we have fetched.
  local offset=0 total=0 page_count=0
  while :; do
    request GET "/v1/tasks?limit=$PAGE_LIMIT&offset=$offset"
    if [[ $resp_code != 200 ]]; then
      if (( offset == 0 )); then
        emit_error "$(http_error "$resp_code")"
      fi
      break
    fi
    jq -c '.tasks[]?' <<<"$resp_body" >> "$tmp/tasks.ndjson" 2>/dev/null
    total=$(jq -r '.total // 0' <<<"$resp_body" 2>/dev/null)
    page_count=$(jq -r '(.tasks // []) | length' <<<"$resp_body" 2>/dev/null)
    offset=$(( offset + PAGE_LIMIT ))
    [[ ${page_count:-0} -eq 0 ]] && break
    (( offset >= ${total:-0} )) && break
    (( offset >= MAX_TASKS )) && break
  done

  jq -cn \
    --slurpfile tasks "$tmp/tasks.ndjson" \
    --slurpfile projects "$tmp/projects.ndjson" \
    --arg server "$server_host" \
    --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" \
    '
    ($projects | map({ (.id): .title }) | add // {}) as $pm
    | def norm:
        {
          id: (.id // ""),
          title: (.title // ""),
          status: (.status // ""),
          dueDate: (.dueDate // ""),
          startTime: (.startTime // ""),
          contexts: (.contexts // []),
          tags: (.tags // []),
          priority: (.priority // ""),
          project: (if (.projectId // "") == "" then "" else ($pm[.projectId] // "") end),
          focused: (.isFocusedToday == true)
        };
    ($tasks | map(norm)) as $t
    | ($t | map(select(.focused == true))) as $focus
    | ($t | map(select(.status == "inbox"))) as $inbox
    | ($t | map(select(.status == "next"))) as $next
    | ($t | map(select(.status == "waiting"))) as $waiting
    | ($t | map(select(.status == "someday"))) as $someday
    | {
        ok: true,
        server: $server,
        fetchedAt: $fetchedAt,
        total: ($t | length),
        counts: {
          focus: ($focus | length),
          inbox: ($inbox | length),
          next: ($next | length),
          waiting: ($waiting | length),
          someday: ($someday | length)
        },
        focus: $focus,
        inbox: $inbox,
        next: $next,
        waiting: $waiting,
        someday: $someday
      }
    '
}

cmd_capture() {
  local text="${1:-}"
  [[ -n ${text//[[:space:]]/} ]] || emit_error "empty"
  local payload
  payload=$(jq -cn --arg t "$text" '{ input: $t }')
  request POST "/v1/tasks" "$payload"
  case $resp_code in
    200 | 201) jq -cn '{ok:true}' ;;
    *) emit_error "$(http_error "$resp_code")" ;;
  esac
}

cmd_complete() {
  local id="${1:-}"
  [[ -n $id ]] || emit_error "missing_id"
  request POST "/v1/tasks/$id/complete"
  case $resp_code in
    200 | 201) jq -cn '{ok:true}' ;;
    *) emit_error "$(http_error "$resp_code")" ;;
  esac
}

cmd_ping() {
  request GET "/v1/tasks?limit=1"
  case $resp_code in
    200) jq -cn --arg server "$server_host" '{ok:true,server:$server}' ;;
    *) emit_error "$(http_error "$resp_code")" ;;
  esac
}

case "${1:-summary}" in
  summary) cmd_summary ;;
  capture) cmd_capture "${2:-}" ;;
  complete) cmd_complete "${2:-}" ;;
  ping) cmd_ping ;;
  *) emit_error "unknown_command" ;;
esac
