import {
  getClientSettings,
  updateClientSettings,
  useClientSettings,
} from "../../../hooks/useSettings";
import {
  MenuCheckboxItem,
  MenuGroup,
  MenuGroupLabel,
  MenuItem,
  MenuSeparator,
} from "../../ui/menu";
import {
  isDefaultStatusBar,
  RESET_STATUS_BAR,
  resolveStatusBarOrder,
  resolveStatusBarVisibility,
  setStatusBarItemVisible,
  STATUS_BAR_ITEMS,
} from "./octetStatusBarItems";

/** Show/hide menu for the status bar's chips: its right-click menu. Order is set in Settings. */
export function StatusBarItemsMenuItems() {
  const settings = useClientSettings((current) => ({
    statusBarItems: current.statusBarItems,
    statusBarOrder: current.statusBarOrder,
  }));
  const visibility = resolveStatusBarVisibility(settings.statusBarItems);
  return (
    <>
      <MenuGroup>
        <MenuGroupLabel>Show in status bar</MenuGroupLabel>
        {resolveStatusBarOrder(settings.statusBarOrder).map((id) => (
          <MenuCheckboxItem
            key={id}
            checked={visibility[id]}
            onCheckedChange={(checked) =>
              updateClientSettings({
                statusBarItems: setStatusBarItemVisible(
                  getClientSettings().statusBarItems,
                  id,
                  checked,
                ),
              })
            }
          >
            {STATUS_BAR_ITEMS.find((item) => item.id === id)!.label}
          </MenuCheckboxItem>
        ))}
      </MenuGroup>
      <MenuSeparator />
      <MenuItem
        disabled={isDefaultStatusBar(settings)}
        onClick={() => updateClientSettings(RESET_STATUS_BAR)}
      >
        Reset to default
      </MenuItem>
    </>
  );
}
