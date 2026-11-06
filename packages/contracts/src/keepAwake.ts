import * as Schema from "effect/Schema";

/**
 * Keeping the machine awake while agents work. The client decides whether to hold (its
 * keep-awake mode, how many agents are working, whether the host is on battery) and asks
 * again every few seconds while it should; the server holds a sleep assertion for a short
 * lease each time and lets go when the asks stop, so a closed window never leaves it held.
 */
export const KeepAwakeInput = Schema.Struct({
  hold: Schema.Boolean,
});
export type KeepAwakeInput = typeof KeepAwakeInput.Type;

export const KeepAwakeResult = Schema.Struct({
  /** False where the host has no way to hold the assertion (anything but macOS). */
  supported: Schema.Boolean,
  holding: Schema.Boolean,
});
export type KeepAwakeResult = typeof KeepAwakeResult.Type;
