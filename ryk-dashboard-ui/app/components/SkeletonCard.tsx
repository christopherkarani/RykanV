"use client";

export default function SkeletonCard() {
  return (
    <div className="flex flex-col justify-between rounded-card border border-border bg-surface p-5"
    >
      <div className="mb-4 h-2.5 w-16 rounded bg-border animate-pulse" />
      <div className="mb-3 h-7 w-24 rounded bg-border animate-pulse" />
      <div className="h-2.5 w-3/4 rounded bg-border animate-pulse" />
    </div>
  );
}
