import {
  EventId,
  MessageId,
  ProviderDriverKind,
  ThreadId,
  TurnItemId,
  type OrchestrationV2ConversationMessage,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2ProviderThread,
  type OrchestrationV2TurnItem,
  type ThreadCliMirrorInput,
  type ThreadCliMirrorResult,
} from "@t3tools/contracts";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";

import * as IdAllocator from "@t3tools/provider-core/server/IdAllocator";
import * as EventSink from "../orchestration-v2/EventSink.ts";
import * as Orchestrator from "../orchestration-v2/Orchestrator.ts";
import * as ProviderSessionRuntime from "../persistence/ProviderSessionRuntime.ts";
import { claudeProjectDirectoryName } from "../remoteControl/readRemoteControl.ts";
import * as AgentSessionScanner from "./AgentSessionScanner.ts";
import {
  mirrorMessageKey,
  planCliMirror,
  type TranscriptMessage,
} from "./cliMirror.logic.ts";
import * as ProjectService from "./ProjectService.ts";

const MIRROR_EVENT_PREFIX = "cli-mirror:v1";
const CLAUDE_SESSION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
/** How much of a log's end to read; the thread already holds what came before. */
const TAIL_BYTES = 8 * 1024 * 1024;
const MAX_TAIL_RECORDS = 4000;

const dateTime = (value: string) => DateTime.makeUnsafe(value);

function messageEvents(input: {
  readonly threadId: ThreadId;
  readonly key: string;
  readonly ordinal: number;
  readonly message: TranscriptMessage;
}): ReadonlyArray<OrchestrationV2DomainEvent> {
  const messageId = MessageId.make(`${input.threadId}:cli:${input.key}`);
  const turnItemId = TurnItemId.make(`${MIRROR_EVENT_PREFIX}:turn-item:${input.threadId}:${input.key}`);
  const at = dateTime(input.message.createdAt);
  const message: OrchestrationV2ConversationMessage = {
    createdBy: input.message.role === "user" ? "user" : "agent",
    creationSource: "server",
    id: messageId,
    threadId: input.threadId,
    runId: null,
    nodeId: null,
    role: input.message.role,
    text: input.message.text,
    attachments: [],
    streaming: false,
    createdAt: at,
    updatedAt: at,
  };
  const common = {
    id: turnItemId,
    threadId: input.threadId,
    runId: null,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: input.ordinal,
    status: "completed" as const,
    title: null,
    startedAt: at,
    completedAt: at,
    updatedAt: at,
  };
  const turnItem: OrchestrationV2TurnItem =
    input.message.role === "user"
      ? {
          ...common,
          createdBy: "user",
          creationSource: "server",
          type: "user_message",
          messageId,
          inputIntent: "turn_start",
          text: input.message.text,
          attachments: [],
        }
      : {
          ...common,
          type: "assistant_message",
          messageId,
          text: input.message.text,
          streaming: false,
        };
  return [
    {
      id: EventId.make(`${MIRROR_EVENT_PREFIX}:message:${input.threadId}:${input.key}`),
      type: "message.updated",
      threadId: input.threadId,
      occurredAt: at,
      payload: message,
    },
    {
      id: EventId.make(`${MIRROR_EVENT_PREFIX}:turn-item:${input.threadId}:${input.key}`),
      type: "turn-item.updated",
      threadId: input.threadId,
      occurredAt: at,
      payload: turnItem,
    },
  ];
}

