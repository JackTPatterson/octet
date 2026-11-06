/**
 * Octet's waits in the sidebar's Waiting shelf: work that can't go on until
 * something outside happens, set by you or by an agent. The server checks the
 * condition; this file shapes what the shelf says about each wait.
 */
export type WaitConditionLike =
  | { readonly type: "date"; readonly at: string }
  | {
      readonly type: "pull_request_merged";
      readonly repository: string;
      readonly number: number;
      readonly host?: string | undefined;
    }
  | { readonly type: "url_up"; readonly url: string }
  | { readonly type: "manual"; readonly description?: string | undefined };

export interface WaitLike {
  readonly id: string;
  readonly title: string;
  readonly condition: WaitConditionLike;
  readonly next: string;
  readonly state: "waiting" | "ready" | "cancelled";
  readonly continuedAt: string | null;
  readonly readyAt: string | null;
  readonly createdAt: string;
  readonly createdBy: string;
  readonly lastResult: string | null;
  readonly origin: { readonly threadId?: string | undefined };
}

/** The condition in words: "PR #12 merged", "Nov 12, 3:00 PM", "example.com up". */
export function describeWaitCondition(condition: WaitConditionLike, locale?: string): string {
  switch (condition.type) {
    case "pull_request_merged":
      return `${condition.repository}#${condition.number} merged`;
    case "url_up":
      try {
        return `${new URL(condition.url).host} up`;
      } catch {
        return `${condition.url} up`;
      }
    case "date": {
      const at = new Date(condition.at);
      if (Number.isNaN(at.getTime())) return condition.at;
      return at.toLocaleString(locale, {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      });
    }
    case "manual":
      return condition.description ?? "Waiting on you";
  }
}

/** Waits worth showing: not cancelled, and not already carried on. */
export function visibleWaits<T extends WaitLike>(waits: readonly T[]): readonly T[] {
  return waits
    .filter((wait) => wait.state !== "cancelled" && wait.continuedAt === null)
    .toSorted((left, right) => {
      // What is ready to carry on comes first, then the newest.
      const ready = Number(right.state === "ready") - Number(left.state === "ready");
      if (ready !== 0) return ready;
      return Date.parse(right.createdAt) - Date.parse(left.createdAt);
    });
}

export type WaitAction = "continue" | "done" | null;

/**
 * What the row offers. A ready wait with a next step can be carried on; a
 * manual wait is settled by saying it happened; a ready wait with nothing to
 * send only comes back, so it can be dismissed.
 */
export function waitAction(wait: Pick<WaitLike, "state" | "condition" | "next">): WaitAction {
  if (wait.state === "ready") return wait.next.trim().length > 0 ? "continue" : null;
  if (wait.state === "waiting" && wait.condition.type === "manual") return "done";
  return null;
}

export function waitStatusLabel(wait: Pick<WaitLike, "state" | "lastResult">): string {
  if (wait.state === "ready") return "Ready";
  return wait.lastResult ? `Waiting · ${wait.lastResult}` : "Waiting";
}

/** What a person types to make or change a wait. */
export type WaitFormKind = "manual" | "date" | "pull_request_merged" | "url_up";

export interface WaitForm {
  readonly title: string;
  readonly kind: WaitFormKind;
  /** manual: what you are to confirm. */
  readonly description: string;
  /** date: a `datetime-local` value, in the person's own time zone. */
  readonly date: string;
  /** pull request: owner/name and the number. */
  readonly repository: string;
  readonly number: string;
  readonly url: string;
  readonly next: string;
  readonly autoContinue: boolean;
}

export const WAIT_FORM_KINDS: ReadonlyArray<{ readonly kind: WaitFormKind; readonly label: string }> = [
  { kind: "manual", label: "You say so" },
  { kind: "date", label: "A date and time" },
  { kind: "pull_request_merged", label: "A pull request merged" },
  { kind: "url_up", label: "A URL answering" },
];

export const EMPTY_WAIT_FORM: WaitForm = {
  title: "",
  kind: "manual",
  description: "",
  date: "",
  repository: "",
  number: "",
  url: "",
  next: "",
  autoContinue: false,
};

const pad = (value: number) => String(value).padStart(2, "0");

/** A `datetime-local` value (no zone) for an instant, in the local zone. */
export function toLocalDateInput(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return "";
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}T${pad(at.getHours())}:${pad(at.getMinutes())}`;
}

export function waitFormFromWait(wait: WaitLike & { readonly autoContinue: boolean }): WaitForm {
  const { condition } = wait;
  return {
    ...EMPTY_WAIT_FORM,
    title: wait.title,
    kind: condition.type,
    description: condition.type === "manual" ? (condition.description ?? "") : "",
    date: condition.type === "date" ? toLocalDateInput(condition.at) : "",
    repository: condition.type === "pull_request_merged" ? condition.repository : "",
    number: condition.type === "pull_request_merged" ? String(condition.number) : "",
    url: condition.type === "url_up" ? condition.url : "",
    next: wait.next,
    autoContinue: wait.autoContinue,
  };
}

/** The condition the form describes, or null when it is not complete. */
export function waitConditionFromForm(form: WaitForm): WaitConditionLike | null {
  switch (form.kind) {
    case "manual": {
      const description = form.description.trim();
      return description.length > 0 ? { type: "manual", description } : { type: "manual" };
    }
    case "date": {
      const at = new Date(form.date);
      return form.date.length > 0 && !Number.isNaN(at.getTime())
        ? { type: "date", at: at.toISOString() }
        : null;
    }
    case "pull_request_merged": {
      const repository = form.repository.trim();
      const number = Number(form.number.trim());
      return /^[^\s/]+\/[^\s/]+$/.test(repository) && Number.isInteger(number) && number > 0
        ? { type: "pull_request_merged", repository, number }
        : null;
    }
    case "url_up": {
      const url = form.url.trim();
      try {
        const parsed = new URL(url);
        return parsed.protocol === "http:" || parsed.protocol === "https:"
          ? { type: "url_up", url }
          : null;
      } catch {
        return null;
      }
    }
  }
}

/**
 * Why the form can't be saved yet, in a few words; null when it can. `canSendNext`
 * is whether the wait has a thread to send the next step to, `hasProject` whether
 * a pull request has a project to be looked up in.
 */
export function waitFormProblem(
  form: WaitForm,
  context: { readonly canSendNext: boolean; readonly hasProject: boolean },
): string | null {
  if (form.title.trim().length === 0) return "Say what you are waiting for.";
  if (waitConditionFromForm(form) === null) {
    switch (form.kind) {
      case "date":
        return "Pick a date and time.";
      case "pull_request_merged":
        return "Give the repository as owner/name and a pull request number.";
      case "url_up":
        return "Give an http or https URL.";
      default:
        return "Describe what to wait for.";
    }
  }
  if (form.kind === "pull_request_merged" && !context.hasProject) {
    return "A pull request is looked up in a project; open one first.";
  }
  if (form.autoContinue && form.next.trim().length === 0) return "Auto-continue needs a next step.";
  if (form.autoContinue && !context.canSendNext) return "Auto-continue needs a thread to send to.";
  return null;
}
