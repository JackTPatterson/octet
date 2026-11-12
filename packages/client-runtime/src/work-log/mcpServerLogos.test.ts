import { describe, expect, it } from "vite-plus/test";

import { extractToolActivityPresentation } from "./toolPresentation.ts";
import { mcpServerLogo, mcpServerOfTool, mcpToolActivityIcon } from "./mcpServerLogos.ts";

describe("mcpServerOfTool", () => {
  it("reads Claude's and Codex's MCP tool names, and leaves built-in tools alone", () => {
    expect(mcpServerOfTool("mcp__claude_ai_Linear__list_issues")).toBe("claude_ai_Linear");
    expect(mcpServerOfTool("github.create_issue")).toBe("github");
    expect(mcpServerOfTool("codex_apps.gmail.search_emails")).toBe("codex_apps.gmail");
    expect(mcpServerOfTool("Read")).toBeNull();
  });
});

describe("mcpServerLogo", () => {
  it("matches a service by any word of the server's name", () => {
    expect(mcpServerLogo("claude_ai_Linear")?.slug).toBe("linear");
    expect(mcpServerLogo("plugin_stripe_stripe")?.slug).toBe("stripe");
    expect(mcpServerLogo("codex_apps.gmail")?.slug).toBe("gmail");
    expect(mcpServerLogo("chrome-devtools")?.slug).toBe("googlechrome");
    expect(mcpServerLogo("t3-code")).toBeNull();
  });
});

describe("mcpToolActivityIcon", () => {
  it("draws the brand colour, swapping a near-black brand to a light neutral in dark mode", () => {
    const github = mcpToolActivityIcon("mcp__github__create_issue");
    expect(github?._tag).toBe("themed-logo");
    if (github?._tag !== "themed-logo") return;
    expect(decodeURIComponent(github.logoUrl)).toContain('fill="#181717"');
    expect(decodeURIComponent(github.logoUrlDark ?? "")).toContain('fill="#E4E4E7"');
    expect(mcpToolActivityIcon("Read")).toBeUndefined();
  });

  it("gives an MCP call without its own icon the service logo", () => {
    const presentation = extractToolActivityPresentation({
      type: "dynamic_tool",
      toolName: "mcp__claude_ai_Notion__notion-search",
      input: {},
    });
    expect(presentation.toolIcon?._tag).toBe("themed-logo");
    const own = extractToolActivityPresentation({
      type: "dynamic_tool",
      toolName: "mcp__github__create_issue",
      input: {},
      toolIcon: { _tag: "website", pageUrl: "https://example.com/" },
    });
    expect(own.toolIcon?._tag).toBe("website");
  });
});

describe("the extended list", () => {
  it("covers services past the Swift Octet's table, skipping host prefixes", () => {
    expect(mcpServerLogo("claude_ai_Supabase")?.slug).toBe("supabase");
    expect(mcpServerLogo("railway")?.slug).toBe("railway");
    expect(mcpServerLogo("postiz")?.slug).toBe("postiz");
    expect(mcpServerLogo("claude_ai_Expo")?.slug).toBe("expo");
    // "claude" and "ai" are the host's words, not the service's.
    expect(mcpServerLogo("claude_ai")).toBeNull();
  });

  it("falls back to the site's favicon for a service with no Simple Icons mark", () => {
    expect(mcpToolActivityIcon("firecrawl.firecrawl_scrape")).toEqual({
      _tag: "website",
      pageUrl: "https://www.firecrawl.dev/",
    });
    expect(mcpToolActivityIcon("mcp__claude_ai_Microsoft_365__search")).toEqual({
      _tag: "website",
      pageUrl: "https://www.microsoft.com/",
    });
  });
});
