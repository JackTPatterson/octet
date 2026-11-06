import { DEFAULT_SERVER_SETTINGS, ThreadView } from "@t3tools/contracts";

import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../ui/select";
import { SettingsRow, SettingResetButton } from "./settingsLayout";
import { useSettingsScope } from "./SettingsScopeContext";
import { searchableSetting } from "./settingsSearch";
import {
  useScopedSettings,
  useScopedSettingsMixed,
  useUpdateScopedSettings,
} from "./useScopedSettings";

const VIEWS = {
  chat: "Chat",
  terminal: "Terminal",
} satisfies Record<ThreadView, string>;

/**
 * Octet: whether a thread shows T3's chat or the agent's own CLI in a
 * terminal. Global, with per-project overrides like any project setting.
 */
export function ThreadViewSettings() {
  const settings = useScopedSettings();
  const updateSettings = useUpdateScopedSettings();
  const mixed = useScopedSettingsMixed(["threadView"]);
  const { targets } = useSettingsScope();
  const isProjectScope = targets.some((target) => target.projectId !== null);

  return (
    <SettingsRow
      serverScoped
      settingKeys={["threadView"]}
      mixed={mixed}
      {...searchableSetting("thread-view")}
      description={
        isProjectScope
          ? "How threads in this project show their agent."
          : "How threads show their agent: as a chat, or as the agent's own CLI in a terminal. Projects can override it."
      }
      status={
        !mixed && settings.threadView === "terminal"
          ? "The agent's CLI (claude, codex, …) runs in a terminal in the thread's folder, and keeps running when you switch away."
          : undefined
      }
      resetAction={
        settings.threadView !== DEFAULT_SERVER_SETTINGS.threadView || mixed ? (
          <SettingResetButton
            label="thread view"
            onClick={() => updateSettings({ threadView: DEFAULT_SERVER_SETTINGS.threadView })}
          />
        ) : null
      }
      control={
        <Select
          value={mixed ? null : settings.threadView}
          onValueChange={(value) => {
            if (ThreadView.literals.includes(value as ThreadView)) {
              updateSettings({ threadView: value as ThreadView });
            }
          }}
        >
          <SelectTrigger size="sm" aria-label="Thread view">
            <SelectValue>
              {(value: ThreadView | null) => (value === null ? "Mixed" : VIEWS[value])}
            </SelectValue>
          </SelectTrigger>
          <SelectPopup align="end" alignItemWithTrigger={false}>
            {ThreadView.literals.map((view) => (
              <SelectItem key={view} value={view}>
                {VIEWS[view]}
              </SelectItem>
            ))}
          </SelectPopup>
        </Select>
      }
    />
  );
}
