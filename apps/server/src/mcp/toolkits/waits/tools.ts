import {
  OrchestratorMcpFailure,
  PROVIDER_SEND_TURN_MAX_INPUT_CHARS,
  Wait,
  WaitCondition,
  WaitId,
  TrimmedNonEmptyString,
} from "@t3tools/contracts";
import * as Schema from "effect/Schema";
import { Tool, Toolkit } from "effect/ai";

import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as ProjectService from "../../../project/ProjectService.ts";
import * as ThreadManagementService from "../../../orchestration-v2/ThreadManagementService.ts";
import * as WaitService from "../../../waits/WaitService.ts";

const dependencies = [
  McpInvocationContext.McpInvocationContext,
  ThreadManagementService.ThreadManagementService,
  ProjectService.ProjectService,
  WaitService.WaitService,
];

export const WaitForInput = Schema.Struct({
  title: TrimmedNonEmptyString.annotate({
    description: "What it waits for, in words: `the API migration PR merged`.",
  }),
  condition: WaitCondition.annotate({
    description:
      "`pull_request_merged` (repository owner/name + number), `url_up` (a URL answering 2xx or 3xx), `date` (an ISO 8601 time with an offset), or `manual` when only a person can tell. Octet checks the others itself.",
  }),
  next: Schema.String.check(Schema.isMaxLength(PROVIDER_SEND_TURN_MAX_INPUT_CHARS)).annotate({
    description:
      "The next step, written so it makes sense with no memory of this conversation: it is sent to this thread when the condition is met.",
  }),
  autoContinue: Schema.optional(Schema.Boolean).annotate({
    description:
      "Send `next` to this thread as soon as the condition is met. Default: false, the person sends it.",
  }),
});
export type WaitForInput = typeof WaitForInput.Type;

export const WaitForResult = Schema.Struct({ wait: Wait });
export const ListWaitsResult = Schema.Struct({ waits: Schema.Array(Wait) });
export const CancelWaitInput = Schema.Struct({ id: WaitId });
export type CancelWaitInput = typeof CancelWaitInput.Type;

const WaitForTool = Tool.make("wait_for", {
  description:
    "When the work cannot continue until something outside it happens (a pull request merged, a URL up, a date, someone's answer), record what to wait for and the next step instead of leaving it to be remembered. Octet checks the condition and brings the work back with `next` when it is met.",
  parameters: WaitForInput,
  success: WaitForResult,
  failure: OrchestratorMcpFailure,
  failureMode: "return",
  dependencies,
})
  .annotate(Tool.Title, "Wait for something, then continue")
  .annotate(Tool.Readonly, false)
  .annotate(Tool.Destructive, false)
  .annotate(Tool.Idempotent, false)
  .annotate(Tool.OpenWorld, true);

const ListWaitsTool = Tool.make("list_waits", {
  description: "List waits: what each waits for, its state, and what the last check found.",
  success: ListWaitsResult,
  failure: OrchestratorMcpFailure,
  failureMode: "return",
  dependencies,
})
  .annotate(Tool.Title, "List waits")
  .annotate(Tool.Readonly, true)
  .annotate(Tool.Destructive, false)
  .annotate(Tool.Idempotent, true)
  .annotate(Tool.OpenWorld, false);

const CancelWaitTool = Tool.make("cancel_wait", {
  description: "Stop waiting: the wait is cancelled and never sends its next step.",
  parameters: CancelWaitInput,
  success: WaitForResult,
  failure: OrchestratorMcpFailure,
  failureMode: "return",
  dependencies,
})
  .annotate(Tool.Title, "Cancel a wait")
  .annotate(Tool.Readonly, false)
  .annotate(Tool.Destructive, false)
  .annotate(Tool.Idempotent, true)
  .annotate(Tool.OpenWorld, false);

export const OctetWaitsToolkit = Toolkit.make(WaitForTool, ListWaitsTool, CancelWaitTool);
