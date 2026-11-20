---
name: continue-in-worktime
description: Continue a Claude Code or Codex conversation in WorkTime when the user asks to move a chat, send its context to an existing WorkTime agent, or pick up work there.
---

## Continue in a particular WorkTime agent

Use `agents_overview` to identify the destination in the requested workspace. Send the next task and the context it needs with `send_to_agent`. For an existing topic use its `topic:<id>` key. For a workspace's Main use `agent: "Main"` and `workspace`. A routine and a similarly named topic can be different destinations. If the target cannot be addressed, explain which one you found.

Put short handoffs directly in `text`. When the user wants a full transcript that exceeds the tool's text limit, use a readable local transcript or export the user-visible conversation to a file accessible to the receiving agent. Include the absolute path, what to read, and where to resume in the prompt. WorkTime delivers this as a new message in the destination chat. Its earlier message bubbles stay in the source chat.

Send the handoff yourself when requested. For an asynchronous request, follow the returned `request_id` with `request_status`. Report whether the prompt started, queued, or still needs a decision. Check `pending_decisions` before directing the user to a specific choice. If the user asks for confirmation that the recipient read a file, look for its reply with `wait_for` or the destination's latest result. A queued prompt alone only confirms acceptance.

## Import a native Claude Code session

When the user wants to fork their Claude Code session into WorkTime without specifying a destination, use the native Claude import link. WorkTime resolves the owning agent, the checkout's pull request, or a new topic. Codex handoffs use the message workflow above.

Use `$CLAUDE_SESSION_ID` when set and the folder where Claude started. Otherwise, match a transcript under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/` by its folder and conversation content, and take its filename without `.jsonl` as the ID. With those values in `id` and `cwd`, run:

```sh
open "worktime://agent?session=$id&cwd=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$cwd")"
```

Check the destination with `agents_overview` before reporting where the session opened.
