"use client";

import { useToast } from "../hooks/useToast";
import { X } from "lucide-react";

const variantStyles = {
  success: "border-l-success bg-success-muted/40",
  error: "border-l-error bg-error-muted/40",
  loading: "border-l-accent bg-accent/10",
  info: "border-l-text-secondary bg-surface-elevated",
};

export default function ToastRegion() {
  const { toasts, dismiss } = useToast();

  return (
    <div
      className="fixed right-4 top-4 z-toast flex flex-col gap-2"
      aria-live="polite"
      aria-atomic="true"
    >
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`flex items-center gap-3 rounded-card border border-border px-4 py-3 shadow-xl border-l-4 ${variantStyles[toast.variant]}`}
        >
          {toast.variant === "loading" && (
            <span className="inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-accent border-t-transparent" />
          )}
          <span className="text-[13px] text-text-primary">{toast.message}</span>
          <button
            onClick={() => dismiss(toast.id)}
            className="ml-auto rounded p-1 text-text-tertiary transition hover:text-text-primary"
            aria-label="Dismiss toast"
          >
            <X size={13} />
          </button>
        </div>
      ))}
    </div>
  );
}
