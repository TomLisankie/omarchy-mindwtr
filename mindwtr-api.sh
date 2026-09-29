#!/usr/bin/env bash
# Mindwtr Cloud API client for the Omarchy bar plugin.
#
# Reads the server URL and bearer token from the first source that has them:
#   1. MINDWTR_CLOUD_URL / MINDWTR_CLOUD_TOKEN environment variables
#   2. ~/.config/omarchy/mindwtr.json  ({"baseUrl": "...", "token": "...",
#      "label": "Mindwtr Cloud", "insecureSkipVerify": false,
#      "allowInsecureHttp": false})
#
# Every subcommand prints a single JSON object on stdout and exits 0 for
# expected failures, so the QML side only ever has to parse JSON. The token and
# any request body are handed to curl through a config stream on stdin, never on
# a command line, and plain http:// is refused for non-loopback hosts unless the
# user opts in.
#
# Subcommands:
#   summary            Fetch tasks + projects and emit grouped buckets
#   capture            Read the task text from stdin; POST it to the Inbox
#   complete <id>      Mark a task done (POST /v1/tasks/:id/complete)
#   task <id>          Fetch one task's full details (GET /v1/tasks/:id)
#   ping               Verify URL + token with a tiny request

set -uo pipefail

CONFIG_FILE="${MINDWTR_CONFIG:-$HOME/.config/omarchy/mindwtr.json}"
TIMEOUT="${MINDWTR_TIMEOUT:-8}"
PAGE_LIMIT="${MINDWTR_PAGE_LIMIT:-200}"
MAX_TASKS="${MINDWTR_MAX_TASKS:-1000}"
# Hard byte cap per HTTP response so a hostile or broken server cannot make the
# long-lived shell buffer an unbounded body.
MAX_RESPONSE_BYTES="${MINDWTR_MAX_RESPONSE_BYTES:-16777216}"

base_url="${MINDWTR_CLOUD_URL:-}"
token="${MINDWTR_CLOUD_TOKEN:-}"
insecure=""
allow_insecure_http="${MINDWTR_ALLOW_INSECURE_HTTP:-}"
display_label="${MINDWTR_LABEL:-}"

if [[ -r $CONFIG_FILE ]]; then
  cfg_url=$(jq -r '.baseUrl // .url // empty' "$CONFIG_FILE" 2>/dev/null)
  cfg_token=$(jq -r '.token // empty' "$CONFIG_FILE" 2>/dev/null)
  cfg_insecure=$(jq -r 'if .insecureSkipVerify == true then "1" else "" end' "$CONFIG_FILE" 2>/dev/null)
  cfg_insecure_http=$(jq -r 'if .allowInsecureHttp == true then "1" else "" end' "$CONFIG_FILE" 2>/dev/null)
  cfg_label=$(jq -r '.label // empty' "$CONFIG_FILE" 2>/dev/null)
  [[ -z $base_url ]] && base_url="$cfg_url"
  [[ -z $token ]] && token="$cfg_token"
  [[ -n $cfg_insecure ]] && insecure="1"
  [[ -n $cfg_insecure_http ]] && allow_insecure_http="1"
  [[ -z $display_label ]] && display_label="$cfg_label"
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
# Friendly display name for the bar/panel; falls back to the host.
server_display="${display_label:-$server_host}"

# Refuse to put the bearer token on the wire in cleartext to a remote host.
# Loopback stays allowed for local test servers; anything else needs an explicit
# opt-in via allowInsecureHttp / MINDWTR_ALLOW_INSECURE_HTTP.
#
# The host is parsed properly rather than by string prefix: `127.example.com`
# is a remote name, not loopback, and userinfo (`http://user@host`) is rejected
# outright so it cannot smuggle a loopback-looking authority in front of a
# remote host.
scheme="${base_url%%://*}"
authority="${base_url#*://}"
authority="${authority%%/*}"
if [[ $authority == *@* ]]; then
  emit_error "invalid_url"
