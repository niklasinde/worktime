import { createInterface } from "node:readline";
import { missingFolderError } from "./folder.js";
import { query, type HookCallback, type PermissionResult, type Query } from "@anthropic-ai/claude-agent-sdk";
import { ChromeTabs, chromeResultStatus, chromeServerStatus, isChromeTool } from "./chrome.js";
import { mcpServers, sessionOptions, type PromptOptions } from "./options.js";
import { parseMode, preToolDecision, selfReport, type Decision, type Mode, type RoleTier } from "./permissions.js";
import { contextWindow, hookMessage, reportedContext, usageContext } from "./workmap.js";
import { TextStream } from "./stream.js";
import { userMessage, type PromptImage } from "./images.js";
import { actionInstructions, reportInstructions, reviewInstructions } from "./actions.js";
import { userContext } from "./usercontext.js";
import { PromptQueue } from "./promptqueue.js";
import { RoleWaits } from "./rolewait.js";
import { usageFrom } from "./usage.js";
import { delegateTool, hasDelegateRules, isSessionAllowable, matchDelegate, parseRules, sessionKey, suggestRules, type Rule } from "./rules.js";
import { CodexBridge } from "./codex.js";

type Input =
  | ({ type: "prompt"; text: string; model?: string; provider?: "claude" | "codex"; permissionMode?: string; images?: PromptImage[] } & PromptOptions)
  | { type: "message"; id: string; text: string; images?: PromptImage[] }
  | { type: "cancel_message"; id: string }
  | { type: "permission"; id: string; allow: boolean; session?: boolean; add?: boolean; message?: string }
  | { type: "target"; id: string; key?: string }
  | { type: "mode"; mode: string }
  | { type: "interrupt" }
  | { type: "rules"; rules: unknown }
  | { type: "chrome_hosts"; hosts: string[] }
  | { type: "revoke_session"; key?: string }
  | { type: "allow_session"; key: string };

const model = process.env.WORKTIME_AGENT_MODEL ?? "claude-opus-5-5";
/// Tool calls allowed without asking, with the rule that allowed them when it was one of the user's.
const autoAllowed = new Map<string, string | undefined>();
/// Claude in Chrome calls waiting for their result, which tells whether the extension is connected.
const chromeCalls = new Map<string, { tool: string; input: Record<string, unknown> }>();
const chromeTabs = new ChromeTabs();
/// The sites the user allowed Claude in Chrome on, as the app last sent them.
let chromeHosts: string[] = [];
let rules: Rule[] = [];
/// The calls the user allowed for the rest of this session, by `sessionKey`.
const sessionAllowed = new Set<string>();

function reportSessionAllowed() {
  send({ type: "session_allowed", keys: [...sessionAllowed] });
}
/// What each waiting permission prompt would add to `sessionAllowed`, nothing for a tool that cannot be allowed for the session.
const sessionKeys = new Map<string, string | undefined>();
/// WorkTime tools the user added to the assistant's list, or allowed it to use for the rest of this session, after the list left them out.
const roleAdded = new Set<string>();
/// The questions about a tool the assistant's list leaves out that wait for the user.
const roleWaits = new RoleWaits();
const resultLimit = 4000;
const authErrors = ["authentication_failed", "oauth_org_not_allowed"];
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].includes(key)));

const stream = new TextStream(send);
const resolving = new Map<string, (key?: string) => void>();
const resolveTimeout = 5000;
const pending = new Map<string, (result: PermissionResult) => void>();
let running: { query: Query; abort: AbortController; queue: PromptQueue } | undefined;
let codex: CodexBridge | undefined;
let nextPermission = 0;
let mode: Mode = "default";
/// Calls the user allowed in the PreToolUse hook, so canUseTool does not ask a second time.
const hookAllowed = new Set<string>();
/// A hook waits as long as the user takes to answer.
const hookTimeout = 24 * 3600;
/// The context window of the models used so far, and the model turn the context was last reported for.
let knownWindow: number | undefined;
let reportedTurn: string | undefined;

/// How full the context window is after a model turn: asked of the session, else worked out from the turn's usage.
function reportContext(usage: unknown) {
  const fallback = () => usageContext(usage, knownWindow);
  const report = (context: Record<string, unknown> | undefined) => context && send(context);
  const current = running?.query;
  if (!current) return report(fallback());
  current.getContextUsage({ detail: "summary" }).then((answer) => report(reportedContext(answer) ?? fallback()), () => report(fallback()));
}

