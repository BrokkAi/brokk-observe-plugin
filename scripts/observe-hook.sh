#!/usr/bin/env bash
# Brokk Observe hook for Claude Code and OpenAI Codex.
#
# Forwards every hook event to a Brokk Observe server. Both agents run command
# hooks with the same JSON on stdin, so one script serves both. Design goals:
#   * Never slow the agent down: events are written to a local spool (no
#     network) and flushed in the background. Git is only consulted on session
#     boundaries.
#   * Never lose events: the spool survives crashes, offline laptops and
#     server outages, and is flushed in order on the next event.
#   * Never change the agent's behaviour unless policy enforcement is on: the
#     script prints nothing and exits 0. With enforcement on, PreToolUse asks
#     the server synchronously and prints its allow/ask/deny decision.
#   * Read the agent's memory, never write it: at session boundaries the
#     instruction files it loaded and the notes it keeps for itself are
#     reported by git blob id, and only content the server lacks is sent.
#   * Portable: bash 3.2 (macOS), curl and git. No jq, python or node.
#
#   * Sessions from before the plugin: when the organization allows it, the
#     transcripts they left are uploaded once, by a detached background
#     process that SessionStart starts and never waits for (see Backfill).
#
# Usage (from hooks.json):  observe-hook.sh <HookEventName> [codex]   (event JSON on stdin)
# Maintenance:              observe-hook.sh --status | --flush | --session [id] | --backfill [codex]
# Register this machine:    observe-hook.sh --register [email] [server-url]   (mails you a link, prints a code)

set -u
PLUGIN_VERSION="0.5.0"
ARG="${1:-}"
# The agent running the hook: Codex's hooks file passes "codex" (hooks/codex-hooks.json).
case "${2:-}" in codex) AGENT=codex ;; *) AGENT=claude-code ;; esac

# ----------------------------------------------------------------------------
# Configuration: env OBSERVE_* (e.g. from managed settings) >
# config file (~/.config/brokk-observe/config, KEY=VALUE lines).
# ----------------------------------------------------------------------------
CONF_FILE="${OBSERVE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/brokk-observe/config}"
CF_OBSERVE_URL="" CF_OBSERVE_TOKEN="" CF_OBSERVE_ENFORCE="" CF_OBSERVE_TRANSCRIPTS="" CF_OBSERVE_MEMORY="" CF_OBSERVE_GITHUB_LOGIN="" CF_OBSERVE_AGENT_NAME="" CF_OBSERVE_FAIL_CLOSED=""
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      OBSERVE_URL|OBSERVE_TOKEN|OBSERVE_ENFORCE|OBSERVE_TRANSCRIPTS|OBSERVE_MEMORY|OBSERVE_GITHUB_LOGIN|OBSERVE_AGENT_NAME|OBSERVE_FAIL_CLOSED)
        eval "CF_$k=\$v" ;;  # k is from the fixed allowlist above; v is assigned, never evaluated
    esac
  done < "$CONF_FILE"
fi

URL="${OBSERVE_URL:-$CF_OBSERVE_URL}"
URL="${URL%/}"
TOKEN="${OBSERVE_TOKEN:-$CF_OBSERVE_TOKEN}"
ENFORCE="${OBSERVE_ENFORCE:-${CF_OBSERVE_ENFORCE:-false}}"
TRANSCRIPTS="${OBSERVE_TRANSCRIPTS:-${CF_OBSERVE_TRANSCRIPTS:-true}}"
MEMORY="${OBSERVE_MEMORY:-${CF_OBSERVE_MEMORY:-true}}"
GH_LOGIN="${OBSERVE_GITHUB_LOGIN:-$CF_OBSERVE_GITHUB_LOGIN}"
AGENT_NAME="${OBSERVE_AGENT_NAME:-$CF_OBSERVE_AGENT_NAME}"
FAIL_CLOSED="${OBSERVE_FAIL_CLOSED:-${CF_OBSERVE_FAIL_CLOSED:-false}}"
TIMEOUT="${OBSERVE_TIMEOUT:-3}"

