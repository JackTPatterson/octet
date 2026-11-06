import { describe, expect, it } from "vite-plus/test";

import { detectServiceSlug } from "./serviceKind.logic";

describe("detectServiceSlug", () => {
  it("prefers a framework name over the runtime", () => {
    expect(detectServiceSlug({ processName: "next-server", port: 3000 })).toBe("nextdotjs");
    expect(detectServiceSlug({ processName: "/usr/bin/vite.js", port: 5173 })).toBe("vite");
  });
  it("falls back to well-known ports, then the runtime", () => {
    expect(detectServiceSlug({ processName: "com.apple.foo", port: 5432 })).toBe("postgresql");
    expect(detectServiceSlug({ processName: "node", port: 4000 })).toBe("nodedotjs");
    expect(detectServiceSlug({ processName: "python3.12", port: 8000 })).toBe("python");
  });
  it("returns null when nothing matches", () => {
    expect(detectServiceSlug({ processName: null, port: 4000 })).toBeNull();
  });
});
