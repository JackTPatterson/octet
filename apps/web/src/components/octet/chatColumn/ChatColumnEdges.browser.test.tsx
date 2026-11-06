// The screenshot needs the app's styles; the browser project does not load them by default.
import "../../../index.css";

import { useEffect } from "react";
import { afterEach, expect, it, vi } from "vite-plus/test";
import { page } from "vite-plus/test/browser";

import { act, render } from "../../../../test/render";
import {
  getClientSettings,
  updateClientSettings,
  useClientSettings,
} from "../../../hooks/useSettings";
import { ChatColumnEdges } from "./ChatColumnEdges";

afterEach(() => updateClientSettings({ chatWidth: "comfortable" }));

const WIDTH = 1600;

function Frame() {
  // The app mirrors the setting onto the root, which sizes the column (see appInit).
  const chatWidth = useClientSettings((settings) => settings.chatWidth);
  useEffect(() => {
    document.documentElement.dataset.chatWidth = chatWidth;
    return () => {
      delete document.documentElement.dataset.chatWidth;
    };
  }, [chatWidth]);
  return (
    <div
      data-testid="frame"
      className="relative bg-background"
      style={{ width: WIDTH, height: 300 }}
    >
      {/* The column, as the timeline draws it. */}
      <div
        className="mx-auto h-full border-x border-dashed border-border/60"
        style={{ maxWidth: "var(--chat-content-max-width)" }}
      />
      <ChatColumnEdges />
    </div>
  );
}

const pointer = { bubbles: true, pointerId: 1, button: 0 };

it("drags the column between its widths, and Escape, double-click and arrows adjust it", async () => {
  await page.viewport(1700, 700);
  await using screen = await render(<Frame />, { router: false });
  const frame = page.getByTestId("frame").element() as HTMLElement;
  const left = frame.getBoundingClientRect().left;
  // The strips appear once the overlay has measured its width.
  await vi.waitFor(() =>
    expect(screen.container.querySelector('[data-testid="chat-column-edge-right"]')).not.toBeNull(),
  );
  const right = screen.container.querySelector<HTMLElement>('[data-testid="chat-column-edge-right"]')!;
  // Synthetic drag events have no active browser pointer to capture.
  using _capture = vi.spyOn(right, "setPointerCapture").mockImplementation(() => {});
  const move = (type: string, distanceFromCentre: number) =>
    act(() => {
      right.dispatchEvent(
        new PointerEvent(type, { ...pointer, clientX: left + WIDTH / 2 + distanceFromCentre }),
      );
    });

  // Out past the halfway point to the full column.
  await move("pointerdown", 368);
  await move("pointermove", 770);
  expect(getClientSettings().chatWidth).toBe("full");
  await expect.element(page.getByTestId("frame")).toMatchScreenshot("chat-column-edges-dragging");

  // Escape puts it back as it was when the drag began.
  await act(() => {
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(getClientSettings().chatWidth).toBe("comfortable");
  // The drag is over: further movement changes nothing.
  await move("pointermove", 770);
  expect(getClientSettings().chatWidth).toBe("comfortable");

  // A finished drag keeps its width.
  await move("pointerdown", 368);
  await move("pointermove", 770);
  await move("pointerup", 770);
  expect(getClientSettings().chatWidth).toBe("full");

  // The arrow keys step it, and a double-click goes back to the default.
  const edge = page.getByTestId("chat-column-edge-right");
  edge.element().focus();
  await act(() => {
    edge.element().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
  });
  expect(getClientSettings().chatWidth).toBe("comfortable");
  await act(() => {
    edge.element().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  expect(getClientSettings().chatWidth).toBe("full");
  await edge.element().dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
  await vi.waitFor(() => expect(getClientSettings().chatWidth).toBe("comfortable"));
});
