#!/usr/bin/env bash
# Brokk Observe hook for Claude Code.
#
# Forwards every hook event to a Brokk Observe server. Design goals:
#   * Never slow Claude down: events are written to a local spool (no network)
#     and flushed in the background. Git is only consulted on session
#     boundaries.
#   * Never lose events: the spool survives crashes, offline laptops and
#     server outages, and is flushed in order on the next event.
#   * Never change Claude's behaviour unless policy enforcement is on: the
#     script prints nothing and exits 0. With enforcement on, PreToolUse asks
#     the server synchronously and prints its allow/ask/deny decision.
#   * Portable: bash 3.2 (macOS), curl and git. No jq, python or node.
#
# Usage (from hooks.json):  observe-hook.sh <HookEventName>   (event JSON on stdin)
# Maintenance:              observe-hook.sh --status | --flush | --session [id]
# Register this machine:    observe-hook.sh --register [email] [server-url]   (mails you a link)

set -u
PLUGIN_VERSION="0.3.1"
ARG="${1:-}"

# ----------------------------------------------------------------------------
# Configuration: env OBSERVE_* (e.g. from managed settings) >
# config file (~/.config/brokk-observe/config, KEY=VALUE lines).
# ----------------------------------------------------------------------------
CONF_FILE="${OBSERVE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/brokk-observe/config}"
CF_OBSERVE_URL="" CF_OBSERVE_TOKEN="" CF_OBSERVE_ENFORCE="" CF_OBSERVE_TRANSCRIPTS="" CF_OBSERVE_GITHUB_LOGIN="" CF_OBSERVE_AGENT_NAME="" CF_OBSERVE_FAIL_CLOSED=""
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      OBSERVE_URL|OBSERVE_TOKEN|OBSERVE_ENFORCE|OBSERVE_TRANSCRIPTS|OBSERVE_GITHUB_LOGIN|OBSERVE_AGENT_NAME|OBSERVE_FAIL_CLOSED)
        eval "CF_$k=\$v" ;;  # k is from the fixed allowlist above; v is assigned, never evaluated
    esac
  done < "$CONF_FILE"
fi

URL="${OBSERVE_URL:-$CF_OBSERVE_URL}"
URL="${URL%/}"
TOKEN="${OBSERVE_TOKEN:-$CF_OBSERVE_TOKEN}"
ENFORCE="${OBSERVE_ENFORCE:-${CF_OBSERVE_ENFORCE:-false}}"
TRANSCRIPTS="${OBSERVE_TRANSCRIPTS:-${CF_OBSERVE_TRANSCRIPTS:-true}}"
GH_LOGIN="${OBSERVE_GITHUB_LOGIN:-$CF_OBSERVE_GITHUB_LOGIN}"
AGENT_NAME="${OBSERVE_AGENT_NAME:-$CF_OBSERVE_AGENT_NAME}"
FAIL_CLOSED="${OBSERVE_FAIL_CLOSED:-${CF_OBSERVE_FAIL_CLOSED:-false}}"
TIMEOUT="${OBSERVE_TIMEOUT:-3}"

DATA="${OBSERVE_DATA_DIR:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/brokk-observe}}"
SPOOL="$DATA/spool"
STATE="$DATA/state"
LOCK="$DATA/flush.lock"
mkdir -p "$SPOOL" "$STATE" 2>/dev/null

is_true() { case "$1" in 1|true|TRUE|True|yes|on) return 0 ;; *) return 1 ;; esac; }

