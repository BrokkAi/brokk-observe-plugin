---
description: Import this machine's sessions from before Brokk Observe was installed (runs in the background)
allowed-tools: Bash
---

## Brokk Observe backfill

!`"${CLAUDE_PLUGIN_ROOT}/scripts/observe-hook.sh" --backfill`

Tell the user in one or two lines what the output above says: whether the import of earlier sessions started or is already running, and its last result. It runs in the background and nothing waits for it. If it says the organization does not import earlier sessions, explain that an administrator turns this on in the Brokk Observe dashboard under **Settings → Sessions from before the plugin**.
