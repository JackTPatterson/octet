import * as Schema from "effect/Schema";

import { ThreadId, TrimmedNonEmptyString } from "./baseSchemas.ts";

/** A server's connection, in the words both Claude and Codex map onto. */
export const McpServerConnectionStatus = Schema.Literals([
  "connected",
  "pending",
  "failed",
  "needs-auth",
  "disabled",
]);
export type McpServerConnectionStatus = typeof McpServerConnectionStatus.Type;

export const McpServerTool = Schema.Struct({
  name: TrimmedNonEmptyString,
  description: Schema.optional(Schema.String),
});
export type McpServerTool = typeof McpServerTool.Type;

/** One MCP server of a thread's running agent, as `/mcp` lists it. */
export const McpServerSummary = Schema.Struct({
  name: TrimmedNonEmptyString,
  status: McpServerConnectionStatus,
  /** Why it failed or needs sign-in, when the provider says. */
  error: Schema.optional(Schema.String),
  /** Where it is configured: user, project, local, plugin, claudeai, … */
  scope: Schema.optional(Schema.String),
  /** The HTTP origin of a remote server. */
  url: Schema.optional(Schema.String),
  tools: Schema.Array(McpServerTool),
});
export type McpServerSummary = typeof McpServerSummary.Type;

/** What the provider can do to a server from here. */
export const McpServerActionSupport = Schema.Struct({
  reconnect: Schema.Boolean,
  toggle: Schema.Boolean,
  login: Schema.Boolean,
  /** Reload every server from the provider's config (Codex), in place of a per-server reconnect. */
  reloadAll: Schema.Boolean,
});
export type McpServerActionSupport = typeof McpServerActionSupport.Type;

export const ThreadMcpServersInput = Schema.Struct({ threadId: ThreadId });
export type ThreadMcpServersInput = typeof ThreadMcpServersInput.Type;

export const ThreadMcpServersResult = Schema.Struct({
  driver: TrimmedNonEmptyString,
  servers: Schema.Array(McpServerSummary),
  actions: McpServerActionSupport,
});
export type ThreadMcpServersResult = typeof ThreadMcpServersResult.Type;

export const McpServerAction = Schema.Literals([
  "reconnect",
  "enable",
  "disable",
  "login",
  "reload",
]);
export type McpServerAction = typeof McpServerAction.Type;

export const ThreadMcpServerActionInput = Schema.Struct({
  threadId: ThreadId,
  /** Empty for `reload`, which acts on every server. */
  server: Schema.String,
  action: McpServerAction,
});
export type ThreadMcpServerActionInput = typeof ThreadMcpServerActionInput.Type;

export const ThreadMcpServerActionResult = Schema.Struct({
  /** For `login`: the page to finish signing in on. */
  authorizationUrl: Schema.optional(Schema.String),
});
export type ThreadMcpServerActionResult = typeof ThreadMcpServerActionResult.Type;

export const McpServersRequestErrorReason = Schema.Literals([
  "session-stopped",
  "provider-unsupported",
  "action-unsupported",
  "request-failed",
]);
export type McpServersRequestErrorReason = typeof McpServersRequestErrorReason.Type;

export class McpServersRequestError extends Schema.TaggedError<McpServersRequestError>()(
  "McpServersRequestError",
  {
    threadId: ThreadId,
    reason: McpServersRequestErrorReason,
    /** The provider's own words, for `request-failed`. */
    detail: Schema.optional(Schema.String),
    cause: Schema.optional(Schema.Defect()),
  },
) {
  override get message(): string {
    switch (this.reason) {
      case "session-stopped":
        return "This thread's agent isn't running. Send a message to start it, then run /mcp again.";
      case "provider-unsupported":
        return "This thread's provider doesn't report its MCP servers.";
      case "action-unsupported":
        return "This thread's provider can't do that to an MCP server.";
      case "request-failed":
        return this.detail ?? "The MCP request failed.";
    }
  }
}
