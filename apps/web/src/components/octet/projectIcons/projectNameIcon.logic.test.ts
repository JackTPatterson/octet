import { describe, expect, it } from "vite-plus/test";

import { projectNameIcon, projectNameTokens } from "./projectNameIcon.logic";

describe("project name icons", () => {
  it("splits names however they are written", () => {
    expect(projectNameTokens("fantasyEngine")).toEqual(["fantasy", "engine"]);
    expect(projectNameTokens("fantasy-engine")).toEqual(["fantasy", "engine"]);
    expect(projectNameTokens("Fantasy_Engine")).toEqual(["fantasy", "engine"]);
  });
  it("picks an icon from what the name says", () => {
    expect(projectNameIcon("toolbox")).toBe("wrench");
    expect(projectNameIcon("fantasy-hockey")).toBe("trophy");
    expect(projectNameIcon("pay-api")).toBe("credit-card");
    expect(projectNameIcon("octet")).toBe("hexagon-grid");
  });
  it("matches a long word by its start, a short one only whole", () => {
    expect(projectNameIcon("toolkit-x")).toBe("wrench");
    expect(projectNameIcon("tools")).toBe("wrench");
    // "ai" must be a whole word: "air" is not it, nor "maintenance".
    expect(projectNameIcon("air")).toBeNull();
    expect(projectNameIcon("ai-notes")).toBe("sparkles");
  });
  it("keeps the initials when nothing matches", () => {
    expect(projectNameIcon("zzqx")).toBeNull();
    expect(projectNameIcon("")).toBeNull();
  });
});
