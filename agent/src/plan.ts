/// One-shot: asks Claude Code for the plan limits the `/usage` screen shows and prints them as one JSON line, `{plan}` or `{error}`.
/// It starts a session that is never given a prompt, so no model is called and nothing is saved. The SDK's call for this is experimental.
import { tmpdir } from "node:os";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { planFrom } from "./usage.js";

const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].includes(key)));
const timeout = 45_000;

async function main() {
  const idle = (async function* (): AsyncGenerator<never> {
    await new Promise(() => {});
  })();
  const session = query({
    prompt: idle,
    options: { cwd: tmpdir(), env, settingSources: [], mcpServers: {}, tools: [], persistSession: false },
  });
  const timer = setTimeout(() => {
    console.log(JSON.stringify({ error: "Claude Code did not answer in time." }));
    process.exit(0);
  }, timeout);
  try {
    const answer = await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
    console.log(JSON.stringify({ plan: planFrom(answer as unknown as Record<string, unknown>) ?? null }));
  } catch (error) {
    console.log(JSON.stringify({ error: String((error as Error)?.message ?? error) }));
  } finally {
    clearTimeout(timer);
    session.close();
  }
  process.exit(0);
}

void main();
