import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';

export interface PaletteCommand {
  id: string;
  label: string;
  detail: string;
  keywords: string;
  run: () => void;
}

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  onJobLookup: (query: string) => void;
  commands: PaletteCommand[];
}

export default function CommandPalette({ open, onClose, onJobLookup, commands }: CommandPaletteProps) {
  const [query, setQuery] = useState('');
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (!open) return;
    window.setTimeout(() => inputRef.current?.focus(), 0);
  }, [open]);

  useEffect(() => {
    if (!open) setQuery('');
  }, [open]);

  const normalized = query.trim().toLowerCase();
  const filtered = useMemo(
    () =>
      commands.filter((item) => {
        if (!normalized) return true;
        return `${item.label} ${item.detail} ${item.keywords}`.toLowerCase().includes(normalized);
      }),
    [commands, normalized],
  );

  if (!open) return null;

  function execute(item: PaletteCommand) {
    item.run();
    onClose();
  }

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (filtered[0]) {
      execute(filtered[0]);
      return;
    }
    if (normalized.length >= 4) {
      onJobLookup(normalized);
      onClose();
    }
  }

  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center px-4 pt-24">
      <button type="button" className="absolute inset-0 bg-void-900/80 backdrop-blur-sm" onClick={onClose} aria-label="Close palette" />
      <div className="relative w-full max-w-2xl rounded-2xl border border-neon-cyan/35 bg-void-900/95 p-4 shadow-neon-xl">
        <form onSubmit={submit} className="mb-3">
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search routes, commands, or paste job id"
            className="input-field w-full border-neon-cyan/30 bg-void-800/80"
          />
        </form>
        <p className="mb-3 text-xs text-gray-500">
          Enter runs the first match, including recent job IDs loaded from /jobs. If nothing matches, Enter searches by raw query.
        </p>
        <div className="max-h-[55vh] space-y-2 overflow-y-auto pr-1">
          {filtered.slice(0, 9).map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => execute(item)}
              className="w-full rounded-xl border border-void-600 bg-void-800/85 p-3 text-left transition-colors hover:border-neon-cyan/50 hover:bg-void-700"
            >
              <p className="text-sm font-semibold text-gray-100">{item.label}</p>
              <p className="mt-1 text-xs text-gray-400">{item.detail}</p>
            </button>
          ))}
          {filtered.length === 0 && (
            <p className="rounded-xl border border-void-600 bg-void-800/85 p-3 text-sm text-gray-400">
              No command match. Press Enter to search jobs for: <span className="text-neon-cyan">{normalized || '...'}</span>
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
