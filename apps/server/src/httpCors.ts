import { ORCHESTRATION_PROTOCOL_HEADER } from "@t3tools/contracts";

export const browserApiCorsAllowedMethods = ["GET", "POST", "OPTIONS"] as const;
export const browserApiCorsAllowedHeaders = [
  "authorization",
  "b3",
  "traceparent",
  "content-type",
  "dpop",
  ORCHESTRATION_PROTOCOL_HEADER,
] as const;

// Octet: the desktop app's renamed schemes (apps/desktop/src/electron/ElectronProtocol.ts).
export const DESKTOP_RENDERER_ORIGINS = ["octet-next://app", "octet-next-dev://app"] as const;
