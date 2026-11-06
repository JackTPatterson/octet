import { describe, expect, it } from "vite-plus/test";

import {
  chatColumnWidth,
  distinctChatWidths,
  nearestChatWidth,
  stepChatWidth,
} from "./chatColumn.logic";

describe("chat column widths", () => {
  it("sizes each setting, and caps it at the window", () => {
    expect(chatColumnWidth("comfortable", 1600)).toBe(736);
    expect(chatColumnWidth("wide", 1600)).toBe(1152);
    expect(chatColumnWidth("full", 1600)).toBe(1552);
    expect(chatColumnWidth("wide", 900)).toBe(852);
  });
  it("leaves out a width that is as wide as a later one", () => {
    expect(distinctChatWidths(1600)).toEqual(["comfortable", "full"]);
    expect(distinctChatWidths(780)).toEqual(["full"]);
    expect(distinctChatWidths(700)).toEqual(["full"]);
  });
  it("snaps to the nearest column as the pointer passes it", () => {
    expect(nearestChatWidth(500, 1600)).toBe("comfortable");
    expect(nearestChatWidth(1000, 1600)).toBe("comfortable");
    expect(nearestChatWidth(1200, 1600)).toBe("full");
    expect(nearestChatWidth(1500, 1600)).toBe("full");
    expect(nearestChatWidth(1000, 1000)).toBe("full");
  });
  it("steps one width at a time and stops at the ends", () => {
    expect(stepChatWidth("comfortable", 1, 1600)).toBe("full");
    expect(stepChatWidth("full", 1, 1600)).toBe("full");
    expect(stepChatWidth("full", -1, 1600)).toBe("comfortable");
    expect(stepChatWidth("comfortable", -1, 1600)).toBe("comfortable");
    // A saved "wide" counts as the stop it is nearer to.
    expect(stepChatWidth("wide", -1, 1600)).toBe("comfortable");
  });
});
