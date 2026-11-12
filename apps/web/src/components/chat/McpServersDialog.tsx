import { mcpServerLogo } from "@t3tools/client-runtime/work-log/mcp-server-logos";
import type {
  EnvironmentId,
  McpServerAction,
  McpServerSummary,
  ThreadId,
  ThreadMcpServersResult,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import { ChevronRightIcon, PlugIcon, RefreshCwIcon } from "lucide-react";
import { useState } from "react";

import { cn } from "~/lib/utils";
import { readLocalApi } from "../../localApi";
import { mcpAppEnvironment } from "../../state/mcpApps";
import { useEnvironmentQuery } from "../../state/query";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button } from "../ui/button";
import {
  Dialog,
  DialogDescription,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../ui/dialog";
import { Spinner } from "../ui/spinner";
import { toastManager } from "../ui/toast";

const STATUS: Record<McpServerSummary["status"], { label: string; dot: string }> = {
  connected: { label: "Connected", dot: "bg-success" },
  pending: { label: "Connecting", dot: "bg-amber-500 animate-pulse" },
  failed: { label: "Failed", dot: "bg-destructive" },
  "needs-auth": { label: "Needs sign-in", dot: "bg-amber-500" },
  disabled: { label: "Disabled", dot: "bg-muted-foreground/50" },
};

const DRIVER_LABEL: Record<string, string> = { claudeAgent: "Claude", codex: "Codex" };

/** Connectors from a claude.ai account are signed into there, not from the CLI. */
const CLAUDE_AI_CONNECTORS_URL = "https://claude.ai/settings/connectors";

function failureMessage(cause: Cause.Cause<unknown>): string {
  const error = Cause.squash(cause);
  return error instanceof Error && error.message ? error.message : "The MCP request failed.";
}

function openInBrowser(url: string) {
  void readLocalApi()
    ?.shell.openExternal(url)
    .catch(() => undefined);
}

function ServerLogo({ name }: { readonly name: string }) {
  const logo = mcpServerLogo(name);
  return (
    <span
      aria-hidden
      className="flex size-6 shrink-0 items-center justify-center rounded-md border border-border/70 bg-muted"
    >
      {logo ? (
        <svg viewBox="0 0 24 24" className="size-3.5 fill-current text-foreground/80">
          <path d={logo.path} />
        </svg>
      ) : (
        <PlugIcon className="size-3.5 text-muted-foreground" />
      )}
    </span>
  );
}

/**
 * `/mcp`: the thread's running agent's MCP servers, with the actions its provider allows.
 * Claude can reconnect and switch servers on and off; Codex can sign in and reload its config.
 */
export function McpServersDialog(props: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={props.open} onOpenChange={props.onOpenChange}>
      <DialogPopup className="sm:max-w-lg" data-mcp-servers-dialog="">
        {/* Mounted only while open, so the list is read (and re-read) only then. */}
        {props.open ? (
          <McpServersBody environmentId={props.environmentId} threadId={props.threadId} />
        ) : null}
      </DialogPopup>
    </Dialog>
  );
}

