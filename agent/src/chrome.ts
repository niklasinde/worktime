/// Claude in Chrome: the CLI's built-in MCP server driving the user's Chrome through the browser extension.
const chromeTool = /^mcp__claude[-_]in[-_]chrome__(.+)$/i;
/// Tools that only read what the browser shows; everything else (navigating, clicking, typing, forms, scripts, uploads) asks.
const reads = new Set(["tabs_context_mcp", "list_connected_browsers", "read_page", "get_page_text", "find"]);
const computerReads = new Set(["screenshot", "zoom"]);

export function isChromeTool(tool: string): boolean {
  return chromeTool.test(tool);
}

export function isChromeRead(tool: string, input: Record<string, unknown>): boolean {
  const name = chromeTool.exec(tool)?.[1];
  if (!name) return false;
  return reads.has(name) || (name === "computer" && typeof input.action === "string" && computerReads.has(input.action));
}

/// The host of a URL, lower-cased; a URL without a scheme counts as https. Undefined for anything that is not a web address.
export function hostOf(url: unknown): string | undefined {
  if (typeof url !== "string") return undefined;
  const text = url.trim();
  if (!text || /^(back|forward)$/i.test(text)) return undefined;
  try {
    const { protocol, hostname } = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(text) ? text : `https://${text}`);
    return /^https?:$/.test(protocol) && hostname ? hostname.toLowerCase() : undefined;
  } catch {
    return undefined;
  }
}

/// Whether `host` is one of the allowed sites: an exact host, or a subdomain of a listed `*.example.com` (which does not match example.com itself).
export function siteAllowed(host: string | undefined, allowed: readonly string[]): boolean {
  if (!host) return false;
  return allowed.some((entry) => {
    const site = entry.trim().toLowerCase();
    return site.startsWith("*.") ? host.endsWith(site.slice(1)) : site === host;
  });
}

const urlPattern = /https?:\/\/[^\s)"'>\]]+/;
const tabLine = /tab\s*id\D{0,3}(\d+)\D.*?(https?:\/\/[^\s)"'>\]]+)/i;

/// The host of each Chrome tab, from what the tools themselves report: a navigate, and the tab lists of tabs_context_mcp and
/// tabs_create_mcp. Page text from read_page, get_page_text or a script is never read, as the page writes it. A tab that
/// was clicked away from its recorded host is not noticed until the next list.
export class ChromeTabs {
  private hosts = new Map<number, string>();

  record(tool: string, input: Record<string, unknown>, result: string) {
    const name = chromeTool.exec(tool)?.[1];
    if (name === "navigate") {
      const host = hostOf(urlPattern.exec(result)?.[0] ?? input.url);
      if (typeof input.tabId === "number" && host) this.hosts.set(input.tabId, host);
    } else if (name === "tabs_context_mcp" || name === "tabs_create_mcp") {
      for (const line of result.split("\n")) {
        const [, id, url] = tabLine.exec(line) ?? [];
        const host = hostOf(url);
        if (id && host) this.hosts.set(Number(id), host);
      }
    }
  }

  /// The site a call acts on: the target of a navigate, else the recorded host of its tab.
  hostFor(tool: string, input: Record<string, unknown>): string | undefined {
    if (chromeTool.exec(tool)?.[1] === "navigate") return hostOf(input.url);
    return typeof input.tabId === "number" ? this.hosts.get(input.tabId) : undefined;
  }
}

/// The CLI flag for each session: `--no-chrome` when off, so a global "enabled by default" setting does not switch it on.
export function chromeArgs(enabled: boolean): Record<string, null> {
  return enabled ? { chrome: null } : { "no-chrome": null };
}

/// The extension's state from a Chrome tool's result: connected when it worked, its error text when the browser could not be
/// reached, and undefined for any other failure (a missing element, a denied call), which says nothing about the connection.
export function chromeResultStatus(isError: boolean, text: string): { connected: boolean; message?: string } | undefined {
  if (!isError) return { connected: true };
  return /not connected|extension|connection|no (connected )?browser/i.test(text) ? { connected: false, message: text } : undefined;
}

/// The extension's state from a session's MCP server list: undefined when the server is not listed, so nothing is known yet.
export function chromeServerStatus(servers: unknown): { connected: boolean; message?: string } | undefined {
  if (!Array.isArray(servers)) return undefined;
  const server = servers.find((s) => typeof s?.name === "string" && /^claude[-_]in[-_]chrome$/i.test(s.name));
  if (!server) return undefined;
  return server.status === "connected" ? { connected: true } : { connected: false, message: `its MCP server is ${server.status ?? "not running"}` };
}
