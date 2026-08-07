"use client";

import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "../lib/cn";

const badge = cva(
  "inline-flex items-center gap-1.5 rounded-pill px-2.5 py-0.5 text-xs font-medium tabular-nums whitespace-nowrap",
  {
    variants: {
      variant: {
        success: "bg-success-muted text-success",
        error: "bg-error-muted text-error",
        warning: "bg-warning-muted text-warning",
        accent: "bg-accent/10 text-accent",
        neutral: "bg-surface-hover text-text-secondary",
        muted: "text-text-tertiary",
      },
      dot: {
        true: "before:h-1.5 before:w-1.5 before:rounded-full before:shrink-0",
        false: "",
      },
    },
    compoundVariants: [
      { variant: "success", dot: true, className: "before:bg-success" },
      { variant: "error", dot: true, className: "before:bg-error" },
      { variant: "warning", dot: true, className: "before:bg-warning" },
      { variant: "accent", dot: true, className: "before:bg-accent" },
      { variant: "neutral", dot: true, className: "before:bg-text-tertiary" },
    ],
    defaultVariants: {
      variant: "neutral",
      dot: false,
    },
  }
);

interface StatusBadgeProps extends VariantProps<typeof badge> {
  children: React.ReactNode;
  className?: string;
}

export default function StatusBadge({ children, variant, dot, className }: StatusBadgeProps) {
  return <span className={cn(badge({ variant, dot }), className)}>{children}</span>;
}
