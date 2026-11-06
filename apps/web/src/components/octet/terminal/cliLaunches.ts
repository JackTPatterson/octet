/**
 * When the agent's CLI was last started in each thread's terminal, in this window. A flip
 * to chat uses it to tell the CLI's new session from older ones in the same folder, and
 * the terminal view uses it so a quick flip back doesn't start the CLI twice.
 */
const launches = new Map<string, number>();

export function recordCliLaunch(threadKey: string, atMs: number = Date.now()): void {
  launches.set(threadKey, atMs);
}

export function lastCliLaunch(threadKey: string): number | null {
  return launches.get(threadKey) ?? null;
}

/**
 * Threads whose CLI a flip to chat stopped, so the terminal view knows its idle shell is
 * ours to restart. Typing the command into a shell we didn't leave idle could land it in
 * the CLI as a prompt, so nothing else relaunches it.
 */
const stoppedByFlip = new Set<string>();

export function markCliStoppedByFlip(threadKey: string): void {
  stoppedByFlip.add(threadKey);
}

/** True once, if a flip stopped this thread's CLI since the terminal view last took it. */
export function takeCliStoppedByFlip(threadKey: string): boolean {
  return stoppedByFlip.delete(threadKey);
}
