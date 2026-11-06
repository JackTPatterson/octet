// The screenshot needs the app's styles; the browser project does not load them by default.
import "../../index.css";

import { afterEach, expect, it } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

import { render } from "../../../test/render";
import { getClientSettings, updateClientSettings } from "../../hooks/useSettings";
import { RESET_STATUS_BAR } from "../octet/statusBar/octetStatusBarItems";
import { StatusBarItemsRow } from "./StatusBarItemsRow";

afterEach(() => updateClientSettings(RESET_STATUS_BAR));

it("reorders and hides status bar chips from the settings row", async () => {
  await using screen = await render(<StatusBarItemsRow />);

  await screen.getByRole("button", { name: /Status bar: 10 of 10 on/ }).click();
  await expect.element(page.getByTestId("status-bar-items-editor")).toBeVisible();

  // Move Git branch up past Directory, then hide CI.
  await page.getByRole("button", { name: "Move Git branch earlier" }).click();
  expect(getClientSettings().statusBarOrder.slice(2, 5)).toEqual(["runtime", "branch", "directory"]);

  await page.getByRole("checkbox", { name: "CI" }).click();
  expect(getClientSettings().statusBarItems).toEqual({ ci: false });
  await expect.element(page.getByRole("button", { name: /Status bar: 9 of 10 on/ })).toBeVisible();

  await expect.element(page.getByTestId("status-bar-items-editor")).toMatchScreenshot(
    "status-bar-items-editor",
  );

  // Checking it again drops the override, so a later default change reaches this person.
  await page.getByRole("checkbox", { name: "CI" }).click();
  expect(getClientSettings().statusBarItems).toEqual({});
});
