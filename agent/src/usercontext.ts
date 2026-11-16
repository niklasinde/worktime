import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

export const contextLimit = 16_000;
const fileLimit = 3_000;

function read(path: string): string | undefined {
  try {
    const text = readFileSync(path, "utf8").trim();
    return text || undefined;
  } catch {
    return undefined;
  }
}

function clip(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit).trimEnd()}\n[cut]`;
}

/// Where Claude Code keeps the memory of a working folder: every character outside letters and digits becomes a dash.
export function memoryFolder(home: string, cwd: string): string {
  return join(home, ".claude", "projects", cwd.replace(/[^A-Za-z0-9]/g, "-"), "memory");
}

/// The folders from the working folder up to the repository root, or to the home folder when there is no repository, outermost first.
export function projectFolders(home: string, cwd: string): string[] {
  const folders: string[] = [];
  for (let folder = cwd; ; folder = dirname(folder)) {
    folders.unshift(folder);
    if (existsSync(join(folder, ".git")) || folder === home || dirname(folder) === folder) break;
  }
  return folders;
}

/// The user's global instructions, the project's AGENTS.md files and the working folder's memory, as one block for the system prompt.
/// The project's CLAUDE.md files are left out because the "project" setting source already loads them, and so is any text that repeats
/// one already included. Only text is taken from the user's settings, so their hooks stay out of the app's agents.
/// Missing files are skipped, and the order is fixed so the prompt caches.
export function userContext(home: string | undefined, cwd: string): string | undefined {
  if (!home) return undefined;
  const folders = projectFolders(home, cwd);
  const memory = memoryFolder(home, cwd);
  const index = read(join(memory, "MEMORY.md"));
  const linked = index ? [...new Set([...index.matchAll(/\]\(([^)\s/]+\.md)\)/g)].map((match) => match[1]))] : [];
  const seen = new Set(folders.flatMap((folder) => read(join(folder, "CLAUDE.md")) ?? []));
  const entries: [string, string | undefined][] = [
    ["The user's own instructions (~/.claude/CLAUDE.md)", read(join(home, ".claude", "CLAUDE.md"))],
    ...folders.map((folder): [string, string | undefined] => [`Project instructions (${join(folder, "AGENTS.md")})`, read(join(folder, "AGENTS.md"))]),
    ["Memory index", index],
    ...linked.map((file): [string, string | undefined] => [`Memory: ${file}`, read(join(memory, file))]),
  ];
  const sections = entries.flatMap(([title, text]) => {
    if (!text || seen.has(text)) return [];
    seen.add(text);
    return [`## ${title}\n${clip(text, fileLimit)}`];
  });
  if (sections.length === 0) return undefined;
  return clip(`# The user's instructions and memory\n\n${sections.join("\n\n")}`, contextLimit);
}