# Both agents name the plugin's data directory when they run a hook. Run by
# hand from an agent's plugin cache (.../plugins/cache/<marketplace>/<plugin>/
# <version>/scripts), the script finds that same directory itself, so --status
# and --flush look at the spool the hooks write to.
DATA_DEFAULT="$HOME/.claude/brokk-observe"
case "$0" in
  */plugins/cache/*/*/*/scripts/*)
    cached=${0#*/plugins/cache/}
    cached_data="${0%%/plugins/cache/*}/plugins/data/$(printf '%s' "$cached" | cut -d/ -f2)-${cached%%/*}"
    [ -d "$cached_data" ] && DATA_DEFAULT=$cached_data ;;
esac
DATA="${OBSERVE_DATA_DIR:-${CLAUDE_PLUGIN_DATA:-$DATA_DEFAULT}}"
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
# Agent memory: the instruction files a session loaded (CLAUDE.md, AGENTS.md,
# rules) and the notes the agent keeps for itself (Claude Code's auto memory,
# Codex's memories). Each file is reported by its git blob id; the server
# answers with the versions it does not hold yet, and only those are sent.
# Nothing here writes to the agent's files.
# ----------------------------------------------------------------------------
TAB=$(printf '\t')
MEMORY_MAX_FILES=300
MEMORY_MAX_BYTES=1048576

# The first string the given Claude Code settings files set `key` to, without jq.
setting_str() { # $1=key, then settings files, most specific first
  local key=$1 f v; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    v=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null | head -n 1 | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# True when the most specific settings file that sets `key` sets it false.
setting_off() { # $1=key, then settings files, most specific first
  local key=$1 f v; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    v=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*[a-z]*" "$f" 2>/dev/null | head -n 1 | sed 's/.*:[[:space:]]*//')
    if [ -n "$v" ]; then [ "$v" = false ]; return; fi
  done
  return 1
}

# The repository the session runs in, which its worktrees share.
repo_root() {
  local d
  d=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$d" in
    */.git) printf '%s' "${d%/.git}" ;;
    *) git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD" ;;
  esac
}

# The directories from the top of the checkout down to the working directory.
dirs_down() {
  local d rel
  d=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || d=$CWD
  while [ -n "$d" ]; do
    printf '%s\n' "$d"
    [ "$d" = "$CWD" ] && break
    case "$CWD" in "$d"/*) rel=${CWD#"$d"/}; d="$d/${rel%%/*}" ;; *) break ;; esac
  done
}

# Claude Code's auto memory directory for this session, if it keeps one: it
# is `<config>/projects/<project>/memory`, where <project> comes from the
# repository, unless `autoMemoryDirectory` puts it somewhere else.
claude_memory_dir() { # $1=transcript path
  local tp=$1 home root projects d
  [ "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" = 1 ] && return 1
  home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  root=$(repo_root)
  set -- "$CWD/.claude/settings.local.json" "$CWD/.claude/settings.json" "$root/.claude/settings.local.json" "$root/.claude/settings.json" "$home/settings.json"
  setting_off autoMemoryEnabled "$@" && return 1
  # Where memory is kept is taken only from the user's own settings: a
  # repository's settings file could otherwise point this at any directory
  # on the machine and have its files reported.
  if d=$(setting_str autoMemoryDirectory "$home/settings.json"); then
    case "$d" in \~/*) d="$HOME/${d#\~/}" ;; esac
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  fi
  projects="$home/projects"
  case "$tp" in */projects/*/*) projects="${tp%/*}"; projects="${projects%/*}" ;; esac
  for d in ${CLAUDE_CODE_PROJECT_DIR_NAME:+"$projects/$CLAUDE_CODE_PROJECT_DIR_NAME/memory"} \
           "$projects/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')/memory" "${tp%/*}/memory"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# Claude Code's files, one per line: kind, scope, load reason (or -), path.
claude_memory_files() { # $1=session id $2=transcript path
  local sid=$1 d f has_claude_md=""
  # The instruction files Claude Code said it loaded. Those it loaded at the
  # start come first, so that is the reason kept for a file loaded twice.
  if [ -f "$STATE/$sid.instr" ]; then
    { grep "^session_start$TAB" "$STATE/$sid.instr"; grep -v "^session_start$TAB" "$STATE/$sid.instr"; } \
      | awk -F '\t' -v OFS='\t' '{ print "instructions", $2, $1, $3 }'
  fi
  # Claude Code reads a project's AGENTS.md itself, without saying so, when
  # no CLAUDE.md is on the way down to the working directory.
  while IFS= read -r d; do
    for f in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do [ -f "$d/$f" ] && has_claude_md=1; done
  done <<EOF
$(dirs_down)
EOF
  if [ -z "$has_claude_md" ]; then
    while IFS= read -r d; do
      [ -f "$d/AGENTS.md" ] && printf 'instructions\tproject\tsession_start\t%s\n' "$d/AGENTS.md"
    done <<EOF
$(dirs_down)
EOF
  fi
  if d=$(claude_memory_dir "$2"); then
    find "$d" -maxdepth 2 -type f -name '*.md' ! -name '.*' 2>/dev/null | sort | while IFS= read -r f; do
      printf 'memory\tauto\t-\t%s\n' "$f"
    done
  fi
}

# Codex's files: AGENTS.md (an AGENTS.override.md takes its place) in its
# home and from the top of the checkout down to the working directory, and
# its memories when they are on.
codex_memory_files() {
  local home="${CODEX_HOME:-$HOME/.codex}" d f
  if [ -f "$home/AGENTS.override.md" ]; then printf 'instructions\tuser\tsession_start\t%s\n' "$home/AGENTS.override.md"
  elif [ -f "$home/AGENTS.md" ]; then printf 'instructions\tuser\tsession_start\t%s\n' "$home/AGENTS.md"; fi
  while IFS= read -r d; do
    if [ -f "$d/AGENTS.override.md" ]; then printf 'instructions\tproject\tsession_start\t%s\n' "$d/AGENTS.override.md"
    elif [ -f "$d/AGENTS.md" ]; then printf 'instructions\tproject\tsession_start\t%s\n' "$d/AGENTS.md"; fi
  done <<EOF
$(dirs_down)
EOF
  for d in "$home/memories" "$home/memories_v2"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 3 -type f ! -name '.*' ! -path '*/.*' 2>/dev/null | sort | while IFS= read -r f; do
      printf 'memory\tauto\t-\t%s\n' "$f"
    done
  done
}

