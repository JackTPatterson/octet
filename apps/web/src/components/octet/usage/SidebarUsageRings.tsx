import { useAtomValue } from "@effect/atom-react";
import { ProviderDriverKind } from "@t3tools/contracts";
import { collectLimitAccounts, collectLimitPools } from "@t3tools/shared/usageLimits";
import { ChartNoAxesColumnIcon, ChevronRightIcon } from "lucide-react";
import type { ReactNode } from "react";

import { cn } from "~/lib/utils";
import { environmentPresentations } from "../../../state/presentation";
import { AntigravityIcon, ClaudeAI, OpenAI, type Icon } from "../../Icons";
import { providerTextColor } from "../../chat/ProviderInstanceIcon";
import { SidebarMenuButton } from "../../ui/sidebar";
import { PreviewCard, PreviewCardPopup, PreviewCardTrigger } from "../../ui/preview-card";
import { LimitWindows } from "../../usage/UsageLimits";
import { PROVIDER_PRESENTATION } from "../../usage/usageProviders";
import { formatDuration } from "@t3tools/shared/usageLimits";
import { ringFraction, ringTone, tightestWindow, type RingTone } from "./usageRings.logic";

const ICONS: Partial<Record<string, Icon>> = {
  codex: OpenAI,
  claudeAgent: ClaudeAI,
  antigravity: AntigravityIcon,
};

const TONE_STROKE: Record<RingTone, string> = {
  normal: "stroke-current",
  warn: "stroke-amber-500",
  critical: "stroke-destructive",
};

/** A progress ring: a quiet track and an arc of what is used, starting at the top. */
function UsageRing({
  usedPercent,
  tone,
}: {
  readonly usedPercent: number;
  readonly tone: RingTone;
}) {
  const radius = 6;
  const circumference = 2 * Math.PI * radius;
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="size-3.5 shrink-0 -rotate-90">
      <circle cx="8" cy="8" r={radius} fill="none" strokeWidth="2" className="stroke-border" />
      <circle
        cx="8"
        cy="8"
        r={radius}
        fill="none"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={`${ringFraction(usedPercent) * circumference} ${circumference}`}
        className={TONE_STROKE[tone]}
      />
    </svg>
  );
}

/**
 * The sidebar's Usage button: each agent's logo, a ring and the share of its
 * tightest limit used. With no limits to show it is the plain Usage icon.
 */
export function SidebarUsageButton(props: {
  readonly onClick: () => void;
  readonly fallback?: ReactNode;
}) {
  const presentations = useAtomValue(environmentPresentations.presentationsWithProvidersAtom);
  const pools = collectLimitPools(collectLimitAccounts(presentations), Date.now());
  const rows = pools.flatMap((pool) => {
    const Logo = ICONS[pool.driver];
    const window = tightestWindow(pool);
    return Logo && window ? [{ pool, Logo, window }] : [];
  });
  const label =
    rows.length === 0
      ? "Usage"
      : `Usage: ${rows.map(({ pool, window }) => `${pool.driver === "claudeAgent" ? "Claude" : pool.driver === "codex" ? "Codex" : pool.driver} ${window.label} ${window.usedPercent}% used`).join(", ")}`;
  const now = Date.now();
  return (
    <PreviewCard>
      <PreviewCardTrigger
        delay={250}
        closeDelay={120}
        render={
          <SidebarMenuButton
            aria-label={label}
            onClick={props.onClick}
            size={rows.length === 0 ? "icon" : "default"}
            className={rows.length === 0 ? undefined : "w-auto min-w-0 gap-2 px-1.5"}
          />
        }
      >
        {rows.length === 0
          ? (props.fallback ?? <ChartNoAxesColumnIcon />)
          : rows.map(({ pool, Logo, window }) => {
              const color = providerTextColor(ProviderDriverKind.make(pool.driver));
              return (
                <span
                  key={pool.driver}
                  data-testid="usage-ring"
                  className="flex shrink-0 items-center gap-1 text-xs tabular-nums"
                >
                  <Logo
                    className={cn("size-3 shrink-0", color.className)}
                    {...(color.style ? { style: color.style } : {})}
                  />
                  <UsageRing usedPercent={window.usedPercent} tone={ringTone(window.usedPercent)} />
                  <span>{Math.round(window.usedPercent)}%</span>
                </span>
              );
            })}
      </PreviewCardTrigger>
      <PreviewCardPopup side="top" align="start" sideOffset={8} className="w-72 p-0">
        {rows.length === 0 ? (
          <p className="p-3 text-xs text-muted-foreground">No usage limits to show yet.</p>
        ) : (
          <div data-testid="usage-card" className="flex flex-col">
            <div className="flex flex-col divide-y divide-border/60">
              {rows.flatMap(({ pool, Logo }) => {
                const color = providerTextColor(ProviderDriverKind.make(pool.driver));
                const name = PROVIDER_PRESENTATION[providerKey(pool.driver)]?.label ?? pool.driver;
                return pool.accounts.map((account) => {
                  const checked = Date.parse(account.limits.checkedAt);
                  return (
                    <section key={account.key} className="flex flex-col gap-2.5 p-3">
                      <div className="flex min-w-0 items-start gap-2">
                        <Logo
                          className={cn("mt-0.5 size-3.5 shrink-0", color.className)}
                          {...(color.style ? { style: color.style } : {})}
                        />
                        <div className="flex min-w-0 flex-1 flex-col">
                          <span className="truncate text-sm font-medium leading-5">
                            {account.displayName ?? name}
                          </span>
                          {account.plan ? (
                            <span
                              className="truncate text-xs text-muted-foreground"
                              title={account.plan}
                            >
                              {account.plan}
                            </span>
                          ) : null}
                        </div>
                        {Number.isFinite(checked) ? (
                          <span className="shrink-0 text-2xs leading-5 text-muted-foreground/70 tabular-nums">
                            {now - checked < 60_000
                              ? "just now"
                              : `${formatDuration(now - checked)} ago`}
                          </span>
                        ) : null}
                      </div>
                      {account.limits.windows.length > 0 ? (
                        <LimitWindows
                          driver={account.driver}
                          accentColor={account.accentColor}
                          windows={account.limits.windows}
                          now={now}
                          stacked
                        />
                      ) : (
                        <p className="text-xs text-muted-foreground">
                          {account.limits.unavailable?.message ?? "No limits reported."}
                        </p>
                      )}
                    </section>
                  );
                });
              })}
            </div>
            <button
              type="button"
              onClick={props.onClick}
              className="flex cursor-pointer items-center justify-between border-t border-border/60 px-3 py-2 text-xs text-muted-foreground hover:bg-accent/50 hover:text-foreground"
            >
              Open usage
              <ChevronRightIcon aria-hidden className="size-3.5" />
            </button>
          </div>
        )}
      </PreviewCardPopup>
    </PreviewCard>
  );
}

/** The usage provider key (codex, claude, …) for a driver. */
function providerKey(driver: string): keyof typeof PROVIDER_PRESENTATION {
  return (
    (Object.entries(PROVIDER_PRESENTATION).find(([, entry]) => entry.driverKind === driver)?.[0] as
      | keyof typeof PROVIDER_PRESENTATION
      | undefined) ?? "codex"
  );
}
