import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { userSubagents } from "./subagents.js";
import { preToolDecision } from "./permissions.js";

test("user agents are read from ~/.claude/agents, skipping files without a name, description or prompt", () => {
  const home = mkdtempSync(join(tmpdir(), "subagents-"));
  const folder = join(home, ".claude", "agents");
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "dev.md"), "---\nname: developer\ndescription: Builds things\nmodel: opus\ntools: Read, Bash\n---\n\nYou build.\n");
  writeFileSync(join(folder, "all.md"), "---\nname: all\ndescription: \"Quoted\"\ntools: *\n---\nBody");
  writeFileSync(join(folder, "bad.md"), "---\nname: bad\n---\nBody");
  writeFileSync(join(folder, "plain.md"), "no frontmatter");
  assert.deepEqual(userSubagents(home), {
    developer: { description: "Builds things", prompt: "You build.", tools: ["Read", "Bash"], model: "opus" },
    all: { description: "Quoted", prompt: "Body" },
  });
  assert.deepEqual(userSubagents(join(home, "missing")), {});
  assert.deepEqual(userSubagents(undefined), {});
});

test("starting a subagent runs without asking, while its own tools follow the usual rules", () => {
  assert.equal(preToolDecision("Agent", {}, "/repo", [], "default").kind, "allow");
  assert.equal(preToolDecision("Bash", { command: "rm -rf x" }, "/repo", [], "default").kind, "defer");
});
