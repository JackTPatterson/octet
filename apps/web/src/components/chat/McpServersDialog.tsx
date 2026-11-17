import { mcpServerLogo } from "@t3tools/client-runtime/work-log/mcp-server-logos";
import type {
  EnvironmentId,
  McpServerAction,
  McpServerSummary,
  ThreadId,
  ThreadMcpServersResult,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import { EllipsisIcon, PlugIcon, RefreshCwIcon } from "lucide-react";
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
import { Menu, MenuItem, MenuPopup, MenuTrigger } from "../ui/menu";
import { Spinner } from "../ui/spinner";
import { toastManager } from "../ui/toast";

const DRIVER_LABEL: Record<string, string> = { claudeAgent: "Claude", codex: "Codex" };

/** Connectors from a claude.ai account are signed into there, not from the CLI. */
const CLAUDE_AI_CONNECTORS_URL = "https://claude.ai/settings/connectors";

const SECTIONS: ReadonlyArray<{
  readonly key: string;
  readonly label: string;
  readonly statuses: ReadonlyArray<McpServerSummary["status"]>;
}> = [
  { key: "attention", label: "Needs attention", statuses: ["failed", "needs-auth"] },
  { key: "connected", label: "Connected", statuses: ["connected", "pending"] },
  { key: "disabled", label: "Disabled", statuses: ["disabled"] },
];

/** claude.ai connectors arrive as "claude.ai Gmail"; the section and logo already say where from. */
function displayName(server: McpServerSummary): string {
  return server.name.replace(/^claude\.ai\s+/i, "");
}

function sourceLabel(scope: string | undefined): string | null {
  if (!scope) return null;
  if (scope === "claudeai") return "claude.ai connector";
  return `${scope} config`;
}

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
    <span aria-hidden className="flex size-5 shrink-0 items-center justify-center">
      {logo ? (
        <svg viewBox="0 0 24 24" className="size-4 fill-current text-foreground/75">
          <path d={logo.path} />
        </svg>
      ) : (
        <PlugIcon className="size-3.5 text-muted-foreground/70" />
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
        <DialogTitle>MCP servers</DialogTitle>
        <div className="flex items-center gap-1.5">
          <DialogDescription>
            {result
              ? `${DRIVER_LABEL[result.driver] ?? result.driver} · ${connected} of ${result.servers.length} connected`
              : "The servers this thread's agent is using."}
          </DialogDescription>
          <Button
            size="icon-xs"
            variant="ghost-muted"
            aria-label="Refresh MCP servers"
            disabled={query.isPending || busy !== null}
            onClick={() => query.refresh()}
          >
            {query.isPending && result !== null ? (
              <Spinner size="xs" />
            ) : (
              <RefreshCwIcon className="size-3" />
            )}
          </Button>
        </div>
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
          <div className="-mx-2 flex flex-col gap-3">
            {SECTIONS.map((section) => {
              const servers = result.servers.filter((server) =>
                section.statuses.includes(server.status),
              );
              if (servers.length === 0) return null;
              return (
                <section key={section.key} data-mcp-section={section.key}>
                  <h3 className="flex items-center gap-1.5 px-2 pb-1 text-2xs font-medium text-muted-foreground uppercase tracking-wide">
                    {section.label}
                    <span className="tabular-nums text-muted-foreground/60">{servers.length}</span>
                  </h3>
                  <ul className="flex flex-col">
                    {servers.map((server) => (
                      <ServerRow
                        key={server.name}
                        server={server}
                        actions={result.actions}
                        open={expanded.has(server.name)}
                        onToggle={() => toggleExpanded(server.name)}
                        busy={busy?.startsWith(`${server.name}:`) === true}
                        disabled={busy !== null}
                        onAct={(action) => void act(server.name, action)}
                      />
                    ))}
                  </ul>
                </section>
              );
            })}
          </div>
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

/** One line per server; the source, address, error and tools open below it on click. */
function ServerRow(props: {
  readonly server: McpServerSummary;
  readonly actions: ThreadMcpServersResult["actions"];
  readonly open: boolean;
  readonly onToggle: () => void;
  readonly busy: boolean;
  readonly disabled: boolean;
  readonly onAct: (action: McpServerAction) => void;
}) {
  const { server, actions, open } = props;
  const name = displayName(server);
  const source = sourceLabel(server.scope);
  const isClaudeAi = server.scope === "claudeai";
  const attention = server.status === "failed" || server.status === "needs-auth";
  const hint =
    server.status === "needs-auth" && !actions.login
      ? isClaudeAi
        ? "Signs in through your claude.ai account."
        : "Sign in by running claude in a terminal and choosing this server in /mcp, then reconnect it here."
      : null;

  return (
    <li data-mcp-server={server.name} className="group/row rounded-md">
      <div
        className={cn(
          "flex h-8 items-center gap-2 rounded-md px-2 hover:bg-accent/50",
          open && "bg-accent/40",
        )}
      >
        <button
          type="button"
          aria-expanded={open}
          aria-label={`${open ? "Hide" : "Show"} ${name} details`}
          onClick={props.onToggle}
          className="flex h-full min-w-0 flex-1 cursor-pointer items-center gap-2 text-left"
        >
          <ServerLogo name={server.name} />
          <span
            className={cn(
              "truncate text-sm",
              server.status === "disabled" && "text-muted-foreground",
            )}
          >
            {name}
          </span>
          {server.status === "pending" ? <Spinner size="xs" /> : null}
          {attention ? (
            <span
              className={cn(
                "shrink-0 text-xs",
                server.status === "failed" ? "text-destructive" : "text-warning-foreground",
              )}
            >
              {server.status === "failed" ? "Failed" : "Sign-in needed"}
            </span>
          ) : null}
          <span className="flex-1" />
          {server.status === "connected" && server.tools.length > 0 ? (
            <span className="shrink-0 text-xs tabular-nums text-muted-foreground/70">
              {server.tools.length}
            </span>
          ) : null}
        </button>
        <ServerActions
          server={server}
          actions={actions}
          busy={props.busy}
          disabled={props.disabled}
          onAct={props.onAct}
        />
      </div>
      {open ? (
        <div className="mb-1 ms-9 me-2 flex flex-col gap-1.5 pt-1 pb-2 text-xs">
          {source || server.url ? (
            <p className="truncate text-muted-foreground">
              {[source, server.url].filter(Boolean).join(" · ")}
            </p>
          ) : null}
          {server.error && attention ? (
            <p className="line-clamp-3 text-destructive/90">{server.error}</p>
          ) : null}
          {hint ? <p className="text-muted-foreground">{hint}</p> : null}
          {server.tools.length > 0 ? (
            <ul className="flex flex-col gap-0.5">
              {server.tools.map((tool) => (
                <li key={tool.name} className="flex min-w-0 gap-2 text-2xs">
                  <span className="shrink-0 font-mono text-foreground/80">{tool.name}</span>
                  {tool.description ? (
                    <span className="truncate text-muted-foreground">{tool.description}</span>
                  ) : null}
                </li>
              ))}
            </ul>
          ) : server.status === "connected" ? (
            <p className="text-muted-foreground">No tools.</p>
          ) : null}
        </div>
      ) : null}
    </li>
  );
}

/**
 * Only the action a row needs is shown (sign in, retry, enable); reconnect and disable sit in
 * a menu that appears on hover.
 */
function ServerActions(props: {
  readonly server: McpServerSummary;
  readonly actions: ThreadMcpServersResult["actions"];
  readonly busy: boolean;
  readonly disabled: boolean;
  readonly onAct: (action: McpServerAction) => void;
}) {
  const { server, actions } = props;
  if (props.busy) {
    return (
      <span className="flex size-6 items-center justify-center">
        <Spinner size="xs" />
      </span>
    );
  }

  let primary: { label: string; run: () => void } | null = null;
  if (server.status === "needs-auth" && actions.login) {
    primary = { label: "Sign in", run: () => props.onAct("login") };
  } else if (server.status === "needs-auth" && server.scope === "claudeai") {
    primary = { label: "Open claude.ai", run: () => openInBrowser(CLAUDE_AI_CONNECTORS_URL) };
  } else if (server.status === "failed" && actions.reconnect) {
    primary = { label: "Retry", run: () => props.onAct("reconnect") };
  } else if (server.status === "disabled" && actions.toggle) {
    primary = { label: "Enable", run: () => props.onAct("enable") };
  }

  const menu: Array<{ action: McpServerAction; label: string }> = [];
  if (actions.reconnect && server.status !== "disabled" && server.status !== "failed") {
    menu.push({ action: "reconnect", label: "Reconnect" });
  }
  if (actions.toggle && server.status !== "disabled") {
    menu.push({ action: "disable", label: "Disable" });
  }

  return (
    <div className="flex shrink-0 items-center gap-0.5">
      {primary ? (
        <Button size="xs" variant="outline" disabled={props.disabled} onClick={primary.run}>
          {primary.label}
        </Button>
      ) : null}
      {menu.length > 0 ? (
        <span className="flex opacity-0 transition-opacity group-hover/row:opacity-100 focus-within:opacity-100 has-data-popup-open:opacity-100">
          <Menu>
            <MenuTrigger
              render={
                <Button
                  size="icon-xs"
                  variant="ghost-muted"
                  aria-label={`More actions for ${displayName(server)}`}
                  disabled={props.disabled}
                />
              }
            >
              <EllipsisIcon className="size-3.5" />
            </MenuTrigger>
            <MenuPopup align="end" side="bottom" sideOffset={4} className="min-w-32">
              {menu.map((item) => (
                <MenuItem key={item.action} onClick={() => props.onAct(item.action)}>
                  {item.label}
                </MenuItem>
              ))}
            </MenuPopup>
          </Menu>
        </span>
      ) : (
        <span aria-hidden className="size-6" />
      )}
    </div>
  );
}