# Unix time in milliseconds, always 13 digits. Not `date +%s%3N`: some `date`
# implementations do not zero-pad it, which turns 12:00:00.091 into
# 12:00:00.911 and puts events out of order.
now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then            # bash 5+: no fork
    t=${EPOCHREALTIME/[.,]/}
    printf '%s' "${t:0:13}"
    return
  fi
  t=$(date +%s%N 2>/dev/null)                      # GNU date: 19 digits
  case "$t" in
    ''|*[!0-9]*) t="" ;;
  esac
  if [ ${#t} -eq 19 ]; then
    printf '%s' "${t:0:13}"
  elif t=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null) && [ ${#t} -eq 13 ]; then
    printf '%s' "$t"                               # macOS: bash 3.2, BSD date
  else
    printf '%s000' "$(date +%s)"
  fi
}

# JSON string escaping for values we generate (payload JSON is passed through untouched).
esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  s=${s//$'\n'/\\n}
  printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
}

# First string value for a key in the payload. Nested occurrences inside JSON
# strings are escaped (\"key\") and therefore never match.
json_str() {
  printf '%s' "$PAYLOAD" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 \
    | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's/\\\\/\\/g'
}

spool_list() { local f; for f in "$SPOOL"/*.json; do [ -e "$f" ] && printf '%s\n' "${f##*/}"; done; }
spool_count() { spool_list | wc -l | tr -d ' '; }

curl_post() { # $1=path $2=content-type $3=data-file ; prints HTTP code
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: $2" \
    --data-binary @"$3" "$URL$1" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Spool flushing (single flusher at a time via an mkdir lock).
# ----------------------------------------------------------------------------
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then return 0; fi
  # Break a stale lock left by a killed flusher.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null && return 0
  fi
  return 1
}

flush() { # $1 = seconds to wait for a busy flusher (default 0)
  [ -n "$URL" ] && [ -n "$TOKEN" ] || return 0
  local waited=0
  until acquire_lock; do
    [ "$waited" -lt "$(( ${1:-0} * 5 ))" ] || return 0
    sleep 0.2; waited=$((waited + 1))
  done
  local list="$DATA/.flush-list.$$" batch="$DATA/.flush-batch.$$" rounds=0 code n
  while [ $rounds -lt 40 ]; do
    rounds=$((rounds + 1))
    spool_list | sort | head -n 50 > "$list"
    n=$(wc -l < "$list" | tr -d ' ')
    [ "$n" -gt 0 ] || break
    : > "$batch"
    while IFS= read -r f; do cat "$SPOOL/$f" >> "$batch" 2>/dev/null; done < "$list"
    # A long flush must not look like a dead one to the stale-lock check.
    touch "$LOCK" 2>/dev/null
    code=$(curl_post /api/v1/ingest/batch application/x-ndjson "$batch")
    case "$code" in
      2*) while IFS= read -r f; do rm -f "$SPOOL/$f"; done < "$list"; rm -f "$STATE/last_error" ;;
      # Remembered so the user can be told: `000` is "could not connect".
      *) printf '%s %s' "$code" "$(date +%s)" > "$STATE/last_error" 2>/dev/null; break ;;
    esac
  done
  rm -f "$list" "$batch"
  rmdir "$LOCK" 2>/dev/null
  return 0
}

# Upload new transcript lines (server redacts and de-duplicates by line number).
upload_transcript() {
  is_true "$TRANSCRIPTS" || return 0
  local sid=$1 tp=$2 off_file off total chunk n code
  [ -n "$sid" ] && [ -f "$tp" ] || return 0
  off_file="$STATE/$sid.tlines"
  off=$(cat "$off_file" 2>/dev/null || echo 0)
  total=$(wc -l < "$tp" | tr -d ' ')
  chunk="$STATE/.tchunk.$$"
  local lines=400
  while [ "$off" -lt "$total" ]; do
    tail -n "+$((off + 1))" "$tp" | head -n "$lines" > "$chunk"
    n=$(wc -l < "$chunk" | tr -d ' ')
    [ "$n" -gt 0 ] || break
    code=$(curl_post "/api/v1/ingest/transcript?session_id=$sid&start_line=$off" application/x-ndjson "$chunk")
    case "$code" in
      2*) off=$((off + n)); printf '%s' "$off" > "$off_file" ;;
      413)
        # Too big for the server. Send less at a time; a single line that is
        # still too big is skipped, or it would block every line after it.
        if [ "$lines" -gt 1 ]; then lines=$(( lines / 8 > 0 ? lines / 8 : 1 ))
        else off=$((off + 1)); printf '%s' "$off" > "$off_file"; fi ;;
      *) break ;;
    esac
  done
  rm -f "$chunk"
}

