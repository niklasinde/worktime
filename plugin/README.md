# WorkTime plugin for Claude Code

Starts WorkTime's MCP server (`bin/worktime --mcp`, through the link the app keeps in its data folder), records Claude Code session events for
the activity log, and carries the skills `meeting-context`, `continue-in-worktime` and `worktime-link` (driving and observing WorkTime as a
coordinator: what waits for the user, handing work to agents and to Main, waiting for results, timelines, outcomes, usage, workspaces).

## After updating WorkTime: reconnect

The MCP server is a process started when Claude Code connects. A connection made before an update keeps the tools and instructions it
started with, so new tools are missing until you reconnect: run `/mcp` in Claude Code and reconnect `worktime` (or start a new session).
The server instructions end with `schema_version: <n>`, and the `app_info` tool compares it with the running app's and says when they differ.
The server also tells the client when its tool set changed since the previous run (`notifications/tools/list_changed`).

Open WorkTime once so it can link itself at `<data folder>/bin/worktime`.
