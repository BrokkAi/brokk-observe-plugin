---
description: Show this session's audit summary (tool calls, cost, risk, findings) and its dashboard link
allowed-tools: Bash
---

## Current session as recorded by Brokk Observe

!`"${CLAUDE_PLUGIN_ROOT}/scripts/observe-hook.sh" --session || true`

Present the JSON above as a short summary: tool calls (and failures), prompts, estimated cost, risk score and highest severity, open security findings, LLM audit status, and the dashboard `url` if present. If the server says the session is not recorded yet, say events may still be in flight and suggest `/brokk-observe:flush`. Do not speculate about findings that are not listed.