# Report the session's memory: `start` when the session starts, `later`
# otherwise. One report per session runs at a time, under a lock file.
report_memory() { # $1=session id $2=transcript path $3=start|later
  is_true "$MEMORY" || return 0
  local sid=$1 tp=$2 phase=$3
  [ -n "$sid" ] || return 0
  local lock="$STATE/$sid.memlock" waited=0
  until ( set -C; printf '%s' "$$" > "$lock" ) 2>/dev/null; do
    # A report that was killed leaves its lock behind.
    if [ -n "$(find "$lock" -mmin +2 2>/dev/null)" ]; then rm -f "$lock"; continue; fi
    [ "$waited" -lt 50 ] || return 0
    sleep 0.2; waited=$((waited + 1))
  done
  local tmp="$STATE/.mem.$$" sent="$STATE/$sid.mem" complete=true n out code body h p c ok=1
  if [ "$AGENT" = codex ]; then codex_memory_files; else claude_memory_files "$sid" "$tp"; fi > "$tmp.candidates" 2>/dev/null
  # One line per file that is there and can be read.
  awk -F '\t' '!seen[$4]++' "$tmp.candidates" | while IFS="$TAB" read -r kind scope reason p; do
    if [ -f "$p" ] && [ -r "$p" ]; then printf '%s\t%s\t%s\t%s\n' "$kind" "$scope" "$reason" "$p"; fi
  done > "$tmp.files"
  n=$(wc -l < "$tmp.files" | tr -d ' ')
  if [ "$n" -gt "$MEMORY_MAX_FILES" ]; then
    head -n "$MEMORY_MAX_FILES" "$tmp.files" > "$tmp.cut" && mv "$tmp.cut" "$tmp.files"
    complete=false
  fi
  : > "$tmp.hashes"
  # Raw bytes, as the server hashes them: no line-ending or attribute filters.
  if [ "$n" -gt 0 ] && ! cut -f4 "$tmp.files" | git hash-object --no-filters --stdin-paths > "$tmp.hashes" 2>/dev/null; then
    n=-1
  fi
  touch "$sent.paths"
  [ "$n" -ge 0 ] && paste "$tmp.hashes" "$tmp.files" | while IFS="$TAB" read -r h kind scope reason p; do
    [ -n "$h" ] && [ -n "$p" ] || continue
    when=later
    if [ "$phase" = start ] || [ "$reason" = session_start ]; then grep -qxF -- "$p" "$sent.paths" || when=start; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$(wc -c < "$p" | tr -d ' ')" "$kind" "$scope" "$when" "$reason" "$p"
  done > "$tmp.report"
  # Nothing to say when a file could not be read while it was hashed, when
  # there is nothing now and was nothing before, or when the same versions
  # were all delivered last time.
  [ -f "$tmp.report" ] && cut -f1,7 "$tmp.report" | sort > "$tmp.key"
  if [ "$n" -lt 0 ] || { [ "$n" -eq 0 ] && [ ! -s "$sent" ]; } || { [ -f "$STATE/$sid.memok" ] && cmp -s "$tmp.key" "$sent"; }; then
    rm -f "$tmp.candidates" "$tmp.files" "$tmp.hashes" "$tmp.report" "$tmp.key" "$lock"
    return 0
  fi
  out=$(curl -sS --max-time 15 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: text/plain' \
        --data-binary @"$tmp.report" "$URL/api/v1/ingest/memory?session_id=$sid&complete=$complete" -w '\n%{http_code}' 2>/dev/null)
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    # A server without memory reporting: say nothing more until the files change.
    404) cp "$tmp.key" "$sent"; touch "$STATE/$sid.memok" ;;
    2*)
      cp "$tmp.key" "$sent"
      { cat "$sent.paths"; cut -f7 "$tmp.report"; } | sort -u > "$tmp.paths" && mv "$tmp.paths" "$sent.paths"
      for h in $(printf '%s' "$body" | grep -o '[0-9a-f]\{40\}'); do
        p=$(awk -F '\t' -v h="$h" '$1 == h { print $7; exit }' "$tmp.report")
        [ -f "$p" ] || continue
        [ "$(wc -c < "$p" | tr -d ' ')" -le "$MEMORY_MAX_BYTES" ] || continue
        c=$(curl_post "/api/v1/ingest/memory/blob?session_id=$sid" application/octet-stream "$p")
        # 409: the file changed after it was hashed; the next report has it.
        case "$c" in 2*|409|413) ;; *) ok=0 ;; esac
      done
      if [ "$ok" = 1 ]; then touch "$STATE/$sid.memok"; else rm -f "$STATE/$sid.memok"; fi ;;
  esac
  rm -f "$tmp.candidates" "$tmp.files" "$tmp.hashes" "$tmp.report" "$tmp.key" "$lock"
  return 0
}