function McpServersBody(props: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
}) {
  const { environmentId, threadId } = props;
  const query = useEnvironmentQuery(
    mcpAppEnvironment.listServersQuery({ environmentId, input: { threadId } }),
  );
  const serverAction = useAtomCommand(mcpAppEnvironment.serverAction, { reportFailure: false });
  const [busy, setBusy] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());

  const act = async (server: string, action: McpServerAction) => {
    if (busy !== null) return;
    setBusy(`${server}:${action}`);
    const result = await serverAction({ environmentId, input: { threadId, server, action } });
    setBusy(null);
    if (result._tag === "Failure") {
      toastManager.add({ type: "error", title: failureMessage(result.cause) });
      return;
    }
    if (action === "login" && result.value.authorizationUrl) {
      openInBrowser(result.value.authorizationUrl);
      toastManager.add({
        type: "info",
        title: `Finish signing in to ${server} in your browser`,
        description: "The list updates when it connects.",
      });
    }
    query.refresh();
  };

  const toggleExpanded = (name: string) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });

  const result = query.data;
  const connected = result?.servers.filter((server) => server.status === "connected").length ?? 0;

  return (
    <>
      <DialogHeader>
        <div className="flex items-center gap-2">
          <DialogTitle className="flex-1">MCP servers</DialogTitle>
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label="Refresh MCP servers"
            disabled={query.isPending || busy !== null}
            onClick={() => query.refresh()}
          >
            {query.isPending && result !== null ? (
              <Spinner size="xs" />
            ) : (
              <RefreshCwIcon className="size-3.5" />
            )}
          </Button>
        </div>
        <DialogDescription>
          {result
            ? `${DRIVER_LABEL[result.driver] ?? result.driver} · ${connected} of ${result.servers.length} connected`
            : "The servers this thread's agent is using."}
        </DialogDescription>
      </DialogHeader>
      <DialogPanel>
        {result === null && query.error === null ? (
          <div className="flex items-center gap-2 py-6 text-sm text-muted-foreground">
            <Spinner size="xs" /> Checking servers…
          </div>
        ) : result === null ? (
          <p data-mcp-servers-error="" className="py-4 text-sm text-muted-foreground">
            {query.error}
          </p>
        ) : result.servers.length === 0 ? (
          <p className="py-4 text-sm text-muted-foreground">
            This agent has no MCP servers configured.
          </p>
        ) : (
          <ul className="-mx-2 flex flex-col">
            {result.servers.map((server) => {
              const status = STATUS[server.status];
              const isOpen = expanded.has(server.name);
              const rowBusy = busy?.startsWith(`${server.name}:`) === true;
              return (
                <li key={server.name} data-mcp-server={server.name} className="rounded-lg">
                  <div className="flex min-h-11 items-center gap-2.5 px-2 py-1.5">
                    <button
                      type="button"
                      aria-expanded={isOpen}
                      aria-label={`${isOpen ? "Hide" : "Show"} ${server.name} tools`}
                      disabled={server.tools.length === 0}
                      onClick={() => toggleExpanded(server.name)}
                      className="flex min-w-0 flex-1 cursor-pointer items-center gap-2.5 text-left disabled:cursor-default"
                    >
                      <ServerLogo name={server.name} />
                      <span className="min-w-0 flex-1">
                        <span className="flex min-w-0 items-center gap-1.5">
                          <span className="truncate text-sm font-medium">{server.name}</span>
                          {server.scope ? (
                            <span className="shrink-0 rounded bg-muted px-1 text-2xs text-muted-foreground">
                              {server.scope}
                            </span>
                          ) : null}
                        </span>
                        <span className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
                          <span
                            aria-hidden
                            className={cn("size-1.5 shrink-0 rounded-full", status.dot)}
                          />
                          <span className="shrink-0">{status.label}</span>
                          {server.tools.length > 0 ? (
                            <span className="shrink-0 tabular-nums">
                              · {server.tools.length} {server.tools.length === 1 ? "tool" : "tools"}
                            </span>
                          ) : null}
                          {server.url ? <span className="truncate">· {server.url}</span> : null}
                        </span>
                      </span>
                      {server.tools.length > 0 ? (
                        <ChevronRightIcon
                          aria-hidden
                          className={cn(
                            "size-3.5 shrink-0 text-muted-foreground transition-transform",
                            isOpen && "rotate-90",
                          )}
                        />
                      ) : null}
                    </button>
                    <ServerActions
                      server={server}
                      actions={result.actions}
                      busy={rowBusy}
                      disabled={busy !== null}
                      onAct={(action) => void act(server.name, action)}
                    />
                  </div>
                  {server.error &&
                  (server.status === "failed" || server.status === "needs-auth") ? (
                    <p className="ms-[2.625rem] -mt-1 mb-1.5 line-clamp-3 px-2 text-xs text-destructive/90">
                      {server.error}
                    </p>
                  ) : null}
                  {server.status === "needs-auth" && !result.actions.login ? (
                    <p className="ms-[2.625rem] -mt-1 mb-1.5 px-2 text-xs text-muted-foreground">
                      {server.scope === "claudeai"
                        ? "This connector signs in through your claude.ai account."
                        : "Sign in by running claude in a terminal and choosing this server in /mcp, then reconnect it here."}
                    </p>
                  ) : null}
                  {isOpen ? (
                    <ul className="ms-[2.625rem] mb-2 flex flex-col gap-0.5 px-2">
                      {server.tools.map((tool) => (
                        <li key={tool.name} className="flex min-w-0 gap-2 text-2xs">
                          <span className="shrink-0 font-mono text-foreground/80">{tool.name}</span>
                          {tool.description ? (
                            <span className="truncate text-muted-foreground">
                              {tool.description}
                            </span>
                          ) : null}
                        </li>
                      ))}
                    </ul>
                  ) : null}
                </li>
              );
            })}
          </ul>
        )}
        {result?.actions.reloadAll ? (
          <div className="flex justify-end pt-3">
            <Button
              size="sm"
              variant="outline"
              disabled={busy !== null}
              onClick={() => void act("", "reload")}
            >
              {busy === ":reload" ? <Spinner size="xs" /> : <RefreshCwIcon className="size-3.5" />}
              Reload config
            </Button>
          </div>
        ) : null}
      </DialogPanel>
    </>
  );
}

function ServerActions(props: {
  readonly server: McpServerSummary;
  readonly actions: ThreadMcpServersResult["actions"];
  readonly busy: boolean;
  readonly disabled: boolean;
  readonly onAct: (action: McpServerAction) => void;
}) {
  const { server, actions } = props;
  if (props.busy) return <Spinner size="xs" />;
  const buttons: Array<{ action: McpServerAction | "claudeai"; label: string }> = [];
  if (server.status === "needs-auth") {
    if (actions.login) buttons.push({ action: "login", label: "Sign in" });
    else if (server.scope === "claudeai")
      buttons.push({ action: "claudeai", label: "Open claude.ai" });
  }
  if (actions.reconnect && server.status !== "disabled") {
    buttons.push({ action: "reconnect", label: "Reconnect" });
  }
  if (actions.toggle) {
    buttons.push(
      server.status === "disabled"
        ? { action: "enable", label: "Enable" }
        : { action: "disable", label: "Disable" },
    );
  }
  return (
    <div className="flex shrink-0 items-center gap-1">
      {buttons.map((button) => (
        <Button
          key={button.action}
          size="xs"
          variant={button.action === "login" || button.action === "enable" ? "outline" : "ghost"}
          disabled={props.disabled}
          onClick={() =>
            button.action === "claudeai"
              ? openInBrowser(CLAUDE_AI_CONNECTORS_URL)
              : props.onAct(button.action)
          }
        >
          {button.label}
        </Button>
      ))}
    </div>
  );
}
