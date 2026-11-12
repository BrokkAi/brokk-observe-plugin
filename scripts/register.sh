#!/usr/bin/env bash
# Register this machine with Brokk Observe, by email.
#
#   register.sh [you@company.com] [https://observe.example.com]
#
# The server mails a link to the address, and this script prints a code. Open
# the link, enter the code, and this script collects an ingest key issued to
# you and saves it (with the server URL) in the plugin's config file.
#
# It then installs the Brokk Observe plugin into Claude Code and into OpenAI
# Codex, whichever of the `claude` and `codex` commands are on this machine,
# so this one command is the whole setup.
#
# The server also serves this file, with its own address filled in:
#   curl -fsSL https://observe.example.com/register.sh | bash -s you@company.com
#
# Portable: bash 3.2 (macOS) and curl. No jq, python or node.
set -u

SERVED_FROM="__OBSERVE_URL__"
case "$SERVED_FROM" in __*) SERVED_FROM="" ;; esac

EMAIL="${1:-$(git config user.email 2>/dev/null)}"
URL="${2:-${OBSERVE_URL:-$SERVED_FROM}}"
URL="${URL%/}"
CONF_FILE="${OBSERVE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/brokk-observe/config}"

if [ -z "$EMAIL" ] || [ -z "$URL" ]; then
  echo "Usage: register.sh you@company.com https://observe.example.com" >&2
  exit 2
fi

esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s" | LC_ALL=C tr -d '\000-\037'; }
field() { printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//'; }
post() { # $1=path $2=json ; prints the body, then the HTTP code on its own line
  curl -sS --max-time 20 -X POST -H 'Content-Type: application/json' -d "$2" -w '\n%{http_code}' "$URL$1" 2>/dev/null
}

HOST=$(hostname 2>/dev/null || echo unknown)
resp=$(post /api/v1/device/start "{\"email\":\"$(esc "$EMAIL")\",\"device_name\":\"$(esc "$HOST")\"}")
code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" != 200 ]; then
  why=$(field error "$body")
  echo "Could not start registration with $URL: ${why:-HTTP ${code:-000}}" >&2
  exit 1
fi
DEVICE_CODE=$(field device_code "$body")
[ -n "$DEVICE_CODE" ] || { echo "The server sent no device code." >&2; exit 1; }

# The page behind the link asks for this code, so the link alone registers
# nothing: only someone who can read this terminal can approve the machine.
USER_CODE=$(field user_code "$body")
# It is printed for someone to read and type, so it is only believed if it is
# what such a code looks like: a few letters, digits and dashes. Anything else
# a server sends here (terminal escapes, a line of instructions) is dropped.
case "$USER_CODE" in
  *[!A-Za-z0-9-]*) USER_CODE="" ;;
esac
[ "${#USER_CODE}" -le 16 ] || USER_CODE=""

echo "A link is on its way to $EMAIL."
if [ -n "$USER_CODE" ]; then
  echo "Open it and enter this code to register this machine ($HOST):"
  echo
  printf '    %s\n' "$USER_CODE"
  echo
  echo "Waiting..."
else
  echo "Open it to register this machine ($HOST). Waiting..."
fi

deadline=$(( $(date +%s) + 900 ))
TOKEN=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 2
  resp=$(post /api/v1/device/token "{\"device_code\":\"$DEVICE_CODE\"}")
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  case "$code" in
    200)
      if [ "$(field status "$body")" = approved ]; then TOKEN=$(field token "$body"); break; fi ;;
    ''|000|5*) ;;  # the server is briefly unreachable: keep waiting
    *)
      why=$(field error "$body")
      echo "Registration failed: ${why:-HTTP $code}" >&2
      exit 1 ;;
  esac
done
[ -n "$TOKEN" ] || { echo "This machine was not approved in time. Run this again for a new link." >&2; exit 1; }

# Keep every other setting in the config file; replace the server and token.
mkdir -p "$(dirname "$CONF_FILE")"
tmp="$CONF_FILE.tmp.$$"
( umask 077
  { [ -f "$CONF_FILE" ] && grep -v -e '^OBSERVE_URL=' -e '^OBSERVE_TOKEN=' "$CONF_FILE"
    printf 'OBSERVE_URL=%s\nOBSERVE_TOKEN=%s\n' "$URL" "$TOKEN"
  } > "$tmp" )
mv "$tmp" "$CONF_FILE"
chmod 600 "$CONF_FILE"

echo "Registered: $HOST reports agent sessions to $URL as $EMAIL."
echo "Saved to $CONF_FILE"

# The plugin is what sends the sessions. Install it into each agent on this
# machine, unless it is there already. stdin is redirected because this script
# is usually being read from a pipe.
PLUGIN_SOURCE="${OBSERVE_PLUGIN_SOURCE:-BrokkAi/brokk-observe-plugin}"
install_claude() {
  if claude plugin list </dev/null 2>/dev/null | grep -q 'brokk-observe@'; then return 0; fi
  claude plugin marketplace add "$PLUGIN_SOURCE" </dev/null >/dev/null 2>&1 || true  # fine if it was added before
  claude plugin install brokk-observe@brokk </dev/null >/dev/null 2>&1
}
install_codex() {
  codex plugin marketplace add "$PLUGIN_SOURCE" </dev/null >/dev/null 2>&1 || true   # fine if it was added before
  codex plugin marketplace upgrade brokk </dev/null >/dev/null 2>&1 || true          # an older copy gains Codex support
  codex plugin add brokk-observe@brokk </dev/null >/dev/null 2>&1
}
claude_manual() {
  echo "  In Claude Code, run:"
  echo "    /plugin marketplace add $PLUGIN_SOURCE"
  echo "    /plugin install brokk-observe@brokk"
}
codex_manual() {
  echo "  For Codex, run in a terminal:"
  echo "    codex plugin marketplace add $PLUGIN_SOURCE"
  echo "    codex plugin add brokk-observe@brokk"
}
# Codex runs a plugin's hooks only after the user has reviewed them.
codex_trust() {
  echo "  One step left in Codex: start it and, when it asks about hooks that need review,"
  echo "  trust the Brokk Observe ones (or run /hooks). Codex does not run them until you do."
}
if [ "${OBSERVE_SKIP_PLUGIN:-}" != 1 ]; then
  found=0
  if command -v claude >/dev/null 2>&1; then
    found=1
    if install_claude; then
      echo "The Brokk Observe plugin is installed in Claude Code."
    else
      echo "The plugin could not be installed into Claude Code from here."
      claude_manual
    fi
  fi
  if command -v codex >/dev/null 2>&1; then
    found=1
    if install_codex; then
      echo "The Brokk Observe plugin is installed in Codex."
    else
      echo "The plugin could not be installed into Codex from here."
      codex_manual
    fi
    codex_trust
  fi
  if [ "$found" = 0 ]; then
    echo
    echo "One step left: install the plugin (neither the claude nor the codex command is on your PATH)."
    claude_manual
    codex_manual
    codex_trust
  fi
  echo "Start a new session and it appears in the dashboard: $URL"
fi
if [ -n "${OBSERVE_TOKEN:-}" ] && [ "$OBSERVE_TOKEN" != "$TOKEN" ]; then
  echo "Note: OBSERVE_TOKEN is set in your environment and takes precedence; unset it to use the new key." >&2
fi
