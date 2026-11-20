import assert from "node:assert/strict";
import test from "node:test";
import { CodexBridge, codexApprovalResponse, codexApprovalSettings, codexArgs, codexContext, codexEnvironment, codexThreadRequest, codexTurnParams } from "./codex.js";

test("an interrupted report traces its turn, run and observed interrupt without logging its text", () => {
  const events: Record<string, unknown>[] = [];
  const bridge = new CodexBridge(event => events.push(event), () => {});
  const receive = (method: string, params: unknown) => bridge["receive"](JSON.stringify({ method, params }), { text: "", cwd: "/tmp" });
  receive("turn/started", { turn: { id: "turn-a" } });
  receive("item/started", { item: { type: "mcpToolCall", server: "worktime", tool: "send_to_main", arguments: { text: "private report" } } });
  receive("turn/completed", { turn: { id: "turn-a", status: "interrupted" } });
  const trace = events.filter(event => event.type === "codex_diagnostic");
  assert.deepEqual(trace.map(e => e.stage), ["turn.started", "report.tool.started", "turn.interrupted"]);
  assert.ok(trace.every(e => e.run === trace[0].run && e.turn === "turn-a"));
  assert.ok(!JSON.stringify(trace).includes("private report"));
  assert.ok(codexArgs("/app", String(trace[0].run)).includes(`mcp_servers.worktime.env.WORKTIME_TRACE_RUN="${trace[0].run}"`));
});

test("Codex App Server receives WorkTime's read-only MCP command without an API key", () => {
  assert.deepEqual(codexArgs("/Applications/WorkTime.app/Contents/MacOS/WorkTime"), [
    "app-server", "--stdio",
    "-c", 'mcp_servers.worktime.command="/Applications/WorkTime.app/Contents/MacOS/WorkTime"',
    "-c", 'mcp_servers.worktime.args=["--mcp"]',
  ]);
  assert.deepEqual(codexArgs(undefined), ["app-server", "--stdio"]);
  const environment = codexEnvironment({ OPENAI_API_KEY: "key", CODEX_API_KEY: "other", WORKTIME_MCP_COMMAND: "/app", PATH: "/bin" });
  assert.equal(environment.OPENAI_API_KEY, undefined);
  assert.equal(environment.CODEX_API_KEY, undefined);
  assert.equal(environment.WORKTIME_MCP_COMMAND, "/app");
});

test("Codex routes Ask approvals to the user and Auto approvals to its reviewer", () => {
  assert.deepEqual(codexApprovalResponse(true), { decision: "accept" });
  assert.deepEqual(codexApprovalResponse(false), { decision: "decline" });
  assert.deepEqual(codexApprovalSettings("default"), { approvalPolicy: "on-request", approvalsReviewer: "user" });
  assert.deepEqual(codexApprovalSettings("auto"), { approvalPolicy: "on-request", approvalsReviewer: "auto_review" });

  const fresh = codexThreadRequest({ text: "hello", cwd: "/repo", permissionMode: "auto" });
  assert.equal(fresh.method, "thread/start");
  assert.equal(fresh.params.approvalsReviewer, "auto_review");

  const resumed = codexThreadRequest({ text: "hello", cwd: "/repo", sessionId: "01a1f4ee-e8b2-7d92-93a9-f8499f38914f", permissionMode: "auto" });
  assert.deepEqual(resumed, {
    method: "thread/resume",
    params: {
      threadId: "01a1f4ee-e8b2-7d92-93a9-f8499f38914f",
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
    },
  });

  const turn = codexTurnParams({ text: "hello", cwd: "/repo", permissionMode: "default" }, "thread-1");
  assert.equal(turn.approvalsReviewer, "user");
  assert.equal(turn.approvalPolicy, "on-request");
});

test("Codex reports the thread context size and how full it is", () => {
  assert.deepEqual(codexContext({ tokenUsage: { last: { inputTokens: 40_000 }, total: { totalTokens: 90_000 }, modelContextWindow: 200_000 } }),
    { type: "context", tokens: 40_000, max: 200_000, percent: 20 });
  assert.deepEqual(codexContext({ tokenUsage: { last: { inputTokens: 40_000 }, modelContextWindow: null } }),
    { type: "context", tokens: 40_000 });
  assert.equal(codexContext({ tokenUsage: { last: {}, modelContextWindow: 200_000 } }), undefined);
});

test("only a successfully completed Codex turn lets WorkTime advance its queue", () => {
  for (const status of ["completed", "interrupted", "failed"]) {
    const events: Record<string, unknown>[] = [];
    const bridge = new CodexBridge(event => events.push(event), () => {});
    const completion = JSON.stringify({ method: "turn/completed", params: { turn: { status } } });
    bridge["receive"](completion, { text: "", cwd: "/tmp" });
    bridge["receive"](completion, { text: "", cwd: "/tmp" });
    assert.deepEqual(events.filter(event => event.type === "idle"), [{ type: "idle", completed: status === "completed" }]);
  }
});

test("follow-up turns can send pasted images along with their text", () => {
  const turn = codexTurnParams({ text: "check this", images: [{ mediaType: "image/png", data: "YWJj" }], cwd: "/tmp" }, "thread-a");
  assert.deepEqual(turn.input, [{ type: "text", text: "check this" }, { type: "image", url: "data:image/png;base64,YWJj" }]);
});