/// The key the app would deliver this send_to_agent call to, resolved by the same code as the tool; undefined when unclear.
function resolveTarget(input: Record<string, unknown>): Promise<string | undefined> {
  return new Promise((resolve) => {
    const id = String(++nextPermission);
    const timer = setTimeout(() => resolving.delete(id) && resolve(undefined), resolveTimeout);
    resolving.set(id, (key) => (clearTimeout(timer), resolve(key)));
    send({ type: "resolve_target", id, input });
  });
}

/// The decision for a call; a send_to_agent from a Main is looked at against its delegate rules first.
async function decide(tool: string, input: Record<string, unknown>, options: PromptOptions) {
  const own = selfReport(tool, input, options.delegateFrom);
  if (own) return { kind: "deny", reason: own } as Decision;
  const check = tool === delegateTool && hasDelegateRules(rules, options.delegateFrom);
  const delegated = check ? matchDelegate(rules, options.delegateFrom, await resolveTarget(input)) : undefined;
  const listed = options.allowedMcpTools && [...options.allowedMcpTools, ...roleAdded];
  return preToolDecision(tool, input, options.cwd, rules, mode, listed, delegated, sessionAllowed, options.allowAllChrome === true, chromeTabs.hostFor(tool, input), chromeHosts);
}

/// Asks the user about a tool the assistant's list leaves out, and waits: the turn goes on as soon as the answer comes.
function askRole(tool: string, input: Record<string, unknown>, tier: RoleTier, options: PromptOptions, toolUseId?: string) {
  const id = String(++nextPermission);
  const limit = options.roleWaitSeconds ? options.roleWaitSeconds * 1000 : undefined;
  const answer = roleWaits.ask(id, tool, limit, () => send({ type: "role_timeout", id }));
  send({ type: "permission_request", id, toolUseId, tool, input, roleTool: true, tier, offer: [], waitSeconds: options.roleWaitSeconds });
  return answer;
}

function ask(tool: string, input: Record<string, unknown>, cwd: string, toolUseId?: string): Promise<PermissionResult> {
  return new Promise((resolve) => {
    const id = String(++nextPermission);
    pending.set(id, resolve);
    sessionKeys.set(id, isSessionAllowable(tool) ? sessionKey(tool, input) : undefined);
    send({ type: "permission_request", id, toolUseId, tool, input, offer: suggestRules(tool, input, cwd), site: isChromeTool(tool) ? chromeTabs.hostFor(tool, input) : undefined });
  });
}

/// Applies an allow decision: read-only commands and rule matches are marked auto in the transcript.
function allowed(decision: Extract<Decision, { kind: "allow" }>, toolUseID: string): PermissionResult {
  if (decision.readOnly || decision.rule) autoAllowed.set(toolUseID, decision.rule);
  return { behavior: "allow" };
}

/// Runs before the mode decides, so the read-only list and saved rules apply in every mode and send_to_agent is asked
/// of the user even where the auto mode classifier would otherwise answer.
function preToolUse(options: PromptOptions): HookCallback {
  return async (hook) => {
    if (hook.hook_event_name !== "PreToolUse") return {};
    const input = (hook.tool_input ?? {}) as Record<string, unknown>;
    const cwd = options.cwd;
    let decision = await decide(hook.tool_name, input, options);
    if (decision.kind === "missing") {
      const answer = await askRole(hook.tool_name, input, decision.tier, options, hook.tool_use_id);
      if (!answer.allow) {
        return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: answer.message ?? "The user denied this tool call." } };
      }
      if (answer.add || answer.session) {
        roleAdded.add(hook.tool_name);
        decision = await decide(hook.tool_name, input, options);
      } else {
        hookAllowed.add(hook.tool_use_id);
        return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } };
      }
    }
    if (decision.kind === "defer") return {};
    if (decision.kind === "deny") {
      return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: decision.reason } };
    }
    const result = decision.kind === "allow" ? allowed(decision, hook.tool_use_id) : await ask(hook.tool_name, input, cwd, hook.tool_use_id);
    if (result.behavior === "allow") hookAllowed.add(hook.tool_use_id);
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse", permissionDecision: result.behavior === "allow" ? "allow" : "deny",
        ...(result.behavior === "deny" ? { permissionDecisionReason: result.message } : {}),
      },
    };
  };
}

