# Brokk Observe — plugin for Claude Code and OpenAI Codex

Records every Claude Code and Codex session for your organization's audit trail. The plugin captures prompts, tool calls (with inputs, outputs and timings), permission decisions, subagents, compactions, commits and PRs, and sends them to a Brokk Observe server. The server then:

- runs security detectors on each event and an optional LLM security review on each session,
- ranks people and agents on leaderboards,
- traces bugs back to the session that introduced them.

With **enforce mode** on, the plugin also applies your organization's central guardrail policies before each tool call runs (allow / ask / deny).

One plugin serves both agents: the two run command hooks that receive the same JSON, so the same script handles both. [What differs in Codex](#codex) is listed below.

## Install

Sign in to your Brokk Observe dashboard, open **Connect an agent**, and run the command it shows in a terminal:

```
curl -fsSL https://observe.example.com/register.sh | bash -s you@company.com
```

It mails you a link and prints a short code. Open the link, enter the code, and the machine is registered to you: the script saves the server address and a key of its own in `~/.config/brokk-observe/config`, then installs this plugin into Claude Code and into Codex, whichever of the `claude` and `codex` commands it finds. There is nothing else to set up. Start a new session and it appears in the dashboard.

**Codex needs one more step.** Codex does not run a plugin's hooks until you have reviewed them. The next time you start Codex it says that hooks need review: choose to trust the Brokk Observe ones there, or run `/hooks`. Until you do, nothing is recorded. After a plugin update that changes the hook script, Codex asks again.

If a command is not on your PATH, the script says so; install the plugin by hand instead. In Claude Code:

```
/plugin marketplace add BrokkAi/brokk-observe-plugin
/plugin install brokk-observe@brokk
```

For Codex, in a terminal:

```
codex plugin marketplace add BrokkAi/brokk-observe-plugin
codex plugin add brokk-observe@brokk
```

For CI, fleets and managed settings, skip registration and set a shared ingest token in the environment: `export OBSERVE_URL=https://observe.example.com OBSERVE_TOKEN=bko_ingest_…` (tokens are created in the dashboard under **Settings → API keys**).

Check it with `/brokk-observe:status` in Claude Code.

## Commands

These are Claude Code slash commands.

| Command | What it does |
|---|---|
| `/brokk-observe:status` | Server, token, enforcement mode, spooled events, and a live connectivity check |
| `/brokk-observe:session` | This session's audit summary: tool calls, cost, risk score, open findings, dashboard link |
| `/brokk-observe:flush` | Send any locally spooled events now |

Codex has no plugin slash commands. Run the script behind them in a terminal instead, with `--status`, `--session` or `--flush`:

```
~/.codex/plugins/cache/brokk/brokk-observe/*/scripts/observe-hook.sh --status
```

## Codex

Requires a Codex CLI with plugin hooks; tested with 0.167.0.

| | Claude Code | Codex |
|---|---|---|
| Shell commands | `Bash` | `Bash` (same detectors and policies) |
| File edits | `Edit`, `Write`, one call per file | `apply_patch`, one call for a whole patch. The server checks and counts it as the file writes and edits it makes, so a policy on `Edit\|Write` and a file path covers it |
| Policy **deny** | blocks the call | blocks the call |
| Policy **ask** | pauses for the developer to approve | **denies**. A Codex hook cannot ask, and Codex would run the call if the hook tried to. The reason tells the developer to run it themselves if it is intended |
| Policy **warn** | adds the message to the agent's context | the same |
| Tokens and cost | from the transcript, or OpenTelemetry | reported by Codex after each model request |
| Failed commands | reported by a hook | the exit code is read from the session log, so it shows once the log is uploaded (at the end of each turn) |
| Permissions bypassed | reported by a hook | Codex reports a bypass whenever it will not ask for approval, even inside its sandbox. That is recorded as `never-ask`; the *permissions bypassed* finding needs the session log, which says whether the sandbox was off too |
| Session end | delivered before Claude Code exits | delivered in the background: Codex stops that hook after three seconds |
| Hosted tools (web search) | hooked | not hooked by Codex, so not recorded |

The hooks Codex runs are in [hooks/codex-hooks.json](hooks/codex-hooks.json). Both agents share one registration and one config file; each keeps its own local spool.

## Settings

Set these as environment variables or as `KEY=VALUE` lines in `~/.config/brokk-observe/config`. Environment variables win, so managed settings can enforce values centrally.

| Env var | Default | Meaning |
|---|---|---|
| `OBSERVE_URL` | — | Server base URL |
| `OBSERVE_TOKEN` | — | Ingest key (`bko_ingest_…`) |
| `OBSERVE_ENFORCE` | `false` | Ask the server for a policy decision before every tool call |
| `OBSERVE_FAIL_CLOSED` | `false` | In enforce mode, deny tool calls when the server is unreachable |
| `OBSERVE_TIMEOUT` | `3` | Seconds to wait for a policy decision |
| `OBSERVE_TRANSCRIPTS` | `true` | Upload the transcript, or Codex's session log (for token/cost data, failed commands and LLM audit) |
| `OBSERVE_MEMORY` | `true` | Report the agent's memory: the instruction files it loaded and the notes it keeps for itself (see [Agent memory](#agent-memory)) |
| `OBSERVE_GITHUB_LOGIN` | from `gh` | Links your sessions to your PRs and reviews |
| `OBSERVE_AGENT_NAME` | `claude-code` or `codex` | Label for automated agents, e.g. `nightly-triage` |
| `OBSERVE_USER_EMAIL` | `git config user.email` | Identity override |
| `OBSERVE_DATA_DIR` | the plugin's data directory | Local spool and state |

## Rolling out to an organization

To make auditing mandatory in Claude Code, use [managed settings](https://code.claude.com/docs/en/managed-settings). Place them in `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS), `/etc/claude-code/managed-settings.json` (Linux) or your MDM, or set them in claude.ai's server-managed settings:

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

**Codex:** install the plugin as above and set `OBSERVE_URL`, `OBSERVE_TOKEN` and `OBSERVE_ENFORCE` in the environment Codex runs in. Hooks a user installs need that user's review before they run. To make them mandatory, deploy the hook script with your device management and declare the hooks in Codex's `requirements.toml`: managed hooks are trusted by policy and cannot be switched off, and `allow_managed_hooks_only = true` stops other hooks from running. See [Codex hooks](https://developers.openai.com/codex/hooks). Each managed hook command is the script, the event name and `codex`, as in [hooks/codex-hooks.json](hooks/codex-hooks.json).

## How it works

- **Never slows the agent down.** Each hook writes its event to a local spool (no network) in about 20–60 ms, then exits. A background flusher sends spooled events in order. Git is only consulted at session boundaries. In enforce mode, `PreToolUse` makes one synchronous request, bounded by `OBSERVE_TIMEOUT`.
- **Never loses events.** If the server is down or the laptop is offline, events stay in the spool, which survives restarts. They are delivered on the next hook, and each carries an id, so a batch that is sent twice is stored once. `SessionEnd` flushes synchronously in Claude Code, and in the background in Codex. Events the server has not accepted after 7 days are dropped.
- **Says so when delivery is broken.** If the server rejects the ingest token, or has been unreachable for a day with events waiting, the next session starts with a one-line warning. `/brokk-observe:status` shows the last delivery failure.
- **Never changes behaviour by accident.** Apart from that warning the script prints nothing and always exits 0. The only exception is enforce mode, where it prints the server's decision. Enforce mode fails open unless `OBSERVE_FAIL_CLOSED=true`; with fail-closed on, a plugin that has no server configured denies tool calls too.
- **Portable.** It needs only bash 3.2+ (macOS default), `curl` and `git`. No jq, Python or Node.

## Agent memory

What an agent carries from one session to the next shapes what it does: the instruction files it loads and the notes it keeps for itself. With `OBSERVE_MEMORY` on (the default), the plugin reports them at the start of each session, at the end of each turn and when the session ends, so a finding or a bug can be traced to what the agent had been told, and that to the session that told it. The plugin only reads these files; it never writes them.

| | Claude Code | Codex |
|---|---|---|
| Instruction files | every file Claude Code reports loading (`InstructionsLoaded`): CLAUDE.md, CLAUDE.local.md, `.claude/rules/`, imports, managed CLAUDE.md, and why each was loaded; a project's AGENTS.md when there is no CLAUDE.md | `AGENTS.md` (or `AGENTS.override.md`) in `$CODEX_HOME` and from the top of the checkout down to the working directory |
| The agent's own memory | the auto memory directory, `<config>/projects/<project>/memory/*.md`, or wherever `autoMemoryDirectory` in your own settings puts it (a repository's settings cannot move it); nothing when auto memory is off | `$CODEX_HOME/memories/` and `memories_v2/`, when Codex memories are on. They cover every project on the machine |

Each file is reported by its git blob id. The server answers with the versions it does not hold yet, and only those are sent, so a session that starts with the same memory as the last one sends a list and nothing else. Files over 1 MiB are listed without their content; at most 300 files are reported.

## What leaves the machine

- The hook event JSON that Claude Code or Codex provides: prompts, tool inputs and outputs, file paths.
- Git remote, with any embedded credentials stripped before sending, plus branch, HEAD, and the subjects of commits you made during the session.
- Your git email and name, your GitHub login if known, hostname and OS.
- With transcript upload on: the session transcript (Claude Code) or session log (Codex).
- With memory reporting on: the paths and versions of the agent's instruction and memory files, and the content of versions the server does not hold yet.

The server **redacts secrets on ingest** before anything is stored. Covered patterns include cloud keys, GitHub/Anthropic/OpenAI/Stripe/Slack tokens, private keys, JWTs, connection-string passwords and generic `password=` assignments. Each redaction is itself recorded as a security finding, so leaked credentials get rotated. Admins can set a retention period (`OBSERVE_RETENTION_DAYS`). Every dashboard action, such as triage, export or policy change, is written to an admin audit log.

Tell your users their sessions are recorded. Many jurisdictions require it, and it is the right thing to do.

## License

MIT. See [LICENSE](LICENSE).
