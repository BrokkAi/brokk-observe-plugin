# Brokk Observe — Claude Code plugin

Records every Claude Code session for your organization's audit trail. The plugin captures prompts, tool calls (with inputs, outputs and timings), permission decisions, subagents, compactions, commits and PRs, and sends them to a Brokk Observe server. The server then:

- runs security detectors on each event and an optional LLM security review on each session,
- ranks people and agents on leaderboards,
- traces bugs back to the session that introduced them.

With **enforce mode** on, the plugin also applies your organization's central guardrail policies before each tool call runs (allow / ask / deny).

## Install

```
/plugin marketplace add BrokkAi/brokk-observe-plugin
/plugin install brokk-observe@brokk
```

Then register the machine with your email address:

```
curl -fsSL https://observe.example.com/register.sh | bash -s you@company.com
```

The server mails you a link. Open it, and the machine is registered to you: the script saves the server address and a key of its own in `~/.config/brokk-observe/config`. There is nothing to copy or paste. (The same script is `scripts/register.sh` in this repository.)

To use a shared ingest token instead (CI, fleets, managed settings), use one of these options:

- **Interactive:** `/plugin configure brokk-observe@brokk`. It asks for the server URL and an ingest token, and stores the token in your OS keychain.
- **Environment:** `export OBSERVE_URL=https://observe.example.com OBSERVE_TOKEN=bko_ingest_…`
- **Config file:** put `KEY=VALUE` lines in `~/.config/brokk-observe/config`.

Ingest tokens are created in the dashboard under **Settings → API keys**, or with `brokk-observe keys create --scope ingest --name laptops`.

Check it with `/brokk-observe:status`.

## Commands

| Command | What it does |
|---|---|
| `/brokk-observe:status` | Server, token, enforcement mode, spooled events, and a live connectivity check |
| `/brokk-observe:session` | This session's audit summary: tool calls, cost, risk score, open findings, dashboard link |
| `/brokk-observe:flush` | Send any locally spooled events now |

## Settings

Environment variables win over plugin options, which win over the config file. Managed settings can therefore enforce values centrally.

| Env var | Plugin option | Default | Meaning |
|---|---|---|---|
| `OBSERVE_URL` | `server_url` | — | Server base URL |
| `OBSERVE_TOKEN` | `ingest_token` | — | Ingest key (`bko_ingest_…`) |
| `OBSERVE_ENFORCE` | `enforce_policies` | `false` | Ask the server for a policy decision before every tool call |
| `OBSERVE_FAIL_CLOSED` | — | `false` | In enforce mode, deny tool calls when the server is unreachable |
| `OBSERVE_TIMEOUT` | — | `3` | Seconds to wait for a policy decision |
| `OBSERVE_TRANSCRIPTS` | `upload_transcripts` | `true` | Upload the transcript (for token/cost data and LLM audit) |
| `OBSERVE_GITHUB_LOGIN` | `github_login` | from `gh` | Links your sessions to your PRs and reviews |
| `OBSERVE_AGENT_NAME` | — | `claude-code` | Label for automated agents, e.g. `nightly-triage` |
| `OBSERVE_USER_EMAIL` | — | `git config user.email` | Identity override |
| `OBSERVE_DATA_DIR` | — | `$CLAUDE_PLUGIN_DATA` | Local spool and state |

## Rolling out to an organization

To make auditing mandatory, use [managed settings](https://code.claude.com/docs/en/managed-settings). Place them in `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS), `/etc/claude-code/managed-settings.json` (Linux) or your MDM, or set them in claude.ai's server-managed settings:

```json
{
  "extraKnownMarketplaces": {
    "brokk": { "source": { "source": "github", "repo": "BrokkAi/brokk-observe-plugin" } }
  },
  "enabledPlugins": { "brokk-observe@brokk": true },
  "env": {
    "OBSERVE_URL": "https://observe.example.com",
    "OBSERVE_TOKEN": "bko_ingest_…",
    "OBSERVE_ENFORCE": "true"
  },
  "allowManagedHooksOnly": true,
  "disableSideloadFlags": true
}
```

- Users cannot disable a plugin that is force-enabled in managed settings.
- `allowManagedHooksOnly` stops other hooks from tampering with the audit hooks.
- `disableSideloadFlags` blocks `--plugin-dir` workarounds.
- Use one ingest key per fleet or team, so you can revoke a single fleet without touching the others.

**Native OpenTelemetry (optional, recommended):** Claude Code's built-in telemetry reports authoritative token and cost numbers. Point it at the same server:

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://observe.example.com",
  "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer bko_ingest_…"
}
```

## How it works

- **Never slows Claude down.** Each hook writes its event to a local spool (no network) in about 20–60 ms, then exits. A background flusher sends spooled events in order. Git is only consulted at session boundaries. In enforce mode, `PreToolUse` makes one synchronous request, bounded by `OBSERVE_TIMEOUT`.
- **Never loses events.** If the server is down or the laptop is offline, events stay in the spool, which survives restarts. They are delivered on the next hook, and each carries an id, so a batch that is sent twice is stored once. `SessionEnd` flushes synchronously. Events the server has not accepted after 7 days are dropped.
- **Says so when delivery is broken.** If the server rejects the ingest token, or has been unreachable for a day with events waiting, the next session starts with a one-line warning. `/brokk-observe:status` shows the last delivery failure.
- **Never changes behaviour by accident.** Apart from that warning the script prints nothing and always exits 0. The only exception is enforce mode, where it prints the server's decision. Enforce mode fails open unless `OBSERVE_FAIL_CLOSED=true`; with fail-closed on, a plugin that has no server configured denies tool calls too.
- **Portable.** It needs only bash 3.2+ (macOS default), `curl` and `git`. No jq, Python or Node.

## What leaves the machine

- The hook event JSON that Claude Code provides: prompts, tool inputs and outputs, file paths.
- Git remote, with any embedded credentials stripped before sending, plus branch, HEAD, and the subjects of commits you made during the session.
- Your git email and name, your GitHub login if known, hostname and OS.
- With transcript upload on: the session transcript.

The server **redacts secrets on ingest** before anything is stored. Covered patterns include cloud keys, GitHub/Anthropic/OpenAI/Stripe/Slack tokens, private keys, JWTs, connection-string passwords and generic `password=` assignments. Each redaction is itself recorded as a security finding, so leaked credentials get rotated. Admins can set a retention period (`OBSERVE_RETENTION_DAYS`). Every dashboard action, such as triage, export or policy change, is written to an admin audit log.

Tell your users their sessions are recorded. Many jurisdictions require it, and it is the right thing to do.