# Backfill: the sessions that ran on this machine before the plugin did.
#
# When the organization allows it (the server says how many days back), the
# transcripts those sessions left are uploaded once, a few hundred lines per
# request. A detached, low-priority process does it: SessionStart starts it
# and returns, so no session ever waits for it. It keeps its place in every
# transcript, so when it is stopped (the laptop sleeps, the server is busy, the
# agent's process group is killed) the next session start picks it up again.
# It has a lock of its own, so live events are never held up behind it.
# ----------------------------------------------------------------------------
BF="$DATA/backfill"

backfill_note() { printf '%s %s\n' "$(date +%s)" "$1" > "$BF/last" 2>/dev/null; }

# Do not start again for $1 seconds, because of $2.
backfill_wait() {
  printf '%s' "$(( $(date +%s) + $1 ))" > "$BF/wait_until" 2>/dev/null
  backfill_note "$2"
}

# Whether a session start should start it: transcripts may be uploaded, it
# has not finished, and it is not waiting to try again. Only file checks: this
# runs in the hook.
backfill_due() {
  is_true "$TRANSCRIPTS" && [ -n "$URL" ] && [ -n "$TOKEN" ] || return 1
  [ ! -f "$BF/done" ] || return 1
  local resume_at
  resume_at=$(cat "$BF/wait_until" 2>/dev/null)
  case "$resume_at" in ''|*[!0-9]*) resume_at=0 ;; esac
  [ "$(date +%s)" -ge "$resume_at" ]
}

