import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentDefinition } from "@anthropic-ai/claude-agent-sdk";

function frontmatter(text: string): { fields: Record<string, string>; body: string } | undefined {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!match) return undefined;
  const fields: Record<string, string> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const pair = /^([A-Za-z_-]+):\s*(.*)$/.exec(line);
    if (pair) fields[pair[1]] = pair[2].trim().replace(/^(["'])(.*)\1$/, "$2");
  }
  return { fields, body: match[2].trim() };
}

/// The agents in ~/.claude/agents as subagent definitions. Only these are taken from the user's settings, so their hooks,
/// skills and instructions stay out of the app's agents.
export function userSubagents(home: string | undefined): Record<string, AgentDefinition> {
  if (!home) return {};
  const folder = join(home, ".claude", "agents");
  let files: string[];
  try {
    files = readdirSync(folder).filter((file) => file.endsWith(".md"));
  } catch {
    return {};
  }
  const agents: Record<string, AgentDefinition> = {};
  for (const file of files) {
    try {
      const parsed = frontmatter(readFileSync(join(folder, file), "utf8"));
      const { name, description, tools, model } = parsed?.fields ?? {};
      if (!parsed || !name || !description || !parsed.body) continue;
      const list = tools && tools !== "*" ? tools.split(",").map((tool) => tool.trim()).filter(Boolean) : [];
      agents[name] = { description, prompt: parsed.body, ...(list.length > 0 ? { tools: list } : {}), ...(model ? { model } : {}) };
    } catch {
      continue;
    }
  }
  return agents;
}
