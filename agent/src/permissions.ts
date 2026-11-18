import { isChromeRead, isChromeTool, siteAllowed } from "./chrome.js";
import { builtInAllowed, isAutoAllowedTool, isReadOnlyCommand } from "./readonly.js";
import { isSessionAllowable, matchRules, sessionKey, type Rule } from "./rules.js";

/// The permission modes the app offers. bypassPermissions and dontAsk are never passed on.
export const modes = ["default", "auto", "acceptEdits", "plan"] as const;
export type Mode = (typeof modes)[number];

export function parseMode(value: unknown): Mode {
  return modes.find((m) => m === value) ?? "default";
}

/// What happens to a call before the mode decides: asked of the user in every mode (the tools in `alwaysAsk` unless the user opted
/// that tool out of asking, and never in plan mode), allowed by the read-only list or a
/// saved rule (`rule` names it; undefined for a read-only command, absent for an allowed tool), or left to the mode.
export type Decision = { kind: "ask" } | { kind: "allow"; rule?: string; readOnly?: boolean } | { kind: "defer" } | { kind: "deny"; reason: string }
  | { kind: "missing"; tier: RoleTier };

/// How much asking a WorkTime tool needs once it is on an assistant's list: `read` runs without asking, `ask` asks each time, `risky` asks each
/// time and changes what runs on its own or sends prompts, so adding it to a list carries a warning.
export type RoleTier = "read" | "ask" | "risky";

export function roleTier(tool: string): RoleTier {
  return builtInAllowed.alwaysAskRisky.includes(tool) ? "risky" : builtInAllowed.alwaysAsk.includes(tool) ? "ask" : "read";
}

/// A tool the assistant's list leaves out that the user may add to it: WorkTime's own tools only. Tools of other servers are never added this way.
export function addableToRole(tool: string, allowed: string[] | undefined): boolean {
  return mcpDenied(tool, allowed) && tool.startsWith(builtInAllowed.mcpPrefix);
}

/// An assistant's MCP allowlist: tools of other servers and unlisted ones are refused, whatever the mode or the rules. Claude in
/// Chrome keeps its own rules, notify, its scheduling tools and add_reminder are open to every agent, and tools that are not MCP tools follow
/// the permission mode.
export function mcpDenied(tool: string, allowed: string[] | undefined): boolean {
  return allowed !== undefined && tool.startsWith("mcp__") && !isChromeTool(tool) && !allowed.includes(tool) && !builtInAllowed.everyAgent.includes(tool);
}

export const sessionRule = "this session";

export const reportTool = "mcp__worktime__send_to_main";
export const sendTool = "mcp__worktime__send_to_agent";

/// A Main reporting to its own workspace's Main, with send_to_main or send_to_agent addressed to Main: refused before the user is asked, as the app would refuse it after.
export function selfReport(tool: string, input: Record<string, unknown>, delegateFrom?: string): string | undefined {
  const agent = typeof input.agent === "string" ? input.agent.trim() : "";
  const toMain = tool === reportTool || (tool === sendTool && /^main(:|$)/i.test(agent));
  if (!toMain || !delegateFrom) return undefined;
  const named = typeof input.workspace === "string" ? input.workspace.trim() : "";
  const to = (named || (agent.includes(":") ? agent.slice(agent.indexOf(":") + 1) : "")).toLowerCase();
  return to === "" || to === delegateFrom.toLowerCase() ? "This is the Main of that workspace: a report goes to a Main from another agent. Say it in your own reply." : undefined;
}

/// Claude in Chrome acts in the user's own browser, so only its reads and the calls the user allowed (for this session, or
/// with a saved rule for that tool or computer action) run without asking, in every mode, and all of them when `allowAllChrome` is on. `sessionAllowed` holds those calls' `sessionKey`s.
/// A call whose site is in `allowedHosts` runs too; `chromeHost` is the site it acts on, undefined when that is not known.
/// `delegated` is the delegate rule that lets this call of send_to_agent through, the only thing that does.
export function preToolDecision(tool: string, input: Record<string, unknown>, cwd: string, rules: Rule[], mode: Mode, allowedMcp?: string[], delegated?: string,
                                sessionAllowed: ReadonlySet<string> = new Set(), allowAllChrome = false, chromeHost?: string, allowedHosts: readonly string[] = []): Decision {
  const session = isSessionAllowable(tool) && sessionAllowed.has(sessionKey(tool, input));
  if (addableToRole(tool, allowedMcp)) return { kind: "missing", tier: roleTier(tool) };
  if (mcpDenied(tool, allowedMcp)) return { kind: "deny", reason: `${tool} is not one of this assistant's tools, and tools of other servers cannot be added to its list. Its role file lists the tools it may use.` };
  if (isChromeTool(tool)) {
    if (allowAllChrome) return { kind: "allow", rule: "Allow all Claude in Chrome" };
    if (isChromeRead(tool, input)) return { kind: "allow", readOnly: true };
    if (session) return { kind: "allow", rule: sessionRule };
    if (chromeHost && siteAllowed(chromeHost, allowedHosts)) return { kind: "allow", rule: `Allowed site ${chromeHost}` };
    const rule = matchRules(rules, tool, input, cwd);
    return rule ? { kind: "allow", rule } : { kind: "ask" };
  }
  if (builtInAllowed.alwaysAsk.includes(tool)) {
    if (delegated) return { kind: "allow", rule: delegated };
    if (mode === "plan") return { kind: "ask" };
    if (session) return { kind: "allow", rule: sessionRule };
    const rule = matchRules(rules, tool, input, cwd);
    return rule ? { kind: "allow", rule } : { kind: "ask" };
  }
  if (isAutoAllowedTool(tool)) return { kind: "allow" };
  if (tool === "Bash" && typeof input.command === "string" && isReadOnlyCommand(input.command)) return { kind: "allow", readOnly: true };
  if (mode === "plan") return { kind: "defer" };
  if (session) return { kind: "allow", rule: sessionRule };
  const rule = matchRules(rules, tool, input, cwd);
  return rule ? { kind: "allow", rule } : { kind: "defer" };
}
