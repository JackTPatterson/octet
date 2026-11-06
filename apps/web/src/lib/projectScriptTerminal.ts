/**
 * Project actions reuse only an idle drawer terminal (the active one first).
 */
export function findReusableProjectScriptTerminal(input: {
  readonly drawerTerminalIds: ReadonlyArray<string>;
  readonly activeTerminalId: string;
  readonly runningTerminalIds: ReadonlyArray<string>;
}): string | null {
  const idleDrawerTerminalIds = input.drawerTerminalIds.filter(
    (terminalId) => !input.runningTerminalIds.includes(terminalId),
  );
  if (idleDrawerTerminalIds.includes(input.activeTerminalId)) return input.activeTerminalId;
  return idleDrawerTerminalIds[0] ?? null;
}
