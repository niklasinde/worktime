---
name: worktime-link
description: Drive and observe WorkTime from Claude Code or Codex as the user's coordinator, with the worktime MCP tools. Use when the user asks what waits for them in WorkTime, to hand work to an agent or to a workspace's Main, to wait for an agent to finish, to see a ticket's timeline or latest verdicts, what the agents cost, which version of WorkTime runs, to change workspaces and spaces, or to open something in the app.
---

WorkTime's MCP server `worktime` is the link between this session and the running app. Observe with the read tools, act with the
write tools; the user's own answers (permission prompts, reuse-or-new questions, review drafts) stay theirs: no tool answers,
approves or posts them, so tell the user what waits (`pending_decisions`) and where (`open_in_app`).

After updating WorkTime, reconnect the MCP server (`/mcp`, then reconnect worktime): a connection made before keeps the tools and
instructions it started with, and `app_info` says when its schema is older than the app's. The server instructions end with `schema_version`.

## Observe

- `pending_decisions`: everything waiting for the user, with ids and `worktime://` links: permission prompts, reuse-or-new questions, missing-tool requests, blocked turns, review drafts, automation asks. Read-only.
- `agents_overview`: every agent by urgency; filters kind, ticket, space, status, needs_me, query and since. `agent_session` reads a Claude Code transcript. For a Codex session, inspect its latest prompt, result and state in the overview.
- `attention`: what needs the user across pull requests, agents, Slack, notifications and meetings. Start here for "what do I need to look at".
- `ticket_timeline`: one ticket's or pull request's timeline across its sessions: triggers, prompts from Main, verdicts, reviews drafted and posted, answers, times.
- `outcomes`: the latest verdict (PASS, FAIL, BLOCKED, Recommendation) per ticket as a table; filters ticket, space, since.
- `request_status`: how an asynchronous `send_to_agent` went: pending, answered, created, started, timed_out or refused.
- `wait_for`: long poll (at most 600 s) on a session, request or ticket until it is idle, finished, needs the user or changes.
- `events_since`: a polling feed of events with a cursor (sessions started, finished, errored or waiting; decisions raised and answered; reviews posted; automations fired; routines run; app restarts). The alternative to `wait_for`.
- `app_info`: version, commit, pid, uptime, data folder, workspaces, working and waiting sessions, sidecar status, and whether a restart would interrupt running work.
- `links`: how agents, Jira tickets, pull requests, branches and Slack threads are linked; give `entity` as `jira:KEY`, `github_pr:owner/repo#12`, `agent:<key>` or the uuid a previous answer returned (an old Jira key still resolves after a move), and `depth: 2` for what is related through the neighbors.
- `request_log`: the last 50 requests WorkTime made to GitHub, Slack, Jira and Claude with response sizes, plus totals per service and the bytes of the last hour.
- `usage_summary`: what Claude calls cost by range (today, 7d, 30d) and group (workspace, agent, routine, automation, model), with the plan's windows when cached.
- `workspaces`: workspaces with folders, GitHub owners, Jira projects, Slack and spaces.
- `assistants`, `routines`, `automations`: the role agents, scheduled prompts and event-driven prompts that exist; look before adding one.
- `scheduled_notifications`, `reminders`: what is scheduled and open.

## Act

- `send_to_agent`: a prompt to an agent. When asked to hand off context, locate the intended agent and send the next task with its context in `text`. For a longer transcript include a path the recipient can read. Follow the returned request ID and report the actual outcome. `agent: "Main"` (with `workspace`) talks to a workspace's Main, arriving as "From Claude Code · <folder>". Main returns a direct acknowledgement. For other agents, `async: true` returns a `request_id` while WorkTime handles delivery and any reuse decision.
- `send_to_main`: an agent's report to its Main.
- `open_in_app`: bring WorkTime to the front on a session, ticket, pull request or page. Only navigates and asks nothing.
- `notify`, `cancel_notification`: a notification now or later; `add_reminder`, `complete_reminder`: reminders.
- `create_workspace`, `update_workspace`, `create_space`, `update_space`, `delete_space`, `tag_session`: workspace configuration without editing JSON, applied live; each asks the user.
- `create_assistant`, `update_assistant`, `delete_assistant`: role agents under a Main.
- `create_routine`, `update_routine`, `set_routine_enabled`, `delete_routine`, `analyze_routine`, `compile_routine`: scheduled prompts and their fixed parts.
- `create_automation`, `update_automation`, `delete_automation`: prompts that start on a Slack, GitHub or Jira event.

Act on the user’s request. Surface any approval or reuse decision that WorkTime actually reports.

## Meetings, activity, GitHub, Jira, Slack

- `recent_meetings`, `search_meetings`, `get_meeting`, `meetings_on`, `get_notes`, `read_transcript`, `search_in_meeting`, `open_action_items`: meetings, transcripts with speakers, notes and action items.
- `meeting_brief`: the pre-meeting brief of the next or a named meeting.
- `activity_context`, `activity_on`, `blocks_in_range`, `block_details`, `time_report`, `resume_context`: tracked work, hours and where the user left off.
- `github_needs_attention`, `github_prs`, `github_pr`: cached pull requests, only what the app has fetched.
- `jira_issue`, `jira_search`, `slack_search`, `slack_thread`: lookups with the tokens set up in WorkTime.

Say which meeting, ticket or pull request an answer comes from. When nothing matches, say so instead of guessing.
