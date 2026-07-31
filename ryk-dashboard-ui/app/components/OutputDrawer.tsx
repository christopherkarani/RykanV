"use client";

import { useCommandOutput } from "../hooks/useCommandOutput";
import { useKeyboardShortcut } from "../hooks/useKeyboardShortcut";
import { ChevronUp, ChevronDown, Copy, X, Trash2 } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

function useAnsiConverter() {
  const [convert, setConvert] = useState<((input: string) => string) | null>(null);
  useEffect(() => {
    let cancelled = false;
    import("ansi-to-html").then((mod) => {
      if (cancelled) return;
      const Converter = mod.default;
      const c = new Converter({ fg: "#ededed", bg: "#0a0a0a", newline: true });
      setConvert(() => (input: string) => c.toHtml(input));
    });
    return () => { cancelled = true; };
  }, []);
  return convert;
}

export default function OutputDrawer() {
  const { lines, isOpen, isExpanded, clear, toggle, close, scrollRef } = useCommandOutput();
  const ansiConvert = useAnsiConverter();

  useKeyboardShortcut("Escape", () => {
    if (isExpanded) toggle();
  });

  const handleCopy = useCallback(async () => {
    const text = lines.join("\n");
    try { await navigator.clipboard.writeText(text); } catch { /* noop */ }
  }, [lines]);

  if (!isOpen) {
    return (
      <button
        onClick={toggle}
        className="fixed bottom-14 left-0 right-0 z-drawer flex h-drawer-peek items-center justify-center gap-2 border-t border-border bg-surface/90 text-[13px] text-text-tertiary backdrop-blur-md transition hover:text-text-primary md:bottom-0"
        aria-label="Show command output"
      >
        <ChevronUp size={15} />
        <span>Command output</span>
      </button>
    );
  }

  const heightClass = isExpanded ? "h-[85vh] md:h-[60vh]" : "h-48";

  return (
    <div
      className={`fixed bottom-14 left-0 right-0 z-drawer flex flex-col border-t border-border bg-background transition-all duration-complex ease-out md:bottom-0 ${heightClass}`}
      role="region"
      aria-label="Command output"
    >
      <div className="flex h-12 shrink-0 items-center justify-between border-b border-border px-4">
        <div className="flex items-center gap-3">
          <button
            onClick={toggle}
            className="flex h-7 w-7 items-center justify-center rounded text-text-tertiary transition hover:bg-surface-hover hover:text-text-primary"
            aria-label={isExpanded ? "Collapse output" : "Expand output"}
          >
            {isExpanded ? <ChevronDown size={16} /> : <ChevronUp size={16} />}
          </button>
          <span className="text-[13px] font-semibold text-text-primary">Command output</span>
          {lines.length > 0 && (
            <span className="text-[11px] text-text-tertiary">{lines.length} lines</span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={handleCopy}
            className="flex h-7 w-7 items-center justify-center rounded text-text-tertiary transition hover:bg-surface-hover hover:text-text-primary"
            aria-label="Copy output"
            title="Copy output"
          >
            <Copy size={14} />
          </button>
          <button
            onClick={clear}
            className="flex h-7 w-7 items-center justify-center rounded text-text-tertiary transition hover:bg-surface-hover hover:text-text-primary"
            aria-label="Clear output"
            title="Clear output"
          >
            <Trash2 size={14} />
          </button>
          <button
            onClick={close}
            className="flex h-7 w-7 items-center justify-center rounded text-text-tertiary transition hover:bg-surface-hover hover:text-text-primary"
            aria-label="Close output drawer"
            title="Close output drawer"
          >
            <X size={14} />
          </button>
        </div>
      </div>
      <pre
        ref={scrollRef}
        className="flex-1 overflow-auto bg-[#0a0a0a] p-4 font-mono text-[13px] leading-relaxed text-text-primary"
        tabIndex={0}
      >
        {lines.length === 0 ? (
          <span className="text-text-tertiary">No command has run yet.</span>
        ) : (
          lines.map((line, i) => {
            const html = ansiConvert ? ansiConvert(line) : line
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/>/g, "&gt;");
            return (
              <div
                key={i}
                className="whitespace-pre-wrap break-words"
                dangerouslySetInnerHTML={{ __html: html }}
              />
            );
          })
        )}
      </pre>
    </div>
  );
}
