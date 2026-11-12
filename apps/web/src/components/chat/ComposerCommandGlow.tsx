import "./composerCommandGlow.css";

export function ComposerCommandGlow({ prompt }: { prompt: string }) {
  const level = prompt.startsWith("!") ? (prompt.slice(1).trim() ? 2 : 1) : 0;

  return (
    <div aria-hidden="true" data-slot="composer-command-glow" data-level={level}>
      <div />
    </div>
  );
}
