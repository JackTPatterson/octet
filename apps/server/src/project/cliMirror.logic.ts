/**
 * Mirroring the agent's own CLI into a thread's chat history. A CLI run of the same
 * session writes every turn, including the ones the chat started, to the session log.
 * So a log message already in the thread (same role, same text) is not added again, and
 * the rest are: they are what was typed in the CLI.
 */
export interface MirrorMessage {
  readonly role: "user" | "assistant";
  readonly text: string;
}

export interface TranscriptMessage extends MirrorMessage {
  readonly createdAt: string;
}

/** Whitespace-insensitive, so wrapping and trailing newlines don't make a message look new. */
export function normalizeMirrorText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/**
 * The transcript messages the thread lacks, in transcript order. Each existing message
 * accounts for at most one transcript message, so a repeated "yes" is added only as many
 * times as the transcript has more of it than the thread.
 */
export function planCliMirror(
  existing: ReadonlyArray<MirrorMessage>,
  transcript: ReadonlyArray<TranscriptMessage>,
): ReadonlyArray<TranscriptMessage> {
  const remaining = new Map<string, number>();
  for (const message of existing) {
    const key = `${message.role}\u0000${normalizeMirrorText(message.text)}`;
    remaining.set(key, (remaining.get(key) ?? 0) + 1);
  }
  const missing: TranscriptMessage[] = [];
  for (const message of transcript) {
    const text = normalizeMirrorText(message.text);
    if (text === "") continue;
    const key = `${message.role}\u0000${text}`;
    const left = remaining.get(key) ?? 0;
    if (left > 0) remaining.set(key, left - 1);
    else missing.push(message);
  }
  return missing;
}

/**
 * A stable id for a mirrored message, so writing it twice (two flips racing) is one
 * message: the session, the message's time, role and which repeat of that text it is.
 */
export function mirrorMessageKey(input: {
  readonly sessionId: string;
  readonly message: TranscriptMessage;
  readonly occurrence: number;
}): string {
  const at = Date.parse(input.message.createdAt);
  const stamp = Number.isFinite(at) ? String(at) : input.message.createdAt;
  return `${input.sessionId.slice(0, 8)}:${stamp}:${input.message.role === "user" ? "u" : "a"}:${input.occurrence}`;
}
