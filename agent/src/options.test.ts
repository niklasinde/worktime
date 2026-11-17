import { test } from "node:test";
import assert from "node:assert/strict";
import { mcpServers, sessionOptions } from "./options.js";

test("an imported session is forked on resume, so its transcript is never appended to", () => {
  const forked = sessionOptions({ cwd: "/repo", sessionId: "s", forkSession: true }, "m", "default");
  assert.equal(forked.resume, "s");
  assert.equal(forked.forkSession, true);
  assert.equal(sessionOptions({ cwd: "/repo", sessionId: "s" }, "m", "default").forkSession, undefined);
  assert.equal(sessionOptions({ cwd: "/repo", forkSession: true }, "m", "default").forkSession, undefined);
});

test("the MCP server gets the Main's workspace only when there is one", () => {
  assert.deepEqual(mcpServers({}), {});
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app" }), { worktime: { type: "stdio", command: "/app", args: ["--mcp"] } });
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app", WORKTIME_WORKSPACE: "personal" }).worktime,
    { type: "stdio", command: "/app", args: ["--mcp"], env: { WORKTIME_WORKSPACE: "personal" } });
  assert.deepEqual(mcpServers({ WORKTIME_MCP_COMMAND: "/app", WORKTIME_WORKSPACE: "work", WORKTIME_AGENT: "topic:abc" }).worktime,
    { type: "stdio", command: "/app", args: ["--mcp"], env: { WORKTIME_WORKSPACE: "work", WORKTIME_AGENT: "topic:abc" } });
});

test("agents can start subagents, with the user's agent definitions available", () => {
  const options = sessionOptions({ cwd: "/repo" }, "m", "default");
  assert.ok((options.tools as string[]).includes("Agent"));
  assert.ok(options.agents);
});

test("partial messages are on, so the reply streams", () => {
  assert.equal(sessionOptions({ cwd: "/repo" }, "m", "default").includePartialMessages, true);
});

test("every agent is told how to offer a next step as buttons", () => {
  const options = sessionOptions({ cwd: "/repo", appendSystemPrompt: "Be brief." }, "m", "default");
  const append = (options.systemPrompt as { append: string }).append;
  assert.match(append, /```worktime-action\ntitle:/);
  assert.match(append, /prompt: \|/);
  assert.match(append, /```worktime-review\n\{"pr":/);
  assert.match(append, /never post, approve or comment yourself/);
  assert.match(append, /send_to_main/);
  assert.match(append, /Report from <name>/);
  assert.ok(append.endsWith("Be brief."));
});

test("the app's own instruction texts replace the built-in ones, and a blank one falls back", () => {
  const options = sessionOptions(
    { cwd: "/repo", instructions: { actions: "Offer steps my way.", review: "   ", report: "Report my way." } },
    "m",
    "default",
  );
  const append = (options.systemPrompt as { append: string }).append;
  assert.match(append, /Offer steps my way\./);
  assert.doesNotMatch(append, /Keep the sentence before the block short/);
  assert.match(append, /worktime-review/);
  assert.match(append, /Report my way\./);
  assert.doesNotMatch(append, /Send one report per job/);
});
