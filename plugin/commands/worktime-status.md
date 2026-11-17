---
description: Show which WorkTime runs, what waits for you in it and whether this MCP connection is up to date
---

Call `app_info` and `pending_decisions` of the `worktime` MCP server and show both answers briefly. If `app_info` says the connection's schema
differs from the app's, tell the user to reconnect the `worktime` MCP (`/mcp`) so the new tools appear. If it says a restart would interrupt running work, say so.
Do not answer, approve or dismiss anything that waits: only the user can, in WorkTime.
