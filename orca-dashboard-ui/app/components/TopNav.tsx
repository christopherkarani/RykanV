"use client";

import { useState, useCallback } from "react";
import { usePathname } from "next/navigation";
import Link from "next/link";
import { Search, Stethoscope, RefreshCw } from "lucide-react";
import CommandPalette from "./CommandPalette";
import { useKeyboardShortcut } from "../hooks/useKeyboardShortcut";
import { useToast } from "../hooks/useToast";
import { useCommandOutput } from "../hooks/useCommandOutput";
import { runAction } from "../lib/api";
import { isNavTabActive, visibleNavigation } from "../lib/nav";
import { useDashboardMode } from "../lib/dashboard-mode";

export default function TopNav() {
  const pathname = usePathname();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const { mode } = useDashboardMode();
  const { enqueue } = useToast();
  const { append, expand } = useCommandOutput();
  const tabs = visibleNavigation(mode);


  useKeyboardShortcut("k", () => setPaletteOpen(true), { meta: true, preventDefault: true });
  useKeyboardShortcut("k", () => setPaletteOpen(true), { ctrl: true, preventDefault: true });

  const handleRefresh = useCallback(() => {
    if (typeof window !== "undefined") window.location.reload();
  }, []);

  const handleRunDoctor = useCallback(async () => {
    expand();
    append("$ doctor");
    try {
      const result = await runAction("doctor");
      const output = [`$ doctor`, `exit ${result.exit_code}`, result.stdout || "", result.stderr ? `stderr:\n${result.stderr}` : ""]
        .filter(Boolean)
        .join("\n\n");
      append(output);
      enqueue(result.ok ? "Doctor completed" : "Doctor returned non-zero", result.ok ? "success" : "error");
    } catch (err) {
      append(err instanceof Error ? err.message : "Doctor failed");
      enqueue(err instanceof Error ? err.message : "Doctor failed", "error");
    }
  }, [append, expand, enqueue]);

  const handleRunAction = useCallback(
    async (actionId: string) => {
      expand();
      append(`$ ${actionId}`);
      try {
        const result = await runAction(actionId);
        const output = [`$ ${actionId}`, `exit ${result.exit_code}`, result.stdout || "", result.stderr ? `stderr:\n${result.stderr}` : ""]
          .filter(Boolean)
          .join("\n\n");
        append(output);
        enqueue(result.ok ? "Command completed" : "Command returned non-zero", result.ok ? "success" : "error");
      } catch (err) {
        append(err instanceof Error ? err.message : "Command failed");
        enqueue(err instanceof Error ? err.message : "Command failed", "error");
      }
    },
    [append, expand, enqueue]
  );

  return (
    <>
      <nav
        className="fixed left-0 right-0 top-0 z-nav flex h-nav items-center gap-3 border-b border-border bg-background/70 px-4 backdrop-blur-xl md:px-6"
        aria-label="Primary"
      >
        <Link
          href="/"
          className="flex items-center gap-2.5 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
        >
          <div className="flex h-7 w-7 items-center justify-center rounded-md border border-text-primary/80 bg-text-primary text-background font-bold text-xs">
            R
          </div>
          <span className="hidden text-sm font-semibold tracking-tight text-text-primary md:inline">
            ryk
          </span>
        </Link>

        <div className="mx-auto hidden items-center gap-0.5 rounded-full border border-border bg-surface/80 p-0.5 md:inline-flex">
          {tabs.map((tab) => {
            const Icon = tab.icon;
            const isActive = isNavTabActive(pathname, tab.href);
            return (
              <Link
                key={tab.id}
                href={tab.href}
                aria-current={isActive ? "page" : undefined}
                className={`flex items-center gap-1.5 rounded-full px-3 py-1.5 text-[13px] font-medium transition-all duration-micro focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
                  isActive
                    ? "bg-accent text-white shadow-sm shadow-accent/20"
                    : "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
                }`}
              >
                <Icon size={14} strokeWidth={1.5} />
                <span>{tab.label}</span>
              </Link>
            );
          })}
        </div>

        <div className="ml-auto flex items-center gap-1.5">
          <button
            onClick={() => setPaletteOpen(true)}
            className="flex h-8 w-8 items-center justify-center rounded-md border border-border bg-surface/80 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent md:hidden"
            aria-label="Open command palette"
            title="Search commands"
          >
            <Search size={15} strokeWidth={1.5} />
          </button>
          <button
            onClick={() => setPaletteOpen(true)}
            className="hidden items-center gap-2 rounded-md border border-border bg-surface/80 px-2.5 py-1.5 text-[13px] text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent md:inline-flex"
            aria-label="Open command palette"
          >
            <Search size={13} strokeWidth={1.5} />
            <span>Command</span>
            <kbd className="ml-1 rounded border border-border bg-background px-1 py-0 text-[10px] font-mono text-text-tertiary">
              ⌘K
            </kbd>
          </button>
          <button
            onClick={handleRefresh}
            className="flex h-8 w-8 items-center justify-center rounded-md text-text-tertiary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            aria-label="Refresh data"
            title="Refresh"
          >
            <RefreshCw size={15} strokeWidth={1.5} />
          </button>
          <button
            onClick={handleRunDoctor}
            className="flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-white shadow-sm shadow-accent/20 transition-all hover:bg-accent-hover active:scale-[0.97] focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            <Stethoscope size={14} strokeWidth={1.5} />
            <span className="hidden sm:inline">Run Doctor</span>
          </button>
        </div>
      </nav>
      <nav
        className="fixed inset-x-0 bottom-0 z-nav border-t border-border bg-background/95 pb-[env(safe-area-inset-bottom,0px)] backdrop-blur-xl md:hidden"
        aria-label="Mobile primary"
      >
        <div className="mx-auto flex h-14 max-w-lg items-stretch justify-around px-1">
          {tabs.map((tab) => {
            const Icon = tab.icon;
            const isActive = isNavTabActive(pathname, tab.href);
            return (
              <Link key={tab.id} href={tab.href} aria-label={tab.label} aria-current={isActive ? "page" : undefined}
                className={`flex min-h-[44px] min-w-[44px] flex-1 flex-col items-center justify-center gap-0.5 rounded-md px-1 py-1 text-[10px] font-medium ${isActive ? "text-accent" : "text-text-tertiary"}`}>
                <Icon size={18} strokeWidth={isActive ? 2 : 1.5} aria-hidden="true" />
                <span aria-hidden="true" className="max-w-full truncate">{tab.shortLabel}</span>
              </Link>
            );
          })}
        </div>
      </nav>
      <CommandPalette isOpen={paletteOpen} onClose={() => setPaletteOpen(false)} onRunAction={handleRunAction} />
    </>
  );
}
