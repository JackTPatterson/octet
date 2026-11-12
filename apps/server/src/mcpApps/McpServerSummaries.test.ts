import { describe, expect, it } from "vite-plus/test";

import { claudeMcpServerSummary } from "../orchestration-v2/Adapters/ClaudeAdapterV2.ts";
import { codexMcpServerSummary } from "../orchestration-v2/Adapters/CodexAdapterV2.ts";

describe("claudeMcpServerSummary", () => {
  it("keeps the status, scope, tools and only the origin of a remote URL", () => {
    expect(
      claudeMcpServerSummary({
        name: "linear",
        status: "needs-auth",
        error: "Sign in required",
        scope: "user",
        config: { type: "http", url: "https://mcp.linear.app/sse?token=secret" },
        tools: [{ name: "list_issues", description: "List issues" }, { name: "  " }],
      } as never),
    ).toEqual({
      name: "linear",
      status: "needs-auth",
      error: "Sign in required",
      scope: "user",
      url: "https://mcp.linear.app",
      tools: [{ name: "list_issues", description: "List issues" }],
    });
  });

  it("falls back to the source when there is no scope, and leaves a stdio server URL-less", () => {
    const summary = claudeMcpServerSummary({
      name: "rea",
      status: "connected",
      source: "plugin",
      config: { type: "stdio", command: "rea" },
    } as never);
    expect(summary).toEqual({ name: "rea", status: "connected", scope: "plugin", tools: [] });
  });
});

describe("codexMcpServerSummary", () => {
  const server = (overrides: Record<string, unknown>) =>
    ({
      name: "github",
      authStatus: "oAuth",
      resources: [],
      resourceTemplates: [],
      tools: {},
      ...overrides,
    }) as never;

  it("maps Codex's runtime status onto /mcp's", () => {
    expect(codexMcpServerSummary(server({ runtimeStatus: "authenticationRequired" })).status).toBe(
      "needs-auth",
    );
    expect(codexMcpServerSummary(server({ runtimeStatus: "notStarted" })).status).toBe("pending");
    expect(codexMcpServerSummary(server({ runtimeStatus: "cancelled" })).status).toBe("failed");
    expect(codexMcpServerSummary(server({ runtimeStatus: "disabled" })).status).toBe("disabled");
  });

  it("infers a status on builds that report none, and carries tools, errors and origins", () => {
    expect(codexMcpServerSummary(server({ authStatus: "notLoggedIn" })).status).toBe("needs-auth");
    expect(
      codexMcpServerSummary(
        server({
          runtimeStatus: "failed",
          toolsError: "connection refused",
          httpOrigin: "https://api.githubcopilot.com",
          pluginId: "github@openai",
          tools: { search: { name: "search", description: "Search code", inputSchema: {} } },
        }),
      ),
    ).toEqual({
      name: "github",
      status: "failed",
      error: "connection refused",
      scope: "plugin",
      url: "https://api.githubcopilot.com",
      tools: [{ name: "search", description: "Search code" }],
    });
  });
});
