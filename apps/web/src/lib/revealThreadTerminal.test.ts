import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { beforeEach, expect, it } from "vite-plus/test";

import { selectThreadRightPanelState, useRightPanelStore } from "../rightPanelStore";
import { selectThreadTerminalUiState, useTerminalUiStateStore } from "../terminalUiStateStore";
import { revealThreadTerminal } from "./revealThreadTerminal";

const threadRef = scopeThreadRef(EnvironmentId.make("local"), ThreadId.make("settled-thread"));
const remoteRef = scopeThreadRef(EnvironmentId.make("remote"), threadRef.threadId);

beforeEach(() => {
  useTerminalUiStateStore.setState({
    terminalUiStateByThreadKey: {},
    suppressedTerminalIdsByThreadKey: {},
  });
  useRightPanelStore.setState({ byThreadKey: {} });
});

it("opens a terminal in the bottom drawer and leaves the right panel alone", () => {
  revealThreadTerminal(threadRef, "setup-install");
  expect(
    selectThreadTerminalUiState(
      useTerminalUiStateStore.getState().terminalUiStateByThreadKey,
      threadRef,
    ),
  ).toMatchObject({ terminalOpen: true, activeTerminalId: "setup-install" });
  expect(
    selectThreadRightPanelState(useRightPanelStore.getState().byThreadKey, threadRef).surfaces,
  ).toEqual([]);
});

it("reveals terminals in their own environment without changing another environment's drawer", () => {
  revealThreadTerminal(threadRef, "default");
  revealThreadTerminal(remoteRef, "setup-install");
  const state = useTerminalUiStateStore.getState().terminalUiStateByThreadKey;
  expect(selectThreadTerminalUiState(state, threadRef).terminalIds).toEqual(["default"]);
  expect(selectThreadTerminalUiState(state, remoteRef).terminalIds).toEqual(["setup-install"]);
});
