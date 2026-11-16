import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { contextLimit, memoryFolder, projectFolders, userContext } from "./usercontext.js";
import { sessionOptions } from "./options.js";

function home(): string {
  const root = mkdtempSync(join(tmpdir(), "usercontext-"));
  mkdirSync(join(root, ".claude"), { recursive: true });
  return root;
}

test("the memory folder follows Claude Code's encoding of the working folder", () => {
  assert.equal(memoryFolder("/h", "/Users/a/My App/x.y"), "/h/.claude/projects/-Users-a-My-App-x-y/memory");
});

test("instructions, the memory index and the files it links come in a fixed order", () => {
  const root = home();
  const memory = memoryFolder(root, "/work/app");
  mkdirSync(memory, { recursive: true });
  writeFileSync(join(root, ".claude", "CLAUDE.md"), "Keep it short.");
  writeFileSync(join(memory, "MEMORY.md"), "- [A](a.md) note\n- [B](b.md) note\n- [Gone](gone.md) note\n- [A again](a.md)");
  writeFileSync(join(memory, "a.md"), "fact a");
  writeFileSync(join(memory, "b.md"), "fact b");
  const text = userContext(root, "/work/app") ?? "";
  const order = ["Keep it short.", "Memory index", "Memory: a.md", "Memory: b.md"].map((part) => text.indexOf(part));
  assert.ok(order.every((at) => at >= 0));
  assert.deepEqual(order, [...order].sort((a, b) => a - b));
  assert.equal(text.split("Memory: a.md").length, 2);
  assert.equal(userContext(root, "/work/app"), text);
});

test("missing files give nothing, and a large memory is cut", () => {
  const root = home();
  assert.equal(userContext(root, "/work/app"), undefined);
  assert.equal(userContext(undefined, "/work/app"), undefined);
  const memory = memoryFolder(root, "/work/app");
  mkdirSync(memory, { recursive: true });
  const names = Array.from({ length: 10 }, (_, index) => `f${index}.md`);
  writeFileSync(join(memory, "MEMORY.md"), names.map((name) => `- [x](${name})`).join("\n"));
  for (const name of names) writeFileSync(join(memory, name), "x".repeat(5000));
  const text = userContext(root, "/work/app") ?? "";
  assert.ok(text.length <= contextLimit + 10);
});

test("project AGENTS.md files come outermost first between the user's instructions and the memory, and CLAUDE.md files are left to the SDK", () => {
  const root = home();
  const repo = join(root, "repo");
  const cwd = join(repo, "app");
  mkdirSync(join(repo, ".git"), { recursive: true });
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(root, "AGENTS.md"), "above the repository");
  writeFileSync(join(repo, "AGENTS.md"), "repo rules");
  writeFileSync(join(repo, "CLAUDE.md"), "claude rules");
  writeFileSync(join(cwd, "AGENTS.md"), "app rules");
  writeFileSync(join(root, ".claude", "CLAUDE.md"), "user rules");
  const memory = memoryFolder(root, cwd);
  mkdirSync(memory, { recursive: true });
  writeFileSync(join(memory, "MEMORY.md"), "- [A](a.md)");
  writeFileSync(join(memory, "a.md"), "fact a");
  assert.deepEqual(projectFolders(root, cwd), [repo, cwd]);
  const text = userContext(root, cwd) ?? "";
  const order = ["user rules", "repo rules", "app rules", "Memory index", "fact a"].map((part) => text.indexOf(part));
  assert.ok(order.every((at) => at >= 0));
  assert.deepEqual(order, [...order].sort((a, b) => a - b));
  assert.ok(!text.includes("claude rules"));
  assert.ok(!text.includes("above the repository"));
});

test("a text that is already included, or already loaded as a CLAUDE.md, is not repeated", () => {
  const root = home();
  const cwd = join(root, "app");
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(root, ".claude", "CLAUDE.md"), "same words");
  writeFileSync(join(root, "AGENTS.md"), "same words");
  writeFileSync(join(cwd, "AGENTS.md"), "shared rules");
  writeFileSync(join(cwd, "CLAUDE.md"), "shared rules");
  const text = userContext(root, cwd) ?? "";
  assert.equal(text.split("same words").length, 2);
  assert.ok(!text.includes("shared rules"));
});

test("the prompt's own append still follows the user's context", () => {
  const root = home();
  writeFileSync(join(root, ".claude", "CLAUDE.md"), "Be brief.");
  const saved = process.env.HOME;
  process.env.HOME = root;
  try {
    const prompt = sessionOptions({ cwd: "/work/app", appendSystemPrompt: "You are a PR agent." }, "m", "default").systemPrompt;
    const append = typeof prompt === "object" && "append" in prompt ? (prompt.append ?? "") : "";
    assert.ok(append.indexOf("Be brief.") < append.indexOf("You are a PR agent."));
  } finally {
    process.env.HOME = saved;
  }
});
