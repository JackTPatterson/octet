import type { ToolActivityIcon } from "@t3tools/contracts";

import { MCP_SERVER_LOGOS, type McpServerLogo } from "./mcpServerLogos.data.ts";

/**
 * The MCP server a tool call goes to: Claude names tools `mcp__<server>__<tool>`, Codex
 * `<server>.<tool>` (connectors as `codex_apps.<app>.<tool>`). Built-in tools have neither.
 */
export function mcpServerOfTool(toolName: string): string | null {
  const claude = /^mcp__(.+?)__.+$/i.exec(toolName);
  if (claude) return claude[1]!;
  const dot = toolName.lastIndexOf(".");
  if (dot > 0 && !/\s/.test(toolName)) return toolName.slice(0, dot);
  return null;
}

/**
 * Words hosts put in front of a server's own name (`claude_ai_Notion`, `plugin_stripe_stripe`,
 * `codex_apps.gmail`): never the service itself.
 */
const HOST_WORDS = new Set(["claude", "ai", "plugin", "codex", "apps", "mcp", "server"]);

function serverWords(server: string): string[] {
  return server
    .toLowerCase()
    .split(/[_\-:. ]+/)
    .filter((word) => word.length > 0 && !HOST_WORDS.has(word));
}

/**
 * Services with no Simple Icons mark: their site's own favicon, loaded from that site
 * (each checked to serve `/favicon.ico`).
 */
const MCP_SERVER_SITES: ReadonlyArray<{
  readonly names: ReadonlyArray<string>;
  readonly url: string;
}> = [
  { names: ["firecrawl"], url: "https://www.firecrawl.dev/" },
  { names: ["workos"], url: "https://workos.com/" },
  { names: ["context7"], url: "https://context7.com/" },
  { names: ["mobbin"], url: "https://mobbin.com/" },
  { names: ["pencil"], url: "https://www.pencil.dev/" },
  { names: ["slack"], url: "https://slack.com/" },
  {
    names: ["microsoft", "m365", "outlook", "teams", "sharepoint", "onedrive"],
    url: "https://www.microsoft.com/",
  },
  { names: ["linkedin"], url: "https://www.linkedin.com/" },
  { names: ["apify"], url: "https://apify.com/" },
  { names: ["exa"], url: "https://exa.ai/" },
  { names: ["tavily"], url: "https://tavily.com/" },
  { names: ["browserbase"], url: "https://www.browserbase.com/" },
  { names: ["twilio"], url: "https://www.twilio.com/" },
  { names: ["salesforce"], url: "https://www.salesforce.com/" },
  { names: ["heroku"], url: "https://www.heroku.com/" },
  { names: ["canva"], url: "https://www.canva.com/" },
];

/** The logo of the service an MCP server fronts, matched by the words of its name. */
export function mcpServerLogo(server: string): McpServerLogo | null {
  for (const word of serverWords(server)) {
    const logo = MCP_SERVER_LOGOS.find(
      (entry) => entry.slug === word || entry.names.includes(word),
    );
    if (logo) return logo;
  }
  return null;
}

function luminance(hex: string): number {
  const channel = (offset: number) => {
    const value = Number.parseInt(hex.slice(offset, offset + 2), 16) / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
}

function svgDataUrl(path: string, fill: string): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="${fill}"><path d="${path}"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const cache = new Map<string, ToolActivityIcon | null>();

/**
 * The service logo for an MCP tool call, in its brand colour, as the Swift Octet drew it.
 * A brand too dark for a dark theme (GitHub, Notion) or too light for a light one (Hugging
 * Face) swaps to a neutral there, so the mark stays visible.
 */
export function mcpToolActivityIcon(toolName: string | undefined): ToolActivityIcon | undefined {
  if (!toolName) return undefined;
  const cached = cache.get(toolName);
  if (cached !== undefined) return cached ?? undefined;
  const server = mcpServerOfTool(toolName);
  const logo = server === null ? null : mcpServerLogo(server);
  const site =
    server === null || logo !== null
      ? null
      : (MCP_SERVER_SITES.find((entry) =>
          serverWords(server).some((word) => entry.names.includes(word)),
        ) ?? null);
  const icon: ToolActivityIcon | null =
    site !== null
      ? { _tag: "website", pageUrl: site.url }
      : logo === null
        ? null
        : (() => {
            const brand = `#${logo.hex}`;
            const light = luminance(logo.hex);
            return {
              _tag: "themed-logo",
              logoUrl: svgDataUrl(logo.path, light > 0.75 ? "#71717A" : brand),
              logoUrlDark: svgDataUrl(logo.path, light < 0.06 ? "#E4E4E7" : brand),
            };
          })();
  if (cache.size > 2000) cache.clear();
  cache.set(toolName, icon);
  return icon ?? undefined;
}
