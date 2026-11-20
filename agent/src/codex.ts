import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { validImages, type PromptImage } from "./images.js";
import { contextMessage } from "./workmap.js";

export type CodexPrompt = { text: string; images?: PromptImage[]; cwd: string; sessionId?: string; model?: string; permissionMode?: string; appendSystemPrompt?: string };
export type CodexControl = { type: "permission"; id: string; allow: boolean } | { type: "interrupt" };

type Send = (message: Record<string, unknown>) => void;

/// App Server reads the same local WorkTime MCP server Claude gets. Config values are TOML literals; JSON strings are valid TOML strings.
export function codexArgs(mcpCommand: string | undefined, run?: string): string[] {
  const args = ["app-server", "--stdio"];
  if (!mcpCommand) return args;
  args.push("-c", `mcp_servers.worktime.command=${JSON.stringify(mcpCommand)}`,
    "-c", 'mcp_servers.worktime.args=["--mcp"]');
  if (run) args.push("-c", `mcp_servers.worktime.env.WORKTIME_TRACE_RUN=${JSON.stringify(run)}`);
  return args;
}

/// Subscription credentials stay with Codex. An exported API key must not silently change the billing/authentication path.
export function codexEnvironment(environment: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return Object.fromEntries(Object.entries(environment).filter(([key]) => key !== "OPENAI_API_KEY" && key !== "CODEX_API_KEY"));
}

export function codexApprovalSettings(permissionMode: string | undefined) {
  return { approvalPolicy: "on-request", approvalsReviewer: permissionMode === "auto" ? "auto_review" : "user" } as const;
}

export function codexApprovalResponse(allow: boolean) {
  return { decision: allow ? "accept" : "decline" } as const;
}

export function codexContext(params: any) {
  const usage = params?.tokenUsage;
  const tokens = usage?.last?.inputTokens;
  if (typeof tokens !== "number" || !Number.isFinite(tokens) || tokens < 0) return undefined;
  const window = usage?.modelContextWindow;
  return contextMessage(tokens, typeof window === "number" && Number.isFinite(window) && window > 0 ? window : undefined);
}

export function codexThreadRequest(input: CodexPrompt) {
  const approval = codexApprovalSettings(input.permissionMode);
  return input.sessionId
    ? { method: "thread/resume", params: { threadId: input.sessionId, ...approval } }
    : { method: "thread/start", params: { cwd: input.cwd, sandbox: "workspace-write", model: input.model, ...approval } };
}

export function codexTurnParams(input: CodexPrompt, threadId: string) {
  return {
    threadId,
    input: [{ type: "text", text: [input.appendSystemPrompt, input.text].filter(Boolean).join("\n\n") },
      ...validImages(input.images).map(image => ({ type: "image", url: `data:${image.mediaType};base64,${image.data}` }))],
    cwd: input.cwd,
    sandboxPolicy: { type: "workspaceWrite", writableRoots: [input.cwd], networkAccess: false },
    ...codexApprovalSettings(input.permissionMode),
    ...(input.model ? { model: input.model } : {}),
  };
}

/// Small App Server bridge. WorkTime owns approvals; Codex stays signed in through its normal local login.
export class CodexBridge {
  private readonly run = randomUUID();
  private child: ReturnType<typeof spawn> | undefined;
  private request = 0;
  private finished = false;
  private threadID: string | undefined;
  private turnID: string | undefined;
  private approvals = new Map<string, number | string>();
  private nextApproval = 0;
  private output = new Map<string, string>();

  constructor(private readonly send: Send, private readonly onFinish: () => void) {}

  start(input: CodexPrompt) {
    const command = process.env.WORKTIME_CODEX ?? "codex";
    this.child = spawn(command, codexArgs(process.env.WORKTIME_MCP_COMMAND, this.run), { cwd: input.cwd, env: codexEnvironment(process.env), stdio: ["pipe", "pipe", "pipe"] });
    this.child.on("error", (error) => this.finish(`Could not start Codex: ${error.message}`));
    const child = this.child;
    if (!child.stdout || !child.stderr || !child.stdin) return this.finish("Codex could not open its App Server connection.");
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", () => {});
    createInterface({ input: child.stdout }).on("line", (line) => this.receive(line, input));
    this.child.on("close", (code, signal) => {
      if (this.finished) return;
      this.trace("server.exited");
      this.finish(`Codex stopped (${signal ?? `exit ${code}`}).`);
    });
    this.call("initialize", { clientInfo: { name: "worktime", title: "WorkTime", version: "1" } });
  }

  control(input: CodexControl) {
    if (input.type === "interrupt") {
      this.trace(this.threadID && this.turnID ? "interrupt.forwarded" : "interrupt.no_turn");
      if (this.threadID && this.turnID) this.call("turn/interrupt", { threadId: this.threadID, turnId: this.turnID });
      else this.finish("Stopped.");
      return;
    }
    const requestID = this.approvals.get(input.id);
    this.approvals.delete(input.id);
    if (requestID !== undefined) this.write({ id: requestID, result: codexApprovalResponse(input.allow) });
  }

