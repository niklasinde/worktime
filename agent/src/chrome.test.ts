import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { chromeResultStatus, chromeServerStatus, isChromeRead, isChromeTool } from "./chrome.js";
import { sessionOptions } from "./options.js";
import { modes, preToolDecision } from "./permissions.js";
import { matchRules, suggestRules } from "./rules.js";

const chrome = (name: string) => `mcp__claude-in-chrome__${name}`;
const actions = ["navigate", "computer", "form_input", "javascript_tool", "file_upload", "upload_image", "tabs_create_mcp", "tabs_close_mcp",
  "resize_window", "select_browser", "switch_browser", "browser_batch", "gif_creator", "read_console_messages", "read_network_requests"];

test("the options pass --chrome when on and --no-chrome when off", () => {
  assert.deepEqual(sessionOptions({ cwd: "/repo", chrome: true }, "m", "default").extraArgs, { chrome: null });
  assert.deepEqual(sessionOptions({ cwd: "/repo" }, "m", "default").extraArgs, { "no-chrome": null });
  const options = sessionOptions({ cwd: "/repo", sessionId: "s", appendSystemPrompt: "x" }, "m", "plan");
  assert.equal(options.resume, "s");
  assert.equal(options.permissionMode, "plan");
});

test("the flag reaches the spawned Claude Code process", async () => {
  const folder = mkdtempSync(join(tmpdir(), "worktime-chrome-"));
  const args = join(folder, "args"), fake = join(folder, "claude");
  writeFileSync(fake, `#!/bin/sh\nprintf '%s\\n' "$@" > "${args}"\nexit 3\n`);
  chmodSync(fake, 0o755);
  for (const enabled of [true, false]) {
    const run = query({ prompt: "x", options: { ...sessionOptions({ cwd: folder, chrome: enabled }, "m", "default"), pathToClaudeCodeExecutable: fake } });
    await assert.rejects(async () => { for await (const _ of run) { /* the fake exits at once */ } });
    const passed = readFileSync(args, "utf8").split("\n");
    assert.equal(passed.includes("--chrome"), enabled, passed.join(" "));
    assert.equal(passed.includes("--no-chrome"), !enabled, passed.join(" "));
  }
});

test("only Chrome's reads run without asking, in every mode; actions ask until the user saves a rule for that tool or action", () => {
  for (const mode of modes) {
    for (const name of ["tabs_context_mcp", "read_page", "get_page_text", "find", "list_connected_browsers"]) {
      assert.deepEqual(preToolDecision(chrome(name), {}, "/repo", [], mode), { kind: "allow", readOnly: true }, `${mode} ${name}`);
    }
    assert.deepEqual(preToolDecision(chrome("computer"), { action: "screenshot" }, "/repo", [], mode), { kind: "allow", readOnly: true });
    for (const action of ["left_click", "type", "key", "scroll", "left_click_drag", undefined]) {
      assert.deepEqual(preToolDecision(chrome("computer"), { action }, "/repo", [], mode), { kind: "ask" }, `${mode} ${action}`);
    }
    for (const name of actions.filter((a) => a !== "computer")) {
      assert.deepEqual(preToolDecision(chrome(name), {}, "/repo", [], mode), { kind: "ask" }, `${mode} ${name}`);
    }
  }
  assert.deepEqual(preToolDecision("mcp__Claude_in_Chrome__navigate", {}, "/repo", [], "auto"), { kind: "ask" });
  assert.ok(isChromeTool(chrome("navigate")) && !isChromeTool("mcp__worktime__github_pr") && !isChromeRead("Read", {}));
});

test("Always allow on a Chrome action saves that tool, or that computer action, and nothing wider", () => {
  assert.deepEqual(suggestRules(chrome("javascript_tool"), {}, "/repo"), [{ kind: "tool", value: chrome("javascript_tool") }]);
  assert.deepEqual(suggestRules(chrome("computer"), { action: "left_click" }, "/repo"), [{ kind: "tool", value: `${chrome("computer")}:left_click` }]);
  assert.deepEqual(suggestRules(chrome("read_page"), {}, "/repo"), []);
  const rules = [{ kind: "tool" as const, value: chrome("javascript_tool") }, { kind: "tool" as const, value: `${chrome("computer")}:left_click` }];
  for (const mode of modes) {
    assert.deepEqual(preToolDecision(chrome("javascript_tool"), {}, "/repo", rules, mode), { kind: "allow", rule: chrome("javascript_tool") }, mode);
    assert.deepEqual(preToolDecision(chrome("computer"), { action: "left_click" }, "/repo", rules, mode).kind, "allow", mode);
    assert.deepEqual(preToolDecision(chrome("computer"), { action: "type" }, "/repo", rules, mode), { kind: "ask" }, mode);
    assert.deepEqual(preToolDecision(chrome("navigate"), {}, "/repo", rules, mode), { kind: "ask" }, mode);
  }
  assert.equal(matchRules([{ kind: "tool", value: chrome("computer") }], chrome("computer"), { action: "left_click" }, "/repo"), undefined);
});

test("the connection is read from the server list and from tool errors that are about it", () => {
  assert.equal(chromeServerStatus(undefined), undefined);
  assert.equal(chromeServerStatus([{ name: "worktime", status: "connected" }]), undefined);
  assert.deepEqual(chromeServerStatus([{ name: "claude-in-chrome", status: "connected" }]), { connected: true });
  assert.deepEqual(chromeServerStatus([{ name: "claude-in-chrome", status: "failed" }]), { connected: false, message: "its MCP server is failed" });
  assert.deepEqual(chromeResultStatus(false, "tabs"), { connected: true });
  const offline = "Browser extension is not connected. Please ensure the Claude browser extension is installed and running.";
  assert.deepEqual(chromeResultStatus(true, offline), { connected: false, message: offline });
  assert.equal(chromeResultStatus(true, "The user denied this tool call."), undefined);
  assert.equal(chromeResultStatus(true, "Element ref_12 not found"), undefined);
});
