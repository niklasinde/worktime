import type { McpServerConfig, Options } from "@anthropic-ai/claude-agent-sdk";
import { actionInstructions, reportInstructions, reviewInstructions } from "./actions.js";
import { chromeArgs } from "./chrome.js";
import { userSubagents } from "./subagents.js";
import { userContext } from "./usercontext.js";
import type { Mode } from "./permissions.js";

export const tools = ["Read", "Grep", "Glob", "Edit", "Write", "Bash", "Agent"];

/// The texts the app resolves from the user's template files for this prompt; a missing one falls back to the sidecar's own copy.
export type Instructions = { actions?: string; review?: string; report?: string };

export type PromptOptions = { cwd: string; sessionId?: string; forkSession?: boolean; appendSystemPrompt?: string; instructions?: Instructions; chrome?: boolean; allowedMcpTools?: string[]; delegateFrom?: string };

/// The session options that come from the prompt; the sidecar adds its environment, MCP servers, hooks and permission callback.
export function sessionOptions(input: PromptOptions, model: string, mode: Mode): Options {
  const pick = (given: string | undefined, fallback: string) => (given && given.trim() ? given : fallback);
  const { actions, review, report } = input.instructions ?? {};
  const append = [
    userContext(process.env.HOME, input.cwd),
    pick(actions, actionInstructions),
    pick(review, reviewInstructions),
    pick(report, reportInstructions),
    input.appendSystemPrompt,
  ].filter(Boolean).join("\n\n");
  return {
    model,
    cwd: input.cwd,
    resume: input.sessionId,
    ...(input.sessionId && input.forkSession === true ? { forkSession: true } : {}),
    tools,
    ...(append ? { systemPrompt: { type: "preset", preset: "claude_code", append } } : {}),
    includePartialMessages: true,
    permissionMode: mode,
    settingSources: ["project"],
    agents: userSubagents(process.env.HOME),
    extraArgs: chromeArgs(input.chrome === true),
  };
}

/// WorkTime's MCP server, started through the app's binary; a Main's workspace reaches it so its tools default to that workspace,
/// and the agent's key so notify knows who sent a notification.
export function mcpServers(env: NodeJS.ProcessEnv): Record<string, McpServerConfig> {
  const command = env.WORKTIME_MCP_COMMAND;
  if (!command) return {};
  const passed = Object.fromEntries(["WORKTIME_WORKSPACE", "WORKTIME_AGENT"].flatMap((key) => (env[key] ? [[key, env[key] as string]] : [])));
  return { worktime: { type: "stdio", command, args: ["--mcp"], ...(Object.keys(passed).length > 0 ? { env: passed } : {}) } };
}
