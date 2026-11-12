import {
  McpServersRequestError,
  type McpServerActionSupport,
  type ThreadId,
  type ThreadMcpServerActionInput,
  type ThreadMcpServerActionResult,
  type ThreadMcpServersInput,
  type ThreadMcpServersResult,
} from "@t3tools/contracts";
import type * as ProviderAdapter from "@t3tools/provider-core/server/ProviderAdapter";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import * as ProviderSessionManager from "../orchestration-v2/ProviderSessionManager.ts";
import * as ThreadManagementService from "../orchestration-v2/ThreadManagementService.ts";

/**
 * `/mcp`: a thread's running agent's MCP servers, and what can be done to them. Like MCP
 * app requests, this reports a stopped session rather than starting one.
 */
export class McpServerRequests extends Context.Service<
  McpServerRequests,
  {
    readonly list: (
      input: ThreadMcpServersInput,
    ) => Effect.Effect<ThreadMcpServersResult, McpServersRequestError>;
    readonly act: (
      input: ThreadMcpServerActionInput,
    ) => Effect.Effect<ThreadMcpServerActionResult, McpServersRequestError>;
  }
>()("t3/mcpApps/McpServerRequests") {}

function mcpServerActionSupport(
  servers: ProviderAdapter.ProviderAdapterV2McpServers,
): McpServerActionSupport {
  return {
    reconnect: servers.reconnect !== undefined,
    toggle: servers.setEnabled !== undefined,
    login: servers.login !== undefined,
    reloadAll: servers.reloadAll !== undefined,
  };
}

const make = Effect.gen(function* () {
  const threadManagement = yield* ThreadManagementService.ThreadManagementService;
  const providerSessions = yield* ProviderSessionManager.ProviderSessionManagerV2;

  const fail = (
    threadId: ThreadId,
    reason: McpServersRequestError["reason"],
    cause?: unknown,
    detail?: string,
  ) =>
    new McpServersRequestError({
      threadId,
      reason,
      ...(detail === undefined ? {} : { detail }),
      ...(cause === undefined ? {} : { cause }),
    });
  const adapterFailure = (threadId: ThreadId) => (cause: ProviderAdapter.ProviderAdapterV2Error) =>
    cause._tag === "ProviderAdapterSessionStoppedError"
      ? fail(threadId, "session-stopped", cause)
      : fail(
          threadId,
          "request-failed",
          cause,
          "detail" in cause && typeof cause.detail === "string" ? cause.detail : undefined,
        );

  /** The thread's active provider thread and the live session running it. */
  const resolve = Effect.fn("McpServerRequests.resolve")(function* (threadId: ThreadId) {
    const records = yield* threadManagement
      .getThreadRecords(threadId, ["providerThreads"])
      .pipe(Effect.mapError((cause) => fail(threadId, "request-failed", cause)));
    const providerThread = records.providerThreads.find(
      (candidate) =>
        candidate.id === records.thread.activeProviderThreadId &&
        candidate.appThreadId === threadId,
    );
    if (records.thread.deletedAt !== null || providerThread?.providerSessionId == null) {
      return yield* fail(threadId, "session-stopped");
    }
    const runtime = Option.getOrUndefined(
      yield* providerSessions
        .get(providerThread.providerSessionId)
        .pipe(Effect.mapError((cause) => fail(threadId, "request-failed", cause))),
    );
    if (runtime === undefined) return yield* fail(threadId, "session-stopped");
    if (runtime.mcpServers === undefined) return yield* fail(threadId, "provider-unsupported");
    return { providerThread, runtime, mcpServers: runtime.mcpServers };
  });

  const list = Effect.fn("McpServerRequests.list")(function* (input: ThreadMcpServersInput) {
    const { providerThread, runtime, mcpServers } = yield* resolve(input.threadId);
    const servers = yield* mcpServers
      .list({ providerThread })
      .pipe(Effect.mapError(adapterFailure(input.threadId)));
    return {
      driver: runtime.driver,
      servers: servers.toSorted((left, right) => left.name.localeCompare(right.name)),
      actions: mcpServerActionSupport(mcpServers),
    } satisfies ThreadMcpServersResult;
  });

  const act = Effect.fn("McpServerRequests.act")(function* (input: ThreadMcpServerActionInput) {
    const { providerThread, mcpServers } = yield* resolve(input.threadId);
    const unsupported = fail(input.threadId, "action-unsupported");
    const server = input.server.trim();
    if (input.action !== "reload" && server === "") return yield* unsupported;
    const failed = adapterFailure(input.threadId);
    switch (input.action) {
      case "reconnect":
        if (mcpServers.reconnect === undefined) return yield* unsupported;
        yield* mcpServers.reconnect({ providerThread, server }).pipe(Effect.mapError(failed));
        return {};
      case "enable":
      case "disable":
        if (mcpServers.setEnabled === undefined) return yield* unsupported;
        yield* mcpServers
          .setEnabled({ providerThread, server, enabled: input.action === "enable" })
          .pipe(Effect.mapError(failed));
        return {};
      case "login": {
        if (mcpServers.login === undefined) return yield* unsupported;
        const { authorizationUrl } = yield* mcpServers
          .login({ providerThread, server })
          .pipe(Effect.mapError(failed));
        // Only a web page may be handed to the browser.
        const url = URL.canParse(authorizationUrl) ? new URL(authorizationUrl) : null;
        if (url === null || (url.protocol !== "https:" && url.protocol !== "http:")) {
          return yield* fail(
            input.threadId,
            "request-failed",
            undefined,
            "The sign-in link isn't a web page.",
          );
        }
        return { authorizationUrl: url.href };
      }
      case "reload":
        if (mcpServers.reloadAll === undefined) return yield* unsupported;
        yield* mcpServers.reloadAll({ providerThread }).pipe(Effect.mapError(failed));
        return {};
    }
  });

  return McpServerRequests.of({ list, act });
});

export const layer = Layer.effect(McpServerRequests, make);