backfill_running() { [ -d "$BF/lock" ] && [ -z "$(find "$BF/lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; }

backfill_lock() {
  mkdir "$BF/lock" 2>/dev/null && return 0
  # Break a lock left by a process that was killed.
  if [ -n "$(find "$BF/lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
    rmdir "$BF/lock" 2>/dev/null
    mkdir "$BF/lock" 2>/dev/null && return 0
  fi
  return 1
}

# Detached from the agent (its own session where setsid exists) and niced.
backfill_start() {
  mkdir -p "$BF" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup nice -n 10 bash "$0" --backfill-run "$AGENT" </dev/null >/dev/null 2>&1 &
  else
    nohup nice -n 10 bash "$0" --backfill-run "$AGENT" </dev/null >/dev/null 2>&1 &
  fi
}

# This agent's transcripts written to in the last $1 days, one path a line.
backfill_files() {
  if [ "$AGENT" = codex ]; then
    find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name 'rollout-*.jsonl' -mtime "-$1" 2>/dev/null
  else
    find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mtime "-$1" 2>/dev/null
  fi | sort
}

# The session id a transcript is named after: Claude Code's <id>.jsonl,
# Codex's rollout-<time>-<id>.jsonl.
backfill_sid() {
  local b=${1##*/}
  printf '%s' "${b%.jsonl}" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

# The first line of an upload: who ran the session, and where, as hook events
# say it. The directory it ran in comes from the transcript; the identity and
# the remote from that directory's git configuration, as they are now.
backfill_header() {
  local cwd email name remote login host os m
  cwd=$(head -n 200 "$1" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
    | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//' -e 's/\\\\/\\/g')
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    email="${OBSERVE_USER_EMAIL:-$(git -C "$cwd" config user.email 2>/dev/null)}"
    name=$(git -C "$cwd" config user.name 2>/dev/null)
    remote=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null | sed -E 's#(://)[^/@]+@#\1#')
  else
    email="${OBSERVE_USER_EMAIL:-$(git config --global user.email 2>/dev/null)}"
    name=$(git config --global user.name 2>/dev/null)
    remote=""
  fi
  login="$GH_LOGIN"
  if [ -z "$login" ] && [ -f "$DATA/gh_login" ]; then login=$(cat "$DATA/gh_login"); fi
  host="$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-}")"
  os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  m="\"user_email\":\"$(esc "$email")\",\"user_name\":\"$(esc "$name")\",\"hostname\":\"$(esc "$host")\",\"os\":\"$(esc "$os")\""
  m="$m,\"agent\":\"$AGENT\",\"plugin_version\":\"$PLUGIN_VERSION\",\"runtime\":\"local\""
  [ -n "$login" ] && m="$m,\"github_login\":\"$(esc "$login")\""
  [ -n "$AGENT_NAME" ] && m="$m,\"agent_name\":\"$(esc "$AGENT_NAME")\""
  [ -n "$remote" ] && m="$m,\"git\":{\"remote\":\"$(esc "$remote")\"}"
  printf '{"meta":{%s}}' "$m"
}

# Upload one transcript, resuming where the last attempt stopped.
#   0 imported   3 nothing to import (recorded live, empty, another key's)
#   1 stop for now (already noted)   2 stop: the organization turned it off
backfill_one() {
  local f=$1 sid=$2 led="$BF/sessions/$2" chunk="$BF/.chunk.$$" off total header n code resp body end lines=400 busy=0
  off=$(cat "$led" 2>/dev/null)
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  total=$(wc -l < "$f" | tr -d ' ')
  header=$(backfill_header "$f")
  while :; do
    touch "$BF/lock" 2>/dev/null
    tail -n "+$((off + 1))" "$f" | head -n "$lines" > "$chunk.lines"
    n=$(wc -l < "$chunk.lines" | tr -d ' ')
    [ "$n" -eq 0 ] && [ -s "$chunk.lines" ] && n=1  # a last line without its newline
    end=""
    [ $((off + n)) -ge "$total" ] && end="&end=1"
    { printf '%s\n' "$header"; cat "$chunk.lines"; } > "$chunk"
    resp=$(curl -sS --max-time 120 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/x-ndjson' \
      --data-binary @"$chunk" "$URL/api/v1/ingest/import?session_id=$sid&start_line=$off$end" -w '\n%{http_code}' 2>/dev/null)
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}
    case "$code" in
      2*)
        busy=0
        case "$body" in *'"skipped"'*) echo "done" > "$led"; return 3 ;; esac
        off=$((off + n))
        if [ -n "$end" ]; then
          echo "done" > "$led"
          printf '%s\n' "$sid" >> "$BF/imported"
          return 0
        fi
        printf '%s' "$off" > "$led"
        [ "$lines" -lt 400 ] && lines=$(( lines * 2 > 400 ? 400 : lines * 2 )) ;;
      413)
        # Too big for the server. Send less at a time; a single line that is
        # still too big is skipped, or it would block every line after it.
        if [ "$lines" -gt 1 ]; then lines=$(( lines / 8 > 0 ? lines / 8 : 1 ))
        else off=$((off + 1)); printf '%s' "$off" > "$led"; fi ;;
      503)
        # Another machine's import is running. Wait our turn, for a while.
        busy=$((busy + 1))
        if [ "$busy" -gt 30 ]; then backfill_wait 600 "waiting: the server is busy importing other sessions"; return 1; fi
        sleep 60 ;;
      403)
        case "$body" in
          *'does not import'*) return 2 ;;
          *) echo "done" > "$led"; return 3 ;;  # started with another key: not ours to import
        esac ;;
      400) echo "done" > "$led"; return 3 ;;    # the server can never take it
      *) backfill_wait 600 "stopped: the server answered HTTP ${code:-000}; trying again later"; return 1 ;;
    esac
  done
}

