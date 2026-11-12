import { toastManager } from "../ui/toast";
import { randomUUID } from "../../lib/utils";
import type { Editor } from "@tiptap/core";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { MicIcon } from "lucide-react";
import "./composerVoiceInput.css";

const waveformBars = Array.from({ length: 32 }, (_, index) => `bar-${index}`);

type Recording = {
  phase: "starting" | "listening" | "finishing";
  partial: string;
  levels: number[];
  shell: HTMLElement;
};

function reportError(description: string) {
  toastManager.add({ type: "error", title: "Couldn't start voice input", description });
}

export function ComposerVoiceInput({ editor }: { editor: Editor | null }) {
  const [recording, setRecording] = useState<Recording | null>(null);

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- owns native dictation and keyboard listeners for this editor's lifetime.
  useEffect(() => {
    const voice = window.desktopBridge?.voiceInput;
    if (!editor || !voice) return;
    const dom = editor.view.dom;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let pending = false;
    let awaitingPermission = false;
    let id: string | null = null;
    let shell: HTMLElement | null = null;
    let originalDoc = editor.state.doc;
    let selection = editor.state.selection;
    const clearHold = () => {
      clearTimeout(timer);
      timer = undefined;
      pending = false;
    };
    const restore = () => {
      if (shell) {
        delete shell.dataset.voiceRecording;
        shell.style.removeProperty("--voice-width");
        shell.style.removeProperty("--voice-height");
        shell = null;
      }
      setRecording(null);
    };
    const cancel = () => {
      clearHold();
      if (id) void voice.control({ id, action: "cancel" }).catch(() => {});
      id = null;
      restore();
    };
    const insertSpace = () => {
      clearHold();
      if (editor.isEditable) editor.commands.insertContent(" ");
    };
    const unsubscribe = voice.subscribe((event) => {
      if (event.id !== id) return;
      if (event.type === "final") {
        const text = event.text.trim();
        id = null;
        restore();
        if (text && editor.isEditable && editor.state.doc.eq(originalDoc)) {
          const before = originalDoc.textBetween(Math.max(0, selection.from - 1), selection.from);
          const after = originalDoc.textBetween(
            selection.to,
            Math.min(originalDoc.content.size, selection.to + 1),
          );
          const prefix = before && !/\s$/.test(before) ? " " : "";
          const suffix = after && !/^\s|^[.,!?;:]/.test(after) ? " " : "";
          editor.view.dispatch(
            editor.state.tr.insertText(prefix + text + suffix, selection.from, selection.to),
          );
        }
      } else if (event.type === "error" || event.type === "cancelled") {
        id = null;
        restore();
        if (event.type === "error") reportError(event.text);
      } else if (event.type === "level") {
        const level = Number(event.text);
        if (Number.isFinite(level))
          setRecording(
            (value) =>
              value && {
                ...value,
                levels: [...value.levels.slice(1), Math.min(1, Math.max(0, level))],
              },
          );
      } else {
        awaitingPermission = false;
        setRecording(
          (value) =>
            value && {
              ...value,
              phase: value.phase === "finishing" ? "finishing" : "listening",
              partial: event.type === "partial" ? event.text : value.partial,
            },
        );
      }
    });
    const down = (event: KeyboardEvent) => {
      if (id) {
        if (event.code === "Space") {
          event.preventDefault();
          event.stopPropagation();
          return;
        }
        cancel();
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
        }
        return;
      }
      if (!dom.closest('[data-slot="composer-shell"]')) return;
      if (pending && event.code !== "Space") insertSpace();
      if (
        event.code !== "Space" ||
        event.isComposing ||
        event.ctrlKey ||
        event.metaKey ||
        event.altKey ||
        event.shiftKey ||
        !editor.isEditable
      )
        return;
      event.preventDefault();
      event.stopPropagation();
      if (event.repeat || pending) return;
      pending = true;
      timer = setTimeout(() => {
        clearHold();
        if (!editor.isEditable || !editor.isFocused) return;
        originalDoc = editor.state.doc;
        selection = editor.state.selection;
        shell = dom.closest<HTMLElement>('[data-slot="composer-shell"]');
        if (!shell) return;
        shell.style.setProperty("--voice-width", `${shell.offsetWidth}px`);
        shell.style.setProperty("--voice-height", `${shell.offsetHeight}px`);
        shell.dataset.voiceRecording = "true";
        setRecording({
          phase: "starting",
          partial: "",
          levels: Array.from({ length: 32 }, () => 0),
          shell,
        });
        const session = randomUUID();
        id = session;
        awaitingPermission = true;
        void voice.control({ id: session, action: "start" }).catch(() => {
          if (id !== session) return;
          cancel();
          reportError(
            "Please try again. If this continues, check microphone and speech permissions.",
          );
        });
      }, 350);
    };
    const up = (event: KeyboardEvent) => {
      if (event.code !== "Space") return;
      if (pending) {
        event.preventDefault();
        insertSpace();
      }
      if (id) {
        event.preventDefault();
        setRecording((value) => value && { ...value, phase: "finishing" });
        void voice.control({ id, action: "stop" }).catch(cancel);
      }
    };
    const blur = () => {
      clearHold();
      if (id && awaitingPermission) {
        setRecording((value) => value && { ...value, phase: "finishing" });
        void voice.control({ id, action: "stop" }).catch(cancel);
      } else cancel();
    };
    const visibility = () => {
      if (document.hidden) cancel();
    };
    dom.addEventListener("keydown", down, true);
    window.addEventListener("keyup", up, true);
    window.addEventListener("blur", blur);
    dom.addEventListener("blur", blur);
    document.addEventListener("visibilitychange", visibility);
    return () => {
      cancel();
      unsubscribe();
      dom.removeEventListener("keydown", down, true);
      window.removeEventListener("keyup", up, true);
      window.removeEventListener("blur", blur);
      dom.removeEventListener("blur", blur);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [editor]);

  return (
    <>
      {recording
        ? createPortal(
            <div
              data-voice-overlay
              role="status"
              aria-label={
                recording.phase === "finishing" ? "Transcribing" : "Recording voice input"
              }
            >
              {/* One status line: the live transcript, once there is one, takes the hint's place. */}
              <div className="flex max-w-full min-w-0 shrink-0 items-center gap-2 text-xs text-muted-foreground">
                <MicIcon className="size-3.5 shrink-0" />
                <span className="min-w-0 truncate">
                  {recording.phase === "starting"
                    ? "Starting microphone…"
                    : recording.phase === "finishing"
                      ? "Transcribing…"
                      : recording.partial || "Release Space to finish"}
                </span>
              </div>
              <div data-voice-waveform aria-hidden>
                {waveformBars.map((bar, index) => (
                  <span
                    key={bar}
                    style={{ height: `${10 + (recording.levels[index] ?? 0) * 90}%` }}
                  />
                ))}
              </div>
            </div>,
            recording.shell,
          )
        : null}
    </>
  );
}
