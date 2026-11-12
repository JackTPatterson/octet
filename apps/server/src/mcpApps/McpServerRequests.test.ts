import {
  ProviderSessionId,
  ProviderThreadId,
  ThreadId,
  type McpServersRequestError,
  type OrchestrationV2ProviderThread,
} from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import * as ProviderAdapter from "@t3tools/provider-core/server/ProviderAdapter";
import * as ProviderSessionManager from "../orchestration-v2/ProviderSessionManager.ts";
import * as ThreadManagementService from "../orchestration-v2/ThreadManagementService.ts";
import * as McpServerRequests from "./McpServerRequests.ts";

const threadId = ThreadId.make("thread-mcp");
const providerThreadId = ProviderThreadId.make("provider-thread-mcp");
const providerSessionId = ProviderSessionId.make("provider-session-mcp");

function makeLayer(input: {
  readonly mcpServers?: ProviderAdapter.ProviderAdapterV2McpServers;
  readonly live?: boolean;
  readonly sessionId?: ProviderSessionId | null;
}) {
  return McpServerRequests.layer.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.mock(ThreadManagementService.ThreadManagementService)({
          getThreadRecords: () =>
            Effect.succeed({
              thread: { activeProviderThreadId: providerThreadId, deletedAt: null },
              providerThreads: [
                {
                  id: providerThreadId,
                  appThreadId: threadId,
                  providerSessionId:
                    input.sessionId === undefined ? providerSessionId : input.sessionId,
                } as OrchestrationV2ProviderThread,
              ],
            } as never),
        }),
        Layer.mock(ProviderSessionManager.ProviderSessionManagerV2)({
          get: () =>
            Effect.succeed(
              input.live === false
                ? Option.none()
                : Option.some({
                    driver: "claudeAgent",
                    ...(input.mcpServers === undefined ? {} : { mcpServers: input.mcpServers }),
                  } as unknown as ProviderAdapter.ProviderAdapterV2SessionRuntime),
            ),
        }),
      ),
    ),
  );
}

const reason = <A, R>(effect: Effect.Effect<A, McpServersRequestError, R>) =>
  effect.pipe(
    Effect.flip,
    Effect.map((error) => error.reason),
  );

describe("McpServerRequests", () => {
  const calls: Array<string> = [];
  const claudeLike: ProviderAdapter.ProviderAdapterV2McpServers = {
    list: () =>
      Effect.succeed([
        { name: "zeta", status: "connected", tools: [] },
        { name: "alpha", status: "needs-auth", tools: [] },
      ]),
    reconnect: ({ server }) => Effect.sync(() => void calls.push(`reconnect ${server}`)),
    setEnabled: ({ server, enabled }) =>
      Effect.sync(() => void calls.push(`${enabled ? "enable" : "disable"} ${server}`)),
  };

  it.effect("lists the servers sorted by name, with the actions the provider has", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      const result = yield* requests.list({ threadId });
      assert.deepStrictEqual(
        result.servers.map((server) => server.name),
        ["alpha", "zeta"],
      );
      assert.deepStrictEqual(result.actions, {
        reconnect: true,
        toggle: true,
        login: false,
        reloadAll: false,
      });
      assert.strictEqual(result.driver, "claudeAgent");
    }).pipe(Effect.provide(makeLayer({ mcpServers: claudeLike }))),
  );

  it.effect("runs the provider's actions and refuses ones it lacks", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      calls.length = 0;
      yield* requests.act({ threadId, server: "linear", action: "reconnect" });
      yield* requests.act({ threadId, server: "linear", action: "disable" });
      assert.deepStrictEqual(calls, ["reconnect linear", "disable linear"]);
      assert.strictEqual(
        yield* reason(requests.act({ threadId, server: "linear", action: "login" })),
        "action-unsupported",
      );
      assert.strictEqual(
        yield* reason(requests.act({ threadId, server: " ", action: "reconnect" })),
        "action-unsupported",
      );
    }).pipe(Effect.provide(makeLayer({ mcpServers: claudeLike }))),
  );

  it.effect("hands back only a web page to sign in on", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      const ok = yield* requests.act({ threadId, server: "github", action: "login" });
      assert.strictEqual(ok.authorizationUrl, "https://github.com/login/oauth?state=1");
    }).pipe(
      Effect.provide(
        makeLayer({
          mcpServers: {
            list: () => Effect.succeed([]),
            login: () =>
              Effect.succeed({ authorizationUrl: "https://github.com/login/oauth?state=1" }),
          },
        }),
      ),
    ),
  );

  it.effect("refuses a sign-in link that isn't a web page", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      assert.strictEqual(
        yield* reason(requests.act({ threadId, server: "evil", action: "login" })),
        "request-failed",
      );
    }).pipe(
      Effect.provide(
        makeLayer({
          mcpServers: {
            list: () => Effect.succeed([]),
            login: () => Effect.succeed({ authorizationUrl: "file:///etc/passwd" }),
          },
        }),
      ),
    ),
  );

  it.effect("reports a stopped session and a provider without /mcp support", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      assert.strictEqual(yield* reason(requests.list({ threadId })), "provider-unsupported");
    }).pipe(Effect.provide(makeLayer({}))),
  );

  it.effect("reports a thread whose agent isn't running", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      assert.strictEqual(yield* reason(requests.list({ threadId })), "session-stopped");
    }).pipe(Effect.provide(makeLayer({ mcpServers: claudeLike, sessionId: null }))),
  );

  it.effect("passes a provider's stopped session through as session-stopped", () =>
    Effect.gen(function* () {
      const requests = yield* McpServerRequests.McpServerRequests;
      assert.strictEqual(yield* reason(requests.list({ threadId })), "session-stopped");
    }).pipe(
      Effect.provide(
        makeLayer({
          mcpServers: {
            list: () =>
              Effect.fail(
                new ProviderAdapter.ProviderAdapterSessionStoppedError({
                  driver: "claudeAgent" as never,
                }),
              ),
          },
        }),
      ),
    ),
  );
});