# The background process itself.
backfill_run() {
  mkdir -p "$BF/sessions" 2>/dev/null
  backfill_lock || return 0
  trap 'rmdir "$BF/lock" 2>/dev/null; rm -f "$BF/.chunk.$$" "$BF/.chunk.$$.lines"' EXIT
  local resp code days f sid fresh=0 imported=0 rc
  resp=$(curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" "$URL/api/v1/ingest/backfill" -w '\n%{http_code}' 2>/dev/null)
  code=${resp##*$'\n'}
  days=$(printf '%s' "${resp%$'\n'*}" | grep -o '"days"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')
  case "$code" in
    200) ;;
    404) backfill_wait 604800 "off: this server does not import earlier sessions"; return 0 ;;
    *) backfill_wait 3600 "waiting: could not ask the server (HTTP ${code:-000})"; return 0 ;;
  esac
  # Off: an administrator may turn it on later, so ask again tomorrow.
  if [ "${days:-0}" -le 0 ]; then backfill_wait 86400 "off: your organization does not import earlier sessions"; return 0; fi
  backfill_note "running: importing sessions from the last $days days"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sid=$(backfill_sid "$f")
    [ -n "$sid" ] || continue
    [ "$(cat "$BF/sessions/$sid" 2>/dev/null)" = "done" ] && continue
    # Recorded live by this plugin: its hook events are the record.
    if [ -f "$STATE/$sid.tlines" ] || [ -f "$STATE/$sid.ident" ]; then echo "done" > "$BF/sessions/$sid"; continue; fi
    # Still being written: a session that was already running when the
    # plugin was installed. Next time, once it has gone quiet.
    if [ -n "$(find "$f" -mmin -30 2>/dev/null)" ]; then fresh=$((fresh + 1)); continue; fi
    backfill_one "$f" "$sid" </dev/null
    rc=$?
    case $rc in
      0) imported=$((imported + 1)) ;;
      3) ;;
      2) backfill_wait 86400 "off: your organization does not import earlier sessions"; return 0 ;;
      *) return 0 ;;
    esac
  done <<EOF
$(backfill_files "$days")
EOF
  local total
  total=$(wc -l < "$BF/imported" 2>/dev/null | tr -d ' ')
  if [ "$fresh" -gt 0 ]; then
    backfill_note "running: ${total:-0} sessions imported; $fresh still in use, imported once they have been quiet for 30 minutes"
  else
    touch "$BF/done"
    backfill_note "finished: ${total:-0} sessions from the last $days days imported"
  fi
  return 0
}

