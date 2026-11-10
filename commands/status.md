---
description: Show Brokk Observe audit status (server connection, spooled events, enforcement)
allowed-tools: Bash
---

## Brokk Observe status

!`"${CLAUDE_PLUGIN_ROOT}/scripts/observe-hook.sh" --status`

Summarize the status above for the user in a few short lines. If the server or token is not configured, explain how to configure it: run `/plugin configure brokk-observe@brokk`, or set `OBSERVE_URL` and `OBSERVE_TOKEN` (an ingest key from the dashboard's Settings page), or ask their administrator if the organization manages it. If events are spooled, mention they will be sent automatically and that `/brokk-observe:flush` sends them now.