function send(message: Record<string, unknown>) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function resultText(content: unknown): string {
  const text = typeof content === "string" ? content
    : Array.isArray(content) ? content.map((part) => (part?.type === "text" ? part.text : `[${part?.type ?? "content"}]`)).join("\n")
    : JSON.stringify(content ?? "");
  return text.length > resultLimit ? text.slice(0, resultLimit) + "\n…" : text;
}

function forward(message: any, model: string) {
  if (message.type === "stream_event") return stream.receive(message);
  stream.flush();
  switch (message.type) {
    case "system":
      if (message.subtype === "init") {
        send({ type: "session", sessionId: message.session_id });
        const chrome = chromeServerStatus(message.mcp_servers);
        if (chrome && !chrome.connected) send({ type: "chrome", ...chrome });
      } else {
        const hook = hookMessage(message);
        if (hook) send(hook);
      }
      break;
    case "assistant":
      if (authErrors.includes(message.error)) {
        return send({ type: "error", message: resultText(message.message?.content) || message.error, auth: true });
      }
      for (const block of message.message?.content ?? []) {
        if (block.type === "text" && block.text && !message.parent_tool_use_id) send({ type: "text", text: block.text });
        if (block.type === "tool_use") {
          send({ type: "tool_use", id: block.id, tool: block.name, input: block.input ?? {} });
          if (isChromeTool(block.name)) chromeCalls.set(block.id, { tool: block.name, input: block.input ?? {} });
        }
      }
      if (!message.parent_tool_use_id && message.message?.id && message.message.id !== reportedTurn) {
        reportedTurn = message.message.id;
        reportContext(message.message.usage);
      }
      break;
    case "user":
      if (!Array.isArray(message.message?.content)) break;
      for (const block of message.message.content) {
        if (block.type === "tool_result") {
          const rule = autoAllowed.get(block.tool_use_id);
          send({
            type: "tool_result", id: block.tool_use_id, content: resultText(block.content), isError: block.is_error === true,
            auto: autoAllowed.delete(block.tool_use_id), rule,
          });
          const call = chromeCalls.get(block.tool_use_id);
          chromeCalls.delete(block.tool_use_id);
          if (call && block.is_error !== true) chromeTabs.record(call.tool, call.input, resultText(block.content));
          const chrome = call ? chromeResultStatus(block.is_error === true, resultText(block.content)) : undefined;
          if (chrome) send({ type: "chrome", ...chrome });
        }
      }
      break;
    case "result":
      knownWindow = contextWindow(message.modelUsage) ?? knownWindow;
      send({
        type: "result", sessionId: message.session_id, isError: message.is_error === true || message.subtype !== "success",
        text: message.result ?? (message.errors ?? []).join("\n"), turns: message.num_turns, model, permissionMode: mode,
        usage: usageFrom(message),
      });
      break;
  }
}

/// Tells the app these held messages reached the agent (`delivered`) or were taken back (`cancelled`).
function report(type: "delivered" | "cancelled", ids: string[]) {
  for (const id of ids) send({ type, id });
}

function denyPending(reason: string) {
  for (const resolve of pending.values()) resolve({ behavior: "deny", message: reason, interrupt: true });
  roleWaits.denyAll(reason);
  pending.clear();
  sessionKeys.clear();
}

async function run(input: Extract<Input, { type: "prompt" }>) {
  if (input.provider === "codex") return runCodex(input);
  if (running) return send({ type: "error", message: "The agent is still working on the previous prompt." });
  const missing = missingFolderError(input.cwd);
  if (missing) {
    send(missing);
    return send({ type: "idle" });
  }
  const abort = new AbortController();
  const promptModel = input.model || model;
  mode = parseMode(input.permissionMode);
  const queue = new PromptQueue(userMessage(input.text, input.images));
  const current = query({
    prompt: queue,
    options: {
      ...sessionOptions(input, promptModel, mode),
      env,
      mcpServers: mcpServers(process.env),
      abortController: abort,
      includeHookEvents: true,
      hooks: {
        PreToolUse: [{ hooks: [preToolUse(input)], timeout: hookTimeout }],
        PostToolBatch: [{ hooks: [async () => (report("delivered", queue.release()), {})] }],
      },
      canUseTool: async (tool, toolInput, { toolUseID }) => {
        if (hookAllowed.delete(toolUseID)) return { behavior: "allow" };
        const decision = await decide(tool, toolInput, input);
        if (decision.kind === "deny") return { behavior: "deny", message: decision.reason };
        if (decision.kind === "missing") return { behavior: "deny", message: `${tool} is not one of this assistant's tools.` };
        return decision.kind === "allow" ? allowed(decision, toolUseID) : ask(tool, toolInput, input.cwd, toolUseID);
      },
    },
  });
  running = { query: current, abort, queue };
  let finished = false;
  try {
    for await (const message of current) {
      forward(message, promptModel);
      if (message.type !== "result") continue;
      finished = true;
      if (queue.hasHeld) report("delivered", queue.release());
      else queue.end();
    }
  } catch (error) {
    stream.flush();
    if (!finished) {
      send(abort.signal.aborted ? { type: "error", message: "Stopped." }
        : missingFolderError(input.cwd) ?? { type: "error", message: String((error as Error)?.message ?? error) });
    }
  } finally {
    stream.flush();
    report("cancelled", queue.drop());
    denyPending("The prompt ended.");
    autoAllowed.clear();
    hookAllowed.clear();
    chromeCalls.clear();
    running = undefined;
    send({ type: "idle" });
  }
}