fi
if [[ $authority == \[* ]]; then
  host_only="${authority%%]*}"
  host_only="${host_only#[}"
else
  host_only="${authority%%:*}"
fi

is_loopback_host() {
  local host="$1"
  [[ $host == localhost ]] && return 0
  [[ $host == ::1 || $host == 0:0:0:0:0:0:0:1 ]] && return 0
  [[ $host == 0.0.0.0 ]] && return 0
  local -a octets
  IFS='.' read -r -a octets <<<"$host"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  (( 10#${octets[0]} == 127 )) && return 0
  return 1
}

if [[ $scheme == http ]] && ! is_loopback_host "$host_only" && [[ -z $allow_insecure_http ]]; then
  emit_error "insecure_http"
fi

resp_body=""
resp_code=""

# Escape a value for a curl config file: backslashes and quotes are escaped so
# curl hands back the original bytes, and raw newlines are dropped because curl's
# config parser would turn them into line breaks mid-value.
config_value() {
  local value="${1//$'\\'/\\\\}"
  local nl=$'\n' cr=$'\r'
  value="${value//\"/\\\"}"
  value="${value//$nl/}"
  value="${value//$cr/}"
  printf '%s' "$value"
}

# Emit the curl config read from stdin: the Authorization header, plus the
# Content-Type header and request body for writes. Keeping the body in this
# stream instead of an argv element means task text never shows up in the
# command line that `ps` or /proc/<pid>/cmdline exposes.
curl_config() {
  local data="${1:-}"
  printf 'header = "Authorization: Bearer %s"\n' "$(config_value "$token")"
  if [[ -n $data ]]; then
    printf 'header = "Content-Type: application/json"\n'
    printf 'data-binary = "%s"\n' "$(config_value "$data")"
  fi
}

request() { # method path [json-data]
  local method="$1" path="$2" data="${3:-}"
  local -a args=(-sS --max-time "$TIMEOUT" --max-filesize "$MAX_RESPONSE_BYTES"
    -X "$method"
    -H "Accept: application/json"
    -w $'\n%{http_code}')
  [[ -n $insecure ]] && args+=(-k)
  local out
  out=$(curl_config "$data" | curl --config - "${args[@]}" "$base_url$path" 2>/dev/null)
  resp_code="${out##*$'\n'}"
  resp_body="${out%$'\n'*}"
  # A 2xx that did not yield a JSON body means the transfer was truncated (for
  # example by --max-filesize) or the server sent something else. Surface it as
  # an error instead of parsing an empty body into a bogus empty result.
  if [[ $resp_code == 2?? ]] && ! jq -e . >/dev/null 2>&1 <<<"$resp_body"; then
    resp_code="bad_response"
    resp_body=""
  fi
}

http_error() { # code -> stable error token
  case "${1:-}" in
    000 | "") echo "unreachable" ;;
    401 | 403) echo "unauthorized" ;;
    bad_response) echo "bad_response" ;;
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
    --arg server "$server_display" \
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
  # The task text arrives on stdin, never as an argument, so private quick-capture
  # content stays out of the process command line. One line is enough because the
  # panel's capture field is single-line; trailing CR is tolerated.
  local text=""
  IFS= read -r text || true
  text="${text%$'\r'}"
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

cmd_task() {
  local id="${1:-}"
  [[ -n $id ]] || emit_error "missing_id"
  request GET "/v1/tasks/$id"
  case $resp_code in
    200) ;;
    404) emit_error "not_found" ;;
    *) emit_error "$(http_error "$resp_code")" ;;
  esac

  # Keep the task response; the project lookup below reuses resp_body.
  local response="$resp_body"

  # Resolve the project title for display; failure here just leaves it blank.
  local projects='[]'
  request GET "/v1/projects?limit=500"
  [[ $resp_code == 200 ]] && projects=$(jq -c '.projects // []' <<<"$resp_body" 2>/dev/null)

  local task
  task=$(jq -c '.task // {}' <<<"$response" 2>/dev/null)

  jq -cn \
    --argjson task "$task" \
    --argjson projects "$projects" \
    '
    ($projects | map({ (.id): .title }) | add // {}) as $pm
    | {
        ok: true,
        task: {
          id: ($task.id // ""),
          title: ($task.title // ""),
          status: ($task.status // ""),
          dueDate: ($task.dueDate // ""),
          startTime: ($task.startTime // ""),
          reviewAt: ($task.reviewAt // ""),
          priority: ($task.priority // ""),
          energyLevel: ($task.energyLevel // ""),
          timeEstimate: (if ($task.timeEstimate // "") | type == "string" then $task.timeEstimate else "" end),
          timeSpentMinutes: ($task.timeSpentMinutes // 0),
          contexts: ($task.contexts // []),
          tags: ($task.tags // []),
          project: (if ($task.projectId // "") == "" then "" else ($pm[$task.projectId] // "") end),
          assignedTo: ($task.assignedTo // ""),
          location: ($task.location // ""),
          description: ($task.description // ""),
          focused: ($task.isFocusedToday == true),
          completedAt: ($task.completedAt // ""),
          checklist: [ ($task.checklist // [])[]? | { id: (.id // ""), title: (.title // ""), done: (.isCompleted == true) } ],
          attachments: [ ($task.attachments // [])[]? | select(.deletedAt == null) | { kind: (.kind // ""), title: (.title // ""), uri: (.uri // "") } ]
        }
      }
    '
}

cmd_ping() {
  request GET "/v1/tasks?limit=1"
  case $resp_code in
    200) jq -cn --arg server "$server_display" '{ok:true,server:$server}' ;;
    *) emit_error "$(http_error "$resp_code")" ;;
  esac
}

case "${1:-summary}" in
  summary) cmd_summary ;;
  capture) cmd_capture "${2:-}" ;;
  complete) cmd_complete "${2:-}" ;;
  task) cmd_task "${2:-}" ;;
  ping) cmd_ping ;;
  *) emit_error "unknown_command" ;;
esac
