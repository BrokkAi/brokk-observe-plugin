---
description: Show Brokk Observe audit status (server connection, spooled events, enforcement)
allowed-tools: Bash
---

## Brokk Observe status

!`"${CLAUDE_PLUGIN_ROOT}/scripts/observe-hook.sh" --status`

Summarize the status above for the user in a few short lines. If the server or token is not configured, explain how to register the machine: open the Brokk Observe dashboard, go to **Connect Claude Code**, and run the one command shown there in a terminal (it mails a link; opening it registers the machine). Organizations that manage it centrally set `OBSERVE_URL` and `OBSERVE_TOKEN` instead. If events are spooled, mention they will be sent automatically and that `/brokk-observe:flush` sends them now.