function runCodex(input: Extract<Input, { type: "prompt" }>) {
  if (running || codex) return send({ type: "error", message: "The agent is still working on the previous prompt." });
  const missing = missingFolderError(input.cwd);
  if (missing) { send(missing); return send({ type: "idle" }); }
  const { actions, review, report, where } = input.instructions ?? {};
  const append = [userContext(process.env.HOME, input.cwd), actions ?? actionInstructions, review ?? reviewInstructions,
    report ?? reportInstructions, where, input.appendSystemPrompt].filter(Boolean).join("\n\n");
  codex = new CodexBridge(send, () => { codex = undefined; });
  codex.start({ text: input.text, images: input.images, cwd: input.cwd, sessionId: input.sessionId, model: input.model,
    permissionMode: input.permissionMode, appendSystemPrompt: append });
}

function handle(line: string) {
  let input: Input;
  try {
    input = JSON.parse(line);
  } catch {
    return send({ type: "error", message: "Not a JSON line." });
  }
  switch (input.type) {
    case "prompt":
      chromeHosts = input.allowedChromeHosts ?? chromeHosts;
      void run(input);
      break;
    case "message": {
      const queue = running?.queue;
      if (!queue || queue.ended) return send({ type: "cancelled", id: input.id });
      queue.hold(input.id, userMessage(input.text, input.images));
      break;
    }
    case "cancel_message":
      if (running?.queue.cancel(input.id)) send({ type: "cancelled", id: input.id });
      break;
    case "permission": {
      if (codex) { codex.control({ type: "permission", id: input.id, allow: input.allow }); return; }
      if (roleWaits.answer(input.id, { allow: input.allow, add: input.add === true, session: input.session === true, message: input.message })) return;
      const resolve = pending.get(input.id);
      pending.delete(input.id);
      const key = sessionKeys.get(input.id);
      sessionKeys.delete(input.id);
      if (input.allow && input.session && key && !sessionAllowed.has(key)) {
        sessionAllowed.add(key);
        reportSessionAllowed();
      }
      resolve?.(input.allow ? { behavior: "allow" } : { behavior: "deny", message: input.message ?? "The user denied this tool call." });
      break;
    }
    case "target": {
      const resolve = resolving.get(input.id);
      resolving.delete(input.id);
      resolve?.(input.key);
      break;
    }
    case "mode":
      mode = parseMode(input.mode);
      running?.query.setPermissionMode(mode).catch(() => {});
      break;
    case "rules":
      rules = parseRules(input.rules);
      break;
    case "chrome_hosts":
      chromeHosts = input.hosts;
      break;
    case "allow_session":
      if (isSessionAllowable(input.key) && !sessionAllowed.has(input.key)) {
        sessionAllowed.add(input.key);
        reportSessionAllowed();
      }
      break;
    case "revoke_session":
      if (input.key === undefined) sessionAllowed.clear();
      else sessionAllowed.delete(input.key);
      reportSessionAllowed();
      break;
    case "interrupt":
      if (codex) { codex.control({ type: "interrupt" }); return; }
      denyPending("The user stopped the agent.");
      if (running) report("cancelled", running.queue.drop());
      if (running) running.query.interrupt().catch(() => running?.abort.abort());
      break;
    default:
      send({ type: "error", message: `Unknown message type: ${(input as { type?: string }).type}` });
  }
}

send({ type: "ready", model });
createInterface({ input: process.stdin }).on("line", (line) => line.trim() && handle(line)).on("close", () => {
  running?.abort.abort();
  process.exit(0);
});
