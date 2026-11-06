import type { DiscoveredLocalServer } from "@t3tools/contracts";

import { cn } from "~/lib/utils";
import { SERVICE_ICON_PATHS } from "./serviceIconPaths";
import { SERVICE_NAMES, detectServiceSlug } from "./serviceKind.logic";

/**
 * The servers a branch's threads started, as a row of small buttons under its
 * card: the service's logo and the port. Each opens the server.
 */
export function ServicePortsRow(props: {
  readonly servers: ReadonlyArray<DiscoveredLocalServer>;
  readonly onOpen: (server: DiscoveredLocalServer) => void;
}) {
  if (props.servers.length === 0) return null;
  return (
    <div
      data-testid="octet-service-ports"
      className="flex min-w-0 flex-wrap items-center gap-1 px-(--sidebar-row-content-inset) pb-1"
    >
      {props.servers.map((server) => {
        const slug = detectServiceSlug(server);
        const path = slug ? SERVICE_ICON_PATHS[slug] : undefined;
        const name = slug ? (SERVICE_NAMES[slug] ?? slug) : "Server";
        return (
          <button
            key={`${server.host}:${server.port}`}
            type="button"
            title={`${name} · localhost:${server.port}`}
            onClick={(event) => {
              event.stopPropagation();
              props.onOpen(server);
            }}
            className={cn(
              "inline-flex h-5 cursor-pointer items-center gap-1 rounded-md px-1.5 text-xs tabular-nums",
              "text-secondary-label transition-colors hover:bg-sidebar-row-hover hover:text-sidebar-foreground",
            )}
          >
            {path ? (
              <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden className="size-3 shrink-0">
                <path d={path} />
              </svg>
            ) : (
              <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-current opacity-60" />
            )}
            <span className="font-mono">{server.port}</span>
          </button>
        );
      })}
    </div>
  );
}
