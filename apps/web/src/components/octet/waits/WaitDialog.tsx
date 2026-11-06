import type { EnvironmentId, Wait, WaitOrigin } from "@t3tools/contracts";
import { AsyncResult } from "effect/reactivity";
import { useState } from "react";

import { serverEnvironment } from "../../../state/server";
import { useAtomCommand } from "../../../state/use-atom-command";
import { Button } from "../../ui/button";
import {
  Dialog,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../../ui/dialog";
import { Input } from "../../ui/input";
import { Label } from "../../ui/label";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import { Switch } from "../../ui/switch";
import { Textarea } from "../../ui/textarea";
import {
  EMPTY_WAIT_FORM,
  WAIT_FORM_KINDS,
  waitConditionFromForm,
  waitFormFromWait,
  waitFormProblem,
  type WaitForm,
  type WaitFormKind,
} from "./waits.logic";

const KIND_LABEL = Object.fromEntries(WAIT_FORM_KINDS.map((entry) => [entry.kind, entry.label])) as Record<
  WaitFormKind,
  string
>;

/**
 * Make a wait by hand, or change one. With `wait` it edits (a ready wait can
 * change its title and next step, not what it waits for); with `origin` it
 * makes a new one, set from that thread and project.
 */
export function WaitDialog(props: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly environmentId: EnvironmentId;
  readonly wait?: Wait;
  readonly origin?: WaitOrigin;
}) {
  const { wait, origin } = props;
  const createWait = useAtomCommand(serverEnvironment.createWait, { label: "wait create" });
  const updateWait = useAtomCommand(serverEnvironment.updateWait, { label: "wait update" });
  const [form, setForm] = useState<WaitForm>(() => (wait ? waitFormFromWait(wait) : EMPTY_WAIT_FORM));
  const [saving, setSaving] = useState(false);
  const target = wait?.origin ?? origin;
  const conditionLocked = wait !== undefined && wait.state !== "waiting";

  const set = <K extends keyof WaitForm>(key: K, value: WaitForm[K]) =>
    setForm((current) => ({ ...current, [key]: value }));
  const problem = waitFormProblem(form, {
    canSendNext: target?.threadId !== undefined,
    hasProject: target?.projectId !== undefined,
  });
  const canSave = problem === null && target !== undefined && !saving;

  const close = (next: boolean) => {
    props.onOpenChange(next);
    if (!next) {
      setForm(wait ? waitFormFromWait(wait) : EMPTY_WAIT_FORM);
      setSaving(false);
    }
  };

  const save = async () => {
    const condition = waitConditionFromForm(form);
    if (!canSave || condition === null || target === undefined) return;
    setSaving(true);
    const result = wait
      ? await updateWait({
          environmentId: props.environmentId,
          input: {
            id: wait.id,
            title: form.title.trim(),
            next: form.next.trim(),
            autoContinue: form.autoContinue,
            ...(conditionLocked ? {} : { condition }),
          },
        })
      : await createWait({
          environmentId: props.environmentId,
          input: {
            title: form.title.trim(),
            condition,
            next: form.next.trim(),
            autoContinue: form.autoContinue,
            origin: target,
          },
        });
    setSaving(false);
    if (AsyncResult.isSuccess(result)) close(false);
  };

  return (
    <Dialog open={props.open} onOpenChange={close}>
      <DialogPopup className="max-w-md">
        <DialogHeader>
          <DialogTitle>{wait ? "Edit wait" : "Wait for something"}</DialogTitle>
          <DialogDescription>
            Octet watches for it and brings the work back when it happens
            {wait ? "." : ", with the next step if you give one."}
          </DialogDescription>
        </DialogHeader>
        <DialogPanel>
          <form
            className="grid gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              void save();
            }}
          >
            <div className="grid gap-1.5">
              <Label htmlFor="wait-title">Waiting for</Label>
              <Input
                id="wait-title"
                placeholder="The API migration PR merged"
                value={form.title}
                onChange={(event) => set("title", event.target.value)}
                autoFocus
              />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="wait-kind">When</Label>
              <Select
                value={form.kind}
                disabled={conditionLocked}
                onValueChange={(value) => set("kind", value as WaitFormKind)}
              >
                <SelectTrigger id="wait-kind" aria-label="What to wait for">
                  <SelectValue>{(value: WaitFormKind | null) => (value ? KIND_LABEL[value] : "")}</SelectValue>
                </SelectTrigger>
                <SelectPopup alignItemWithTrigger={false}>
                  {WAIT_FORM_KINDS.map((entry) => (
                    <SelectItem key={entry.kind} value={entry.kind}>
                      {entry.label}
                    </SelectItem>
                  ))}
                </SelectPopup>
              </Select>
            </div>
            {form.kind === "manual" ? (
              <div className="grid gap-1.5">
                <Label htmlFor="wait-description">What you will confirm (optional)</Label>
                <Input
                  id="wait-description"
                  placeholder="Approved"
                  disabled={conditionLocked}
                  value={form.description}
                  onChange={(event) => set("description", event.target.value)}
                />
              </div>
            ) : null}
            {form.kind === "date" ? (
              <div className="grid gap-1.5">
                <Label htmlFor="wait-date">Date and time</Label>
                <Input
                  id="wait-date"
                  type="datetime-local"
                  disabled={conditionLocked}
                  value={form.date}
                  onChange={(event) => set("date", event.target.value)}
                />
              </div>
            ) : null}
            {form.kind === "pull_request_merged" ? (
              <div className="grid grid-cols-[1fr_6rem] gap-2">
                <div className="grid gap-1.5">
                  <Label htmlFor="wait-repository">Repository</Label>
                  <Input
                    id="wait-repository"
                    placeholder="owner/name"
                    disabled={conditionLocked}
                    value={form.repository}
                    onChange={(event) => set("repository", event.target.value)}
                  />
                </div>
                <div className="grid gap-1.5">
                  <Label htmlFor="wait-number">PR number</Label>
                  <Input
                    id="wait-number"
                    inputMode="numeric"
                    placeholder="12"
                    disabled={conditionLocked}
                    value={form.number}
                    onChange={(event) => set("number", event.target.value)}
                  />
                </div>
              </div>
            ) : null}
            {form.kind === "url_up" ? (
              <div className="grid gap-1.5">
                <Label htmlFor="wait-url">URL</Label>
                <Input
                  id="wait-url"
                  placeholder="https://staging.example.com/health"
                  disabled={conditionLocked}
                  value={form.url}
                  onChange={(event) => set("url", event.target.value)}
                />
              </div>
            ) : null}
            <div className="grid gap-1.5">
              <Label htmlFor="wait-next">Then (optional)</Label>
              <Textarea
                id="wait-next"
                rows={3}
                placeholder="What to send the thread when it happens"
                value={form.next}
                onChange={(event) => set("next", event.target.value)}
              />
            </div>
            <div className="flex items-center justify-between gap-3">
              <Label htmlFor="wait-auto" className="font-normal">
                Send it as soon as it happens
              </Label>
              <Switch
                id="wait-auto"
                checked={form.autoContinue}
                onCheckedChange={(checked) => set("autoContinue", checked)}
              />
            </div>
            {problem !== null && form.title.trim().length > 0 ? (
              <p className="text-muted-foreground text-xs">{problem}</p>
            ) : null}
          </form>
        </DialogPanel>
        <DialogFooter variant="bare">
          <Button variant="outline" onClick={() => close(false)}>
            Cancel
          </Button>
          <Button onClick={() => void save()} disabled={!canSave}>
            {wait ? "Save" : "Wait"}
          </Button>
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}