# ----------------------------------------------------------------------------
# Maintenance commands (used by the plugin's slash commands).
# ----------------------------------------------------------------------------
mask() { local t=$1; [ ${#t} -gt 14 ] && printf '%s…' "${t:0:14}" || printf '%s' "${t:+set}"; }

case "$ARG" in
  --register)
    OBSERVE_URL="${3:-$URL}" exec bash "$(dirname "$0")/register.sh" "${2:-}" ;;
  --status)
    echo "Brokk Observe plugin $PLUGIN_VERSION"
    echo "  server:        ${URL:-NOT CONFIGURED (run observe-hook.sh --register you@company.com https://your-server)}"
    echo "  ingest token:  $( [ -n "$TOKEN" ] && mask "$TOKEN" || echo 'NOT CONFIGURED (run observe-hook.sh --register)')"
    echo "  enforcement:   $(is_true "$ENFORCE" && echo "on (fail-$(is_true "$FAIL_CLOSED" && echo closed || echo open))" || echo off)"
    echo "  transcripts:   $(is_true "$TRANSCRIPTS" && echo upload || echo off)"
    echo "  data dir:      $DATA"
    echo "  spooled events: $(spool_count)"
    if [ -f "$STATE/last_error" ]; then
      read -r err_code err_at < "$STATE/last_error"
      case "$err_code" in
        000) why="could not reach the server" ;;
        401|403) why="the server rejected the ingest token (HTTP $err_code)" ;;
        *) why="the server answered HTTP $err_code" ;;
      esac
      echo "  last delivery:  FAILED, $why ($(( ($(date +%s) - ${err_at:-0}) / 60 )) min ago)"
    fi
    if [ -n "$URL" ] && [ -n "$TOKEN" ]; then
      resp=$(curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" "$URL/api/v1/ingest/ping" -w ' HTTP_%{http_code}' 2>&1)
      echo "  server check:  $resp"
    fi
    exit 0 ;;
  --flush)
    before=$(spool_count)
    flush 10
    after=$(spool_count)
    echo "Flushed $((before - after)) event(s); $after still spooled."
    exit 0 ;;
  --session)
    sid="${2:-$(cat "$STATE/last_session" 2>/dev/null)}"
    [ -n "$sid" ] || { echo "No session recorded yet."; exit 0; }
    flush 5
    curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" "$URL/api/v1/ingest/sessions/$sid/summary" 2>&1
    echo
    exit 0 ;;
esac

# ----------------------------------------------------------------------------
# Hook event path.
# ----------------------------------------------------------------------------
PAYLOAD=$(tr -d '\r\n')
[ -n "$PAYLOAD" ] || exit 0
if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  # Fail-closed means "no policy answer, no tool call". A plugin with no
  # server configured can never get an answer.
  if [ "$ARG" = PreToolUse ] && is_true "$ENFORCE" && is_true "$FAIL_CLOSED"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Brokk Observe is not configured (no server URL or token) and fail-closed mode is enabled."}}'
  fi
  exit 0
fi

TS=$(now_ms)
EVENT="${ARG:-$(json_str hook_event_name)}"
SID=$(json_str session_id)
CWD=$(json_str cwd)
[ -d "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -n "$SID" ] && printf '%s' "$SID" > "$STATE/last_session" 2>/dev/null

RUNTIME=local
if [ "${GITHUB_ACTIONS:-}" = true ] || [ -n "${CI:-}" ] || [ -n "${BUILDKITE:-}" ] || [ -n "${GITLAB_CI:-}" ]; then RUNTIME=ci
elif [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then RUNTIME=cloud; fi

# Identity is resolved once per session and cached.
IDENT="$STATE/$SID.ident"
if [ "$EVENT" = SessionStart ] || [ ! -f "$IDENT" ]; then
  email="${OBSERVE_USER_EMAIL:-$(git -C "$CWD" config user.email 2>/dev/null)}"
  name="$(git -C "$CWD" config user.name 2>/dev/null)"
  login="$GH_LOGIN"
  if [ -z "$login" ] && [ -f "$DATA/gh_login" ]; then login=$(cat "$DATA/gh_login"); fi
  host="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-}")"
  os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  ident="\"user_email\":\"$(esc "$email")\",\"user_name\":\"$(esc "$name")\",\"hostname\":\"$(esc "$host")\",\"os\":\"$(esc "$os")\""
  [ -n "$login" ] && ident="$ident,\"github_login\":\"$(esc "$login")\""
  [ -n "$SID" ] && printf '%s' "$ident" > "$IDENT"
else
  ident=$(cat "$IDENT")
fi

# The event id makes delivery idempotent: it is fixed here, travels in the
# spool file, and lets the server recognise an event it has already stored
# when a batch has to be sent again.
EVENT_ID="$TS-$$-$RANDOM$RANDOM"
META="{\"event_id\":\"$EVENT_ID\",\"ts\":$TS,\"plugin_version\":\"$PLUGIN_VERSION\",\"runtime\":\"$RUNTIME\",$ident"
[ -n "$AGENT_NAME" ] && META="$META,\"agent_name\":\"$(esc "$AGENT_NAME")\""

# Git context on session boundaries only (keeps tool-call hooks fast).
case "$EVENT" in
  SessionStart|Stop|SessionEnd|SubagentStop|PreCompact)
    if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      remote=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#')
      branch=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
      head=$(git -C "$CWD" rev-parse HEAD 2>/dev/null)
      META="$META,\"git\":{\"remote\":\"$(esc "$remote")\",\"branch\":\"$(esc "$branch")\",\"head\":\"$(esc "$head")\"}"
      HEAD0="$STATE/$SID.head0"
      if [ -n "$head" ] && [ ! -f "$HEAD0" ]; then printf '%s' "$head" > "$HEAD0"; fi
      if [ "$EVENT" = Stop ] || [ "$EVENT" = SessionEnd ]; then
        base=$(cat "$HEAD0" 2>/dev/null)
        if [ -n "$base" ] && [ -n "$head" ] && [ "$base" != "$head" ]; then
          author=$(git -C "$CWD" config user.email 2>/dev/null)
          commits=""
          while IFS=$'\x1f' read -r c_sha c_email c_name c_ts c_subject; do
            [ -n "$c_sha" ] || continue
            [ -n "$commits" ] && commits="$commits,"
            commits="$commits{\"sha\":\"$c_sha\",\"email\":\"$(esc "$c_email")\",\"name\":\"$(esc "$c_name")\",\"ts\":${c_ts:-0},\"subject\":\"$(esc "$c_subject")\"}"
          done <<EOF
