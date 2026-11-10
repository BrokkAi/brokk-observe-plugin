#!/usr/bin/env bash
# Register this machine with Brokk Observe, by email.
#
#   register.sh [you@company.com] [https://observe.example.com]
#
# The server mails a link to the address. Open it, and this script collects an
# ingest key issued to you and saves it (with the server URL) in the plugin's
# config file. Nothing to copy or paste.
#
# It then installs the Brokk Observe plugin into Claude Code, if the `claude`
# command is on this machine, so this one command is the whole setup.
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

echo "A link is on its way to $EMAIL."
echo "Open it to register this machine ($HOST). Waiting..."

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
[ -n "$TOKEN" ] || { echo "The link was not opened in time. Run this again for a new one." >&2; exit 1; }

# Keep every other setting in the config file; replace the server and token.
mkdir -p "$(dirname "$CONF_FILE")"
tmp="$CONF_FILE.tmp.$$"
( umask 077
  { [ -f "$CONF_FILE" ] && grep -v -e '^OBSERVE_URL=' -e '^OBSERVE_TOKEN=' "$CONF_FILE"
    printf 'OBSERVE_URL=%s\nOBSERVE_TOKEN=%s\n' "$URL" "$TOKEN"
  } > "$tmp" )
mv "$tmp" "$CONF_FILE"
chmod 600 "$CONF_FILE"

echo "Registered: $HOST reports Claude Code sessions to $URL as $EMAIL."
echo "Saved to $CONF_FILE"

# The plugin is what sends the sessions. Install it unless it is there already.
# stdin is redirected because this script is usually being read from a pipe.
PLUGIN_SOURCE="${OBSERVE_PLUGIN_SOURCE:-BrokkAi/brokk-observe-plugin}"
install_plugin() {
  command -v claude >/dev/null 2>&1 || return 1
  if claude plugin list </dev/null 2>/dev/null | grep -q 'brokk-observe@'; then return 0; fi
  claude plugin marketplace add "$PLUGIN_SOURCE" </dev/null >/dev/null 2>&1 || true  # fine if it was added before
  claude plugin install brokk-observe@brokk </dev/null >/dev/null 2>&1
}
if [ "${OBSERVE_SKIP_PLUGIN:-}" = 1 ]; then
  :
elif install_plugin; then
  echo "The Brokk Observe plugin is installed in Claude Code."
  echo "Done. Start a new Claude Code session and it appears in the dashboard: $URL"
else
  echo
  echo "One step left: install the plugin. In Claude Code, run:"
  echo "  /plugin marketplace add $PLUGIN_SOURCE"
  echo "  /plugin install brokk-observe@brokk"
  echo "Then start a new session and it appears in the dashboard: $URL"
fi
if [ -n "${OBSERVE_TOKEN:-}" ] && [ "$OBSERVE_TOKEN" != "$TOKEN" ]; then
  echo "Note: OBSERVE_TOKEN is set in your environment and takes precedence; unset it to use the new key." >&2
fi
