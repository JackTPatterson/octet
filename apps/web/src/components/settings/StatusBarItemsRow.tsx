import { ArrowDownIcon, ArrowUpIcon, ChevronDownIcon } from "lucide-react";

import {
  getClientSettings,
  updateClientSettings,
  useClientSettings,
} from "../../hooks/useSettings";
import {
  isDefaultStatusBar,
  moveStatusBarItem,
  RESET_STATUS_BAR,
  resolveStatusBarOrder,
  resolveStatusBarVisibility,
  setStatusBarItemVisible,
  STATUS_BAR_ITEMS,
} from "../octet/statusBar/octetStatusBarItems";
import { Button } from "../ui/button";
import { Checkbox } from "../ui/checkbox";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover";
import { SettingResetButton, SettingsRow } from "./settingsLayout";
import { searchableSetting } from "./settingsSearch";

/** Octet: which chips the status bar shows, and in what order. */
export function StatusBarItemsRow() {
  const settings = useClientSettings((current) => ({
    statusBarItems: current.statusBarItems,
    statusBarOrder: current.statusBarOrder,
  }));
  const visibility = resolveStatusBarVisibility(settings.statusBarItems);
  const order = resolveStatusBarOrder(settings.statusBarOrder);
  const shown = STATUS_BAR_ITEMS.filter((item) => visibility[item.id]).length;
  return (
    <SettingsRow
      {...searchableSetting("status-bar-items")}
      description="Choose which chips the status bar under a thread shows, and their order. You can also right-click the bar."
      resetAction={
        isDefaultStatusBar(settings) ? null : (
          <SettingResetButton
            label="status bar"
            onClick={() => updateClientSettings(RESET_STATUS_BAR)}
          />
        )
      }
      control={
        <Popover>
          <PopoverTrigger
            render={
              <Button
                variant="outline"
                size="sm"
                className="w-full justify-between sm:w-40"
                aria-label={`Status bar: ${shown} of ${STATUS_BAR_ITEMS.length} on`}
              />
            }
          >
            {shown} of {STATUS_BAR_ITEMS.length} on
            <ChevronDownIcon aria-hidden />
          </PopoverTrigger>
          <PopoverPopup align="end" className="w-64">
            <ul className="flex flex-col gap-0.5" data-testid="status-bar-items-editor">
              {order.map((id, index) => {
                const item = STATUS_BAR_ITEMS.find((candidate) => candidate.id === id)!;
                return (
                  <li key={id} className="flex items-center gap-2 rounded-md px-1 py-0.5">
                    <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-2 text-sm">
                      <Checkbox
                        checked={visibility[id]}
                        onCheckedChange={(checked) =>
                          updateClientSettings({
                            statusBarItems: setStatusBarItemVisible(
                              getClientSettings().statusBarItems,
                              id,
                              checked === true,
                            ),
                          })
                        }
                      />
                      <span className="truncate">{item.label}</span>
                    </label>
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-label={`Move ${item.label} earlier`}
                      disabled={index === 0}
                      onClick={() =>
                        updateClientSettings({
                          statusBarOrder: moveStatusBarItem(
                            getClientSettings().statusBarOrder,
                            id,
                            -1,
                          ),
                        })
                      }
                    >
                      <ArrowUpIcon aria-hidden />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon-xs"
                      aria-label={`Move ${item.label} later`}
                      disabled={index === order.length - 1}
                      onClick={() =>
                        updateClientSettings({
                          statusBarOrder: moveStatusBarItem(
                            getClientSettings().statusBarOrder,
                            id,
                            1,
                          ),
                        })
                      }
                    >
                      <ArrowDownIcon aria-hidden />
                    </Button>
                  </li>
                );
              })}
            </ul>
          </PopoverPopup>
        </Popover>
      }
    />
  );
}