$(git -C "$CWD" log --no-merges -n 50 ${author:+--author="$author"} --format='%H%x1f%ae%x1f%an%x1f%ct%x1f%s' "$base..HEAD" 2>/dev/null)
EOF
          [ -n "$commits" ] && META="$META,\"commits\":[$commits]"
        fi
      fi
    fi ;;
esac
META="$META}"
ENVELOPE="{\"v\":1,\"meta\":$META,\"event\":$PAYLOAD}"

spool_write() {
  local f="$SPOOL/$TS-$$-$RANDOM"
  printf '%s\n' "$ENVELOPE" > "$f.tmp" && mv "$f.tmp" "$f.json"
}

# --- Enforcement: synchronous policy decision for PreToolUse -----------------
if [ "$EVENT" = PreToolUse ] && is_true "$ENFORCE"; then
  out=$(printf '%s' "$ENVELOPE" | curl -sS --max-time "$TIMEOUT" -X POST \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        --data-binary @- "$URL/api/v1/ingest/hook" -w '\n%{http_code}' 2>/dev/null)
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    2*)
      case "$body" in *permissionDecision*|*additionalContext*) printf '%s\n' "$body" ;; esac
      exit 0 ;;
    *)
      spool_write
      if is_true "$FAIL_CLOSED"; then
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Brokk Observe policy server unreachable and fail-closed mode is enabled."}}'
      fi
      exit 0 ;;
  esac
fi

spool_write

case "$EVENT" in
  SessionEnd)
    # Finish synchronously so nothing is lost when Claude exits (e.g. -p mode).
    flush 5
    upload_transcript "$SID" "$(json_str transcript_path)"
    rm -f "$IDENT" "$STATE/$SID.head0" 2>/dev/null
    exit 0 ;;
  SessionStart)
    TP=$(json_str transcript_path)
    # The one time the plugin speaks without being asked: events are piling
    # up undelivered and would otherwise be dropped unnoticed after 7 days.
    # A rejected token is reported at once; an unreachable server only once
    # something has waited a day (a laptop is often offline).
    if [ -f "$STATE/last_error" ]; then
      read -r err_code _ < "$STATE/last_error"
      waiting=$(spool_count)
      stale=$(find "$SPOOL" -name '*.json' -mmin +1440 2>/dev/null | head -n 1)
      case "$err_code" in
        401|403) why="the server rejected the ingest token (HTTP $err_code)" ;;
        000) why="the server cannot be reached"; [ -n "$stale" ] || why="" ;;
        *) why="the server answered HTTP $err_code"; [ -n "$stale" ] || why="" ;;
      esac
      if [ -n "$why" ] && [ "$waiting" -gt 1 ]; then
        printf '{"systemMessage":"Brokk Observe: %s events have not been delivered because %s. Run /brokk-observe:status."}\n' "$waiting" "$why"
      fi
    fi
    (
      find "$SPOOL" -name '*.json' -mtime +7 -delete 2>/dev/null
      find "$STATE" -type f -mtime +30 -delete 2>/dev/null
      if [ -z "$GH_LOGIN" ] && command -v gh >/dev/null 2>&1; then
        if [ -z "$(find "$DATA/gh_login" -mtime -1 2>/dev/null)" ]; then
          l=$(gh api user --jq .login 2>/dev/null) && [ -n "$l" ] && printf '%s' "$l" > "$DATA/gh_login"
        fi
      fi
      flush
      upload_transcript "$SID" "$TP"
    ) </dev/null >/dev/null 2>&1 &
    ;;
  Stop|PreCompact|SubagentStop)
    TP=$(json_str transcript_path)
    ( flush; upload_transcript "$SID" "$TP" ) </dev/null >/dev/null 2>&1 &
    ;;
  *)
    ( flush ) </dev/null >/dev/null 2>&1 &
    ;;
esac
exit 0
