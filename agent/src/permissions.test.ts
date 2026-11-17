import test from "node:test";
import assert from "node:assert/strict";
import { addableToRole, modes, parseMode, preToolDecision, roleTier, selfReport } from "./permissions.js";
import { builtInAllowed } from "./readonly.js";

const cwd = "/repo";
const rules = [{ kind: "bash" as const, value: "npm test" }, { kind: "edits" as const, value: "/repo" }];

test("only the offered modes pass; anything else is Ask", () => {
  assert.deepEqual([...modes], ["default", "auto", "acceptEdits", "plan"]);
  for (const mode of modes) assert.equal(parseMode(mode), mode);
  for (const other of ["bypassPermissions", "dontAsk", undefined, 3, ""]) assert.equal(parseMode(other), "default");
});

test("send_to_agent, complete_reminder and the routine and assistant changes are asked of the user in every mode", () => {
  for (const mode of modes) {
    for (const tool of ["create_routine", "update_routine", "set_routine_enabled", "delete_routine", "compile_routine", "create_automation", "update_automation", "delete_automation", "create_assistant", "update_assistant", "delete_assistant", "send_to_main"]) {
      assert.deepEqual(preToolDecision(`mcp__worktime__${tool}`, {}, cwd, rules, mode), { kind: "ask" }, `${tool} ${mode}`);
    }
    assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", { text: "x" }, cwd, rules, mode), { kind: "ask" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__complete_reminder", { id: "x" }, cwd, rules, mode), { kind: "ask" }, mode);
  }
});

test("a tool the user opted out of asking runs in every mode but Plan, one for this session too, and send_to_agent only by rule", () => {
  const update = "mcp__worktime__update_routine", create = "mcp__worktime__create_routine", send = "mcp__worktime__send_to_agent";
  const optOut = [{ kind: "tool" as const, value: update }, { kind: "tool" as const, value: send }];
  for (const mode of ["default", "auto", "acceptEdits"] as const) {
    assert.deepEqual(preToolDecision(update, {}, cwd, optOut, mode), { kind: "allow", rule: update }, mode);
    assert.deepEqual(preToolDecision(send, { text: "x" }, cwd, optOut, mode), { kind: "allow", rule: send }, mode);
    assert.deepEqual(preToolDecision(create, {}, cwd, optOut, mode), { kind: "ask" }, `another tool ${mode}`);
    assert.deepEqual(preToolDecision(create, {}, cwd, [], mode, undefined, undefined, new Set([create])), { kind: "allow", rule: "this session" }, mode);
  }
  assert.deepEqual(preToolDecision(update, {}, cwd, optOut, "plan"), { kind: "ask" });
  assert.deepEqual(preToolDecision(create, {}, cwd, [], "plan", undefined, undefined, new Set([create])), { kind: "ask" });
  assert.equal(preToolDecision(update, {}, cwd, optOut, "default", ["mcp__worktime__time_report"]).kind, "missing", "an assistant's allowlist still applies: the user is asked");
});

test("the read-only list and saved rules apply first in every mode but Plan, which keeps only the read-only list", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("Read", {}, cwd, [], mode), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__jira_issue", {}, cwd, [], mode), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("Bash", { command: "git log -3" }, cwd, [], mode), { kind: "allow", readOnly: true }, mode);
  }
  for (const mode of ["default", "auto", "acceptEdits"] as const) {
    assert.deepEqual(preToolDecision("Bash", { command: "npm test" }, cwd, rules, mode), { kind: "allow", rule: "npm test" }, mode);
    assert.deepEqual(preToolDecision("Edit", { file_path: "/repo/a.ts" }, cwd, rules, mode), { kind: "allow", rule: "/repo" }, mode);
  }
  assert.deepEqual(preToolDecision("Bash", { command: "npm test" }, cwd, rules, "plan"), { kind: "defer" });
  assert.deepEqual(preToolDecision("Edit", { file_path: "/repo/a.ts" }, cwd, rules, "plan"), { kind: "defer" });
});

test("the rest is left to the mode: canUseTool asks in Ask, the classifier decides first in Auto", () => {
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("Bash", { command: "rm -rf build" }, cwd, rules, mode), { kind: "defer" }, mode);
    assert.deepEqual(preToolDecision("Write", { file_path: "/elsewhere/x" }, cwd, rules, mode), { kind: "defer" }, mode);
  }
});

test("an assistant's allowlist refuses unlisted MCP tools in every mode and leaves the other tools to the mode", () => {
  const allowed = ["mcp__worktime__time_report", "mcp__worktime__jira_issue"];
  for (const mode of modes) {
    assert.deepEqual(preToolDecision("mcp__worktime__slack_thread", {}, cwd, rules, mode, allowed), { kind: "missing", tier: "read" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", {}, cwd, rules, mode, allowed), { kind: "missing", tier: "risky" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__complete_reminder", {}, cwd, rules, mode, allowed), { kind: "missing", tier: "ask" }, mode);
    assert.equal(preToolDecision("mcp__other__thing", {}, cwd, rules, mode, allowed).kind, "deny", mode);
    assert.deepEqual(preToolDecision("mcp__worktime__time_report", {}, cwd, [], mode, allowed), { kind: "allow" }, mode);
    assert.deepEqual(preToolDecision("Read", {}, cwd, [], mode, allowed), { kind: "allow" }, mode);
    for (const tool of ["notify", "scheduled_notifications", "cancel_notification", "add_reminder"]) {
      assert.deepEqual(preToolDecision(`mcp__worktime__${tool}`, {}, cwd, [], mode, allowed), { kind: "allow" }, `${tool} ${mode}`);
      assert.deepEqual(preToolDecision(`mcp__worktime__${tool}`, {}, cwd, [], mode), { kind: "allow" }, `${tool} ${mode}`);
    }
    assert.deepEqual(preToolDecision("Bash", { command: "rm -rf build" }, cwd, [], mode, allowed), { kind: "defer" }, mode);
  }
  assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", {}, cwd, [], "default", ["mcp__worktime__send_to_agent"]), { kind: "ask" });
  assert.deepEqual(preToolDecision("mcp__worktime__slack_thread", {}, cwd, [], "default", []), { kind: "missing", tier: "read" });
});