const make = Effect.gen(function* () {
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  const eventSink = yield* EventSink.EventSinkV2;
  const projects = yield* ProjectService.ProjectService;
  const idAllocator = yield* IdAllocator.IdAllocatorV2;
  const runtimes = yield* ProviderSessionRuntime.ProviderSessionRuntimeRepository;
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const environment = yield* HostProcess.Environment;
  const home = yield* HostProcess.HomeDirectory;

  /** The folder's session log: this session's, else the newest one written since `sinceMs`. */
  const findLog = Effect.fn("AgentSessionMirror.findLog")(function* (input: {
    readonly cwd: string;
    readonly sessionId: string | null;
    readonly sinceMs: number | null;
  }) {
    const configDir = environment.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
    const directory = path.join(configDir, "projects", claudeProjectDirectoryName(input.cwd));
    if (input.sessionId !== null) {
      const file = path.join(directory, `${input.sessionId}.jsonl`);
      return (yield* fileSystem.exists(file)) ? { file, sessionId: input.sessionId } : null;
    }
    if (input.sinceMs === null) return null;
    let newest: { file: string; mtime: number; sessionId: string } | null = null;
    for (const name of yield* fileSystem.readDirectory(directory)) {
      if (!name.endsWith(".jsonl")) continue;
      const file = path.join(directory, name);
      const info = yield* fileSystem.stat(file);
      const mtime = info.mtime._tag === "Some" ? info.mtime.value.getTime() : 0;
      if (info.type !== "File" || mtime < input.sinceMs) continue;
      if (newest === null || mtime > newest.mtime) {
        newest = { file, mtime, sessionId: name.slice(0, -".jsonl".length) };
      }
    }
    return newest;
  });

  /** The last part of a log, whole lines only. */
  const readTail = Effect.fn("AgentSessionMirror.readTail")(function* (file: string) {
    return yield* Effect.gen(function* () {
      const handle = yield* fileSystem.open(file, { flag: "r" });
      const size = Number((yield* handle.stat).size);
      const start = Math.max(0, size - TAIL_BYTES);
      yield* handle.seek(BigInt(start), "start");
      const bytes = yield* handle.readAlloc(size - start);
      let text = new TextDecoder().decode(Option.getOrElse(bytes, () => new Uint8Array()));
      if (start > 0) text = text.slice(text.indexOf("\n") + 1);
      const lines = text.split("\n").filter((line) => line.trim() !== "");
      return lines.slice(-MAX_TAIL_RECORDS).join("\n");
    }).pipe(Effect.scoped);
  });

  const mirror = Effect.fn("AgentSessionMirror.mirror")(function* (input: ThreadCliMirrorInput) {
    const result = (
      status: ThreadCliMirrorResult["status"],
      added = 0,
      sessionId: string | null = null,
    ): ThreadCliMirrorResult => ({ added, sessionId, status });
    const records = yield* orchestrator.getThreadRecords(input.threadId, [
      "messages",
      "providerThreads",
      "turnItems",
    ]);
    const thread = records.thread;
    const activeProvider = records.providerThreads.find(
      (candidate) => candidate.id === thread.activeProviderThreadId,
    );
    // Only Claude Code's log is read so far; other agents' threads stay as they are.
    const driver = activeProvider?.driver ?? input.driver ?? null;
    if (driver !== "claudeAgent") return result("unsupported");

    const project = yield* projects.getById(thread.projectId).pipe(Effect.map(Option.getOrNull));
    const cwd = thread.worktreePath ?? project?.workspaceRoot ?? null;
    if (cwd === null) return result("no_session");

    const knownSessionId = activeProvider?.nativeThreadRef?.nativeId ?? null;
    const found = yield* findLog({
      cwd,
      sessionId: knownSessionId,
      sinceMs: input.sinceMs ?? null,
    }).pipe(Effect.orElseSucceed(() => null));
    if (!found) return result(knownSessionId ? "no_log" : "no_session", 0, knownSessionId);

    const contents = yield* readTail(found.file).pipe(Effect.orElseSucceed(() => ""));
    const now = yield* Clock.currentTimeMillis;
    const parsed = AgentSessionScanner.parseAgentSessionTranscript({
      source: "claudeAgent",
      providerInstanceId: activeProvider?.providerInstanceId ?? thread.providerInstanceId,
      fallbackSessionId: found.sessionId,
      lastActiveAtMs: now,
      contents,
    });

    const missing = parsed
      ? planCliMirror(
          records.messages.flatMap((message) =>
            message.role === "system" ? [] : [{ role: message.role, text: message.text }],
          ),
          parsed.messages,
        )
      : [];

    const seen = new Map<string, number>();
    let ordinal = records.turnItems.reduce((max, item) => Math.max(max, item.ordinal), 0);
    const messageDomainEvents = missing.flatMap((message) => {
      const base = mirrorMessageKey({ sessionId: found.sessionId, message, occurrence: 0 });
      const occurrence = seen.get(base) ?? 0;
      seen.set(base, occurrence + 1);
      ordinal += 1;
      return messageEvents({
        threadId: thread.id,
        key: mirrorMessageKey({ sessionId: found.sessionId, message, occurrence }),
        ordinal,
        message,
      });
    });

    // A thread with no session of its own takes the CLI's, so the chat carries on from it
    // (and the terminal resumes it) instead of starting a second, unrelated conversation.
    const adopt = !activeProvider && CLAUDE_SESSION_ID_PATTERN.test(found.sessionId);
    const at = DateTime.makeUnsafe(now);
    const adoptionEvents: ReadonlyArray<OrchestrationV2DomainEvent> = adopt
      ? (() => {
          const claude = ProviderDriverKind.make("claudeAgent");
          const providerThreadId = idAllocator.derive.providerThread({
            driver: claude,
            providerInstanceId: thread.providerInstanceId,
            nativeThreadId: found.sessionId,
          });
          const providerThread: OrchestrationV2ProviderThread = {
            id: providerThreadId,
            driver: claude,
            providerInstanceId: thread.providerInstanceId,
            providerSessionId: null,
            appThreadId: thread.id,
            ownerNodeId: null,
            nativeThreadRef: { driver: claude, nativeId: found.sessionId, strength: "strong" },
            nativeConversationHeadRef: null,
            status: "idle",
            firstRunOrdinal: null,
            lastRunOrdinal: null,
            handoffIds: [],
            forkedFrom: null,
            pendingBackgroundTasks: [],
            createdAt: at,
            updatedAt: at,
          };
          return [
            {
              id: EventId.make(`${MIRROR_EVENT_PREFIX}:provider-thread:${providerThreadId}`),
              type: "provider-thread.updated",
              threadId: thread.id,
              driver: claude,
              providerInstanceId: thread.providerInstanceId,
              occurredAt: at,
              payload: providerThread,
            },
            {
              id: EventId.make(`${MIRROR_EVENT_PREFIX}:adopt:${thread.id}:${found.sessionId}`),
              type: "thread.metadata-updated",
              threadId: thread.id,
              occurredAt: at,
              payload: { ...thread, activeProviderThreadId: providerThreadId },
            },
          ];
        })()
      : [];

    const events = [...adoptionEvents, ...messageDomainEvents];
    if (events.length === 0) return result("mirrored", 0, found.sessionId);
    const committed = yield* eventSink.write({ events });
    if (adopt && committed.length > 0) {
      yield* runtimes
        .upsert(
          {
            threadId: thread.id,
            providerName: ProviderDriverKind.make("claudeAgent"),
            providerInstanceId: thread.providerInstanceId,
            adapterKey: ProviderDriverKind.make("claudeAgent"),
            runtimeMode: thread.runtimeMode,
            status: "stopped",
            lastSeenAt: DateTime.formatIso(at),
            resumeCursor: { threadId: thread.id, resume: found.sessionId },
            runtimePayload: { cwd },
          },
          { onConflict: "ignore" },
        )
        .pipe(Effect.ignore);
    }
    return result("mirrored", committed.length > 0 ? missing.length : 0, found.sessionId);
  });

  return { mirror };
});

export class AgentSessionMirror extends Context.Service<
  AgentSessionMirror,
  Effect.Success<typeof make>
>()("t3/project/AgentSessionMirror") {}

export const layer = Layer.effect(AgentSessionMirror, make);