backfill_report() {
  local at what
  if [ -f "$BF/last" ]; then
    read -r at what < "$BF/last"
    echo "  backfill:      $what ($(( ($(date +%s) - ${at:-0}) / 60 )) min ago)$(backfill_running && echo '; running now')"
  elif is_true "$TRANSCRIPTS"; then
    echo "  backfill:      not started yet (starts with the next session)"
  else
    echo "  backfill:      off (transcript uploads are off)"
  fi
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
    echo "  memory:        $(is_true "$MEMORY" && echo upload || echo off)"
    echo "  data dir:      $DATA"
    echo "  spooled events: $(spool_count)"
    backfill_report
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
  --backfill)
    # Start it now (in the background) rather than at the next session.
    if ! is_true "$TRANSCRIPTS"; then
      echo "Brokk Observe backfill uploads transcripts, and transcript uploads are off on this machine (OBSERVE_TRANSCRIPTS)."
      exit 0
    fi
    if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
      echo "Brokk Observe is not configured on this machine: run observe-hook.sh --register you@company.com https://your-server"
      exit 0
    fi
    mkdir -p "$BF" 2>/dev/null
    rm -f "$BF/wait_until" "$BF/done"
    if backfill_running; then
      echo "Brokk Observe: importing sessions from before the plugin is already running in the background."
    else
      backfill_start
      echo "Brokk Observe: importing sessions from before the plugin, in the background. Nothing waits for it."
    fi
    backfill_report
    exit 0 ;;
  --backfill-run)
    backfill_run
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
META="{\"event_id\":\"$EVENT_ID\",\"ts\":$TS,\"plugin_version\":\"$PLUGIN_VERSION\",\"agent\":\"$AGENT\",\"runtime\":\"$RUNTIME\",$ident"
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

# Claude Code names each instruction file as it loads it; the next memory
# report includes it.
if [ "$EVENT" = InstructionsLoaded ] && [ -n "$SID" ] && is_true "$MEMORY"; then
  ip=$(json_str file_path)
  ir=$(json_str load_reason)
  case "$ir" in session_start|nested_traversal|path_glob_match|include|compact) ;; *) ir=- ;; esac
  case "$(json_str memory_type)" in User) it=user ;; Local) it=local ;; Managed) it=managed ;; *) it=project ;; esac
  case "$ip" in /*) printf '%s\t%s\t%s\n' "$ir" "$it" "$ip" >> "$STATE/$SID.instr" ;; esac
fi

# What this script keeps about a session, once the session has ended.
forget_session() {
  rm -f "$IDENT" "$STATE/$SID.head0" "$STATE/$SID.instr" "$STATE/$SID.mem" "$STATE/$SID.mem.paths" "$STATE/$SID.memok" 2>/dev/null
}

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
    TP=$(json_str transcript_path)
    if [ "$AGENT" = codex ]; then
      # Codex stops a SessionEnd hook after three seconds at most, so the
      # last delivery runs detached and outlives both the hook and Codex.
      ( flush 5; upload_transcript "$SID" "$TP"; report_memory "$SID" "$TP" later; forget_session ) </dev/null >/dev/null 2>&1 &
      exit 0
    fi
    # Finish synchronously so nothing is lost when Claude exits (e.g. -p mode).
    flush 5
    upload_transcript "$SID" "$TP"
    report_memory "$SID" "$TP" later
    forget_session
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
        # Codex has no plugin slash commands; the script reports its own status.
        how="Run /brokk-observe:status."
        [ "$AGENT" = codex ] && how="Run this in a terminal: $(esc "$0") --status"
        printf '{"systemMessage":"Brokk Observe: %s events have not been delivered because %s. %s"}\n' "$waiting" "$why" "$how"
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
      report_memory "$SID" "$TP" start
    ) </dev/null >/dev/null 2>&1 &
    # The sessions from before the plugin, if there are any to import.
    if backfill_due && ! backfill_running; then backfill_start; fi
    ;;
  Stop|PreCompact|SubagentStop)
    TP=$(json_str transcript_path)
    ( flush; upload_transcript "$SID" "$TP"; report_memory "$SID" "$TP" later ) </dev/null >/dev/null 2>&1 &
    ;;
  *)
    ( flush ) </dev/null >/dev/null 2>&1 &
    ;;
esac
exit 0