test("without an allowlist every MCP tool is decided as before", () => {
  assert.deepEqual(preToolDecision("mcp__worktime__slack_thread", {}, cwd, [], "default"), { kind: "allow" });
});

test("Claude in Chrome is not touched by the allowlist", () => {
  assert.notEqual(preToolDecision("mcp__claude-in-chrome__navigate", {}, cwd, [], "default", []).kind, "deny");
});

test("a call allowed for this session runs without asking, Chrome's too, and an always-asked tool never does", () => {
  const chromeJs = "mcp__claude-in-chrome__javascript_tool";
  const session = new Set([chromeJs, "mcp__claude-in-chrome__computer:left_click", "mcp__worktime__send_to_agent", "mcp__worktime__slack_thread"]);
  for (const mode of modes) {
    assert.deepEqual(preToolDecision(chromeJs, {}, cwd, [], mode, undefined, undefined, session), { kind: "allow", rule: "this session" }, mode);
    assert.deepEqual(preToolDecision("mcp__worktime__send_to_agent", {}, cwd, [], mode, undefined, undefined, session), { kind: "ask" }, mode);
  }
  assert.deepEqual(preToolDecision("mcp__claude-in-chrome__form_input", {}, cwd, [], "default", undefined, undefined, session), { kind: "ask" });
  const computer = "mcp__claude-in-chrome__computer";
  assert.deepEqual(preToolDecision(computer, { action: "left_click" }, cwd, [], "default", undefined, undefined, session), { kind: "allow", rule: "this session" });
  assert.deepEqual(preToolDecision(computer, { action: "type" }, cwd, [], "default", undefined, undefined, session), { kind: "ask" });
  assert.deepEqual(preToolDecision(chromeJs, {}, cwd, [], "default"), { kind: "ask" });
});

test("a session allowance does not reach Bash or the edit tools", () => {
  const session = new Set(["Bash", "Edit"]);
  assert.deepEqual(preToolDecision("Bash", { command: "rm -rf build" }, cwd, [], "default", undefined, undefined, session), { kind: "defer" });
  assert.deepEqual(preToolDecision("Edit", { file_path: `${cwd}/x` }, cwd, [], "default", undefined, undefined, session), { kind: "defer" });
});

test("send_to_main asks in every mode, can be opted out of or allowed for the session, and is open to an unattended run only by the app's own list", () => {
  const send = "mcp__worktime__send_to_main";
  assert.ok(builtInAllowed.alwaysAsk.includes(send) && !builtInAllowed.alwaysAskRisky.includes(send));
  assert.deepEqual(builtInAllowed.unattendedAllowed, [send]);
  for (const mode of modes) assert.deepEqual(preToolDecision(send, { text: "x" }, cwd, [], mode), { kind: "ask" }, mode);
  assert.deepEqual(preToolDecision(send, { text: "x" }, cwd, [{ kind: "tool", value: send }], "default"), { kind: "allow", rule: send });
  assert.deepEqual(preToolDecision(send, { text: "x" }, cwd, [], "default", undefined, undefined, new Set([send])), { kind: "allow", rule: "this session" });
});

test("a Main reporting to its own workspace's Main is refused before anyone is asked, another workspace's is not", () => {
  const send = "mcp__worktime__send_to_main";
  assert.match(selfReport(send, { text: "x" }, "work") ?? "", /Main of that workspace/);
  assert.match(selfReport(send, { text: "x", workspace: " Work " }, "work") ?? "", /Main of that workspace/);
  assert.equal(selfReport(send, { text: "x", workspace: "reviews" }, "work"), undefined);
  assert.equal(selfReport(send, { text: "x" }, undefined), undefined, "an assistant is not a Main");
  assert.equal(selfReport("mcp__worktime__send_to_agent", { text: "x" }, "work"), undefined);
});

test("a tool the list leaves out can be added only when it is one of WorkTime's, and each tier is told apart", () => {
  const allowed = ["mcp__worktime__jira_issue"];
  assert.equal(addableToRole("mcp__worktime__jira_search", allowed), true);
  assert.equal(addableToRole("mcp__worktime__jira_issue", allowed), false, "listed");
  assert.equal(addableToRole("mcp__other__thing", allowed), false, "another server is never added");
  assert.equal(addableToRole("Bash", allowed), false, "not an MCP tool");
  assert.equal(addableToRole("mcp__worktime__jira_search", undefined), false, "no list, no question");
  assert.equal(roleTier("mcp__worktime__jira_search"), "read");
  assert.equal(roleTier("mcp__worktime__update_routine"), "ask");
  assert.equal(roleTier("mcp__worktime__create_routine"), "risky");
});

test("once the tool is on the list a tool that asks by default still asks for each call", () => {
  const allowed = ["mcp__worktime__update_routine"];
  assert.deepEqual(preToolDecision("mcp__worktime__update_routine", {}, cwd, [], "default", allowed), { kind: "ask" });
  assert.deepEqual(preToolDecision("mcp__worktime__jira_search", {}, cwd, [], "default", [...allowed, "mcp__worktime__jira_search"]), { kind: "allow" });
});