  private receive(line: string, input: CodexPrompt) {
    if (this.finished) return;
    let message: any;
    try { message = JSON.parse(line); } catch { return; }
    if (message.id !== undefined && message.id === 1) {
      this.write({ method: "initialized", params: {} });
      const request = codexThreadRequest(input);
      this.call(request.method, request.params);
      return;
    }
    if (message.id !== undefined && message.result?.thread?.id && !this.threadID) {
      const threadID = String(message.result.thread.id);
      this.threadID = threadID;
      this.send({ type: "session", sessionId: threadID });
      this.call("turn/start", codexTurnParams(input, threadID));
      return;
    }
    if (message.method === "item/commandExecution/requestApproval") return this.approval(message, "Bash", { command: message.params?.command ?? message.params?.reason ?? "Command" });
    if (message.method === "item/fileChange/requestApproval") return this.approval(message, "Edit", { file_path: message.params?.grantRoot ?? "Files in this project" });
    if (message.method === "thread/tokenUsage/updated") {
      const context = codexContext(message.params);
      if (context) this.send(context);
      return;
    }
    if (message.method === "item/agentMessage/delta") return this.send({ type: "text_delta", text: message.params?.delta ?? "" });
    if (message.method === "item/commandExecution/outputDelta") {
      const id = message.params?.itemId ?? "command";
      this.output.set(id, (this.output.get(id) ?? "") + (message.params?.delta ?? ""));
      return;
    }
    if (message.method === "item/started") return this.item(message.params?.item);
    if (message.method === "item/completed") return this.item(message.params?.item, true);
    if (message.method === "mcpServer/elicitation/request") this.trace("approval.elicitation.received");
    if (message.method === "turn/started") { this.turnID = message.params?.turn?.id; this.trace("turn.started"); return; }
    if (message.method === "turn/completed") {
      const status = message.params?.turn?.status;
      this.trace(["completed", "failed", "interrupted"].includes(status) ? `turn.${status}` : "turn.unknown");
      this.finish(message.params?.turn?.error?.message ?? (status === "completed" ? undefined : status === "interrupted" ? "Stopped." : "Codex did not complete the turn."));
      return;
    }
    if (message.error) this.finish(message.error.message ?? "Codex failed.");
  }

  private item(item: any, completed = false) {
    if (!item) return;
    if (item.type === "commandExecution") {
      this.send({ type: "tool_use", id: item.id, tool: "Bash", input: { command: item.command ?? "" } });
      if (completed) this.send({ type: "tool_result", id: item.id, content: this.output.get(item.id) ?? item.aggregatedOutput ?? "", isError: item.status === "failed" });
    } else if (item.type === "fileChange") {
      const paths = (item.changes ?? []).map((change: any) => change.path).join("\n");
      this.send({ type: "tool_use", id: item.id, tool: "Edit", input: { file_path: paths || "Files" } });
      if (completed) this.send({ type: "tool_result", id: item.id, content: paths, isError: item.status === "failed" });
    } else if (item.type === "mcpToolCall") {
      if (item.server === "worktime" && item.tool === "send_to_main")
        this.trace(!completed ? "report.tool.started" : item.status === "failed" || item.result?.isError ? "report.tool.failed" : "report.tool.completed");
      const tool = `mcp__${item.server}__${item.tool}`;
      this.send({ type: "tool_use", id: item.id, tool, input: item.arguments ?? {} });
      if (completed) this.send({ type: "tool_result", id: item.id, content: JSON.stringify(item.result ?? item.error ?? ""), isError: item.status === "failed" });
    } else if (completed && item.type === "agentMessage") this.send({ type: "text", text: item.text ?? "" });
  }

  private approval(message: any, tool: string, input: Record<string, unknown>) {
    const id = `codex-${++this.nextApproval}`;
    this.approvals.set(id, message.id);
    this.send({ type: "permission_request", id, tool, input, offer: [] });
  }

  private trace(stage: string) { this.send({ type: "codex_diagnostic", stage, run: this.run, session: this.threadID, turn: this.turnID }); }
  private call(method: string, params: Record<string, unknown>) { this.write({ method, id: ++this.request, params }); }
  private write(message: Record<string, unknown>) { this.child?.stdin?.write(JSON.stringify(message) + "\n"); }
  private finish(error?: string) {
    if (this.finished) return;
    this.finished = true;
    const failed = error !== undefined;
    this.send({ type: "result", sessionId: this.threadID, isError: failed, text: error ?? "", model: "Codex" });
    this.send({ type: "idle", completed: !failed });
    this.turnID = undefined;
    this.child?.kill();
    this.child = undefined;
    this.onFinish();
  }
}
