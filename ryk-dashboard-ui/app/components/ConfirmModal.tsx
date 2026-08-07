"use client";

import { useEffect, useRef } from "react";

interface ConfirmModalProps {
  open: boolean;
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmModal({ open, title, message, confirmLabel = "Confirm", cancelLabel = "Cancel", onConfirm, onCancel }: ConfirmModalProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleKey(e: KeyboardEvent) {
      if (e.key === "Escape") onCancel();
    }
    if (open) {
      window.addEventListener("keydown", handleKey);
      ref.current?.focus();
    }
    return () => window.removeEventListener("keydown", handleKey);
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-modal flex items-center justify-center bg-black/60 backdrop-blur-sm"
      onClick={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-title"
    >
      <div
        ref={ref}
        tabIndex={-1}
        className="w-full max-w-md rounded-lg border border-border bg-surface p-6 shadow-2xl outline-none"
      >
        <h2 id="confirm-title" className="text-lg font-semibold text-text-primary">{title}</h2>
        <p className="mt-2 text-sm text-text-secondary">{message}</p>
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={onCancel}
            className="rounded border border-border bg-transparent px-4 py-2 text-sm text-text-secondary hover:bg-surface-elevated focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            {cancelLabel}
          </button>
          <button
            onClick={onConfirm}
            className="rounded bg-error px-4 py-2 text-sm font-medium text-white hover:brightness-110 focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
