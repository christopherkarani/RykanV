"use client";

import StatusBadge from "./StatusBadge";

interface StatCardProps {
  label: string;
  value: string;
  detail: string;
  status?: "success" | "error" | "warning" | "neutral";
}

export default function StatCard({ label, value, detail, status = "neutral" }: StatCardProps) {
  return (
    <article className="group relative flex flex-col justify-between rounded-card border border-border bg-surface p-5 transition-all duration-micro hover:border-border-strong hover:bg-surface-hover"
    >
      <div className="flex items-start justify-between gap-2"
      >
        <span className="text-[11px] font-semibold uppercase tracking-widest text-text-tertiary"
        >
          {label}
        </span>
        {status !== "neutral" && (
          <span className={`h-2 w-2 rounded-full shrink-0 mt-0.5 ${
            status === "success" ? "bg-success" : status === "error" ? "bg-error" : "bg-warning"
          }`} />
        )}
      </div>
      <div className="mt-3 text-[22px] font-semibold tracking-tight text-text-primary leading-tight"
      >
        {value}
      </div>
      <div className="mt-2 text-[13px] leading-relaxed text-text-secondary break-words"
      >
        {detail}
      </div>
    </article>
  );
}
