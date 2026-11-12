import { toastManager } from "../ui/toast";
import { useEditor, EditorContent, type Editor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import type { DesktopVoiceEvent } from "@t3tools/contracts";
import { expect, it, vi } from "vite-plus/test";
import { act, render } from "../../../test/render";
import { ComposerVoiceInput } from "./ComposerVoiceInput";

function Fixture({ onReady }: { onReady: (editor: Editor) => void }) {
  const editor = useEditor({
    extensions: [StarterKit],
    content: "<p>Hello</p>",
    onCreate: ({ editor }) => onReady(editor),
  });
  return (
    <div style={{ width: 600 }}>
      {/* Positioned like the real ComposerSurface shell, which anchors the overlay. */}
      <div data-slot="composer-shell" style={{ position: "relative" }}>
        <div style={{ height: 160 }}>
          <EditorContent editor={editor} />
          <ComposerVoiceInput editor={editor} />
        </div>
      </div>
    </div>
  );
}

it("keeps taps as spaces, folds while holding, follows microphone levels, and inserts the final transcript", async () => {
  let listener: (event: DesktopVoiceEvent) => void = () => {};
  const control = vi.fn().mockResolvedValue(undefined);
  const original = window.desktopBridge;
  Object.defineProperty(window, "desktopBridge", {
    configurable: true,
    value: {
      voiceInput: {
        control,
        subscribe: (next: typeof listener) => {
          listener = next;
          return () => {};
        },
      },
    },
  });
  try {
    let editor: Editor | undefined;
    await using screen = await render(
      <Fixture
        onReady={(value) => {
          editor = value;
        }}
      />,
    );
    await expect.poll(() => editor !== undefined).toBe(true);
    await act(() => {
      editor!.commands.setTextSelection(6);
    });
    const input = screen.container.querySelector<HTMLElement>('[contenteditable="true"]')!;
    const shell = screen.container.querySelector<HTMLElement>('[data-slot="composer-shell"]')!;
    input.focus();
    const selection = window.getSelection()!;
    selection.selectAllChildren(input);
    selection.collapseToEnd();
    const down = () =>
      input.dispatchEvent(
        new KeyboardEvent("keydown", { key: " ", code: "Space", bubbles: true, cancelable: true }),
      );
    const up = () =>
      window.dispatchEvent(
        new KeyboardEvent("keyup", { key: " ", code: "Space", bubbles: true, cancelable: true }),
      );
    await act(() => {
      down();
      up();
    });
    expect(input.textContent).toBe("Hello ");
    expect(control).not.toHaveBeenCalled();
    await act(down);
    await expect.poll(() => control.mock.calls.length).toBe(1);
    const id = control.mock.calls[0]![0].id as string;
    await expect.poll(() => Math.round(shell.getBoundingClientRect().width)).toBe(300);
    await expect.poll(() => Math.round(shell.getBoundingClientRect().height)).toBe(80);
    await act(() => {
      listener({ id, type: "listening", text: "" });
      listener({ id, type: "level", text: "0.8" });
    });
    const waveform = screen.container.querySelector("[data-voice-waveform]")!;
    // Bars are a share of the waveform's height, so they scale with the folded composer.
    expect(waveform.lastElementChild?.getAttribute("style")).toContain("82%");
    // The waveform and its loudest bar sit wholly inside the folded composer, not clipped by it.
    const inside = (rect: DOMRect) => {
      const box = shell.getBoundingClientRect();
      return rect.top >= box.top - 0.5 && rect.bottom <= box.bottom + 0.5 && rect.height > 0;
    };
    await expect.poll(() => inside(waveform.getBoundingClientRect())).toBe(true);
    await expect.poll(() => inside(waveform.lastElementChild!.getBoundingClientRect())).toBe(true);
    await act(() => listener({ id, type: "partial", text: "Voice wo" }));
    // The live transcript takes the hint's line instead of adding one.
    expect(screen.container.querySelector("[data-voice-overlay]")?.textContent).toContain(
      "Voice wo",
    );
    expect(screen.container.querySelector("[data-voice-overlay]")?.textContent).not.toContain(
      "Release Space",
    );
    await act(up);
    expect(control).toHaveBeenLastCalledWith({ id, action: "stop" });
    await act(() => listener({ id, type: "final", text: "Voice works." }));
    expect(input.textContent).toBe("Hello Voice works.");
    expect(shell.hasAttribute("data-voice-recording")).toBe(false);
    await expect.poll(() => Math.round(shell.getBoundingClientRect().width)).toBe(600);
    await act(down);
    await expect.poll(() => control.mock.calls.length).toBe(3);
    const nextId = control.mock.calls[2]![0].id as string;
    await act(() => {
      listener({ id: nextId, type: "listening", text: "" });
      input.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "Escape",
          code: "Escape",
          bubbles: true,
          cancelable: true,
        }),
      );
    });
    expect(control).toHaveBeenLastCalledWith({ id: nextId, action: "cancel" });
    await act(() => listener({ id: nextId, type: "final", text: "Must not insert" }));
    expect(input.textContent).toBe("Hello Voice works.");
    expect(shell.hasAttribute("data-voice-recording")).toBe(false);
    using toast = vi.spyOn(toastManager, "add");
    await act(down);
    await expect.poll(() => control.mock.calls.length).toBe(5);
    const failedId = control.mock.calls[4]![0].id as string;
    await act(() =>
      listener({ id: failedId, type: "error", text: "Microphone permission denied." }),
    );
    expect(toast).toHaveBeenCalledWith({
      type: "error",
      title: "Couldn't start voice input",
      description: "Microphone permission denied.",
    });
    expect(shell.textContent).not.toContain("Microphone permission denied.");
    expect(shell.hasAttribute("data-voice-recording")).toBe(false);
  } finally {
    Object.defineProperty(window, "desktopBridge", { configurable: true, value: original });
  }
});
