"use client";

import StatusBadge from "./StatusBadge";

interface PageHeaderProps {
  title: string;
  subtitle?: string;
  eyebrow?: string;
  badge?: {
    text: string;
    variant: "success" | "error" | "warning" | "accent" | "neutral";
  };
  action?: React.ReactNode;
}

export default function PageHeader({ title, subtitle, eyebrow, badge, action }: PageHeaderProps) {
  return (
    <div className="mb-8 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="min-w-0">
        {eyebrow && (
          <span className="mb-1 block text-[11px] font-semibold uppercase tracking-widest text-text-tertiary">
            {eyebrow}
          </span>
        )}
        <div className="flex items-center gap-3">
          <h1 className="text-xl font-semibold tracking-tight text-text-primary">{title}</h1>
          {badge && <StatusBadge variant={badge.variant}>{badge.text}</StatusBadge>}
        </div>
        {subtitle && <p className="mt-1 max-w-xl text-sm text-text-secondary">{subtitle}</p>}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
  );
}
