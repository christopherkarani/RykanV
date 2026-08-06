"use client";

import React from "react";

import type { BlockedAction } from "../lib/types.ts";
import type { DashboardMode } from "../lib/dashboard-mode.ts";

export const PI_COVERAGE =
  "Pi protects bash, write, edit, read, grep, find, and ls built-in tools. Custom/MCP-shaped tool names are gated via ryk decide tool (not full MCP protocol mediation). Use ryk run -- pi for process environment, network, and secretless controls.";

export interface RemediationCommand {
  label: string;
  value: string;
}

export function knownHosts(actions: BlockedAction[]): string[] {
  return Array.from(new Set(actions.map((action) => action.host ?? "unknown"))).sort();
}

export function filterActionsByHost(actions: BlockedAction[], selected: string): BlockedAction[] {
  if (selected === "all") return actions;
  return actions.filter((action) => (action.host ?? "unknown") === selected);
}

export function remediationCommandsFor(action: BlockedAction): RemediationCommand[] {
  const commands: RemediationCommand[] = [];
  if (action.rule && /^[A-Za-z0-9_.:-]+$/.test(action.rule)) {
    commands.push({
      label: "Copy allowlist command",
      value: `ryk allowlist add ${action.rule} -r "approved denial remediation"`,
    });
  }
  commands.push({
    label: "Copy suggestion command",
    value: "ryk suggest-allowlist --confidence high --non-interactive",
  });
  return commands;
}

const inactiveChip = "border-border bg-surface text-text-secondary hover:border-border-strong hover:bg-surface-hover";
const activeChip = "border-accent bg-accent/10 text-accent";
const targetClass = "min-h-11 min-w-11 rounded-md border border-border px-3 py-2 text-xs text-text-secondary transition-colors hover:bg-surface-hover focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent";

export function ActivityHostFilter({ actions, selected, onSelect }: {
  actions: BlockedAction[];
  selected: string;
  onSelect: (host: string) => void;
}) {
  return React.createElement(
    "div",
    { className: "flex flex-wrap gap-2", role: "toolbar", "aria-label": "Filter denied actions by host" },
    ...["all", ...knownHosts(actions)].map((host) => React.createElement(
      "button",
      {
        key: host,
        type: "button",
        "aria-pressed": selected === host,
        onClick: () => onSelect(host),
        className: `min-h-11 min-w-11 rounded-full border px-4 py-2 text-xs font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${selected === host ? activeChip : inactiveChip}`,
      },
      host === "all" ? "All hosts" : host,
    )),
  );
}

export function RemediationActions({ action, mode, onRun, onCopy }: {
  action: BlockedAction;
  mode: DashboardMode;
  onRun: (actionId: string) => void;
  onCopy: (value: string, label: string) => void;
}) {
  if (mode !== "workspace") return null;
  const copyButtons = remediationCommandsFor(action).map((command) => React.createElement(
    "button",
    {
      key: command.value,
      type: "button",
      onClick: () => onCopy(command.value, command.label),
      className: targetClass,
    },
    command.label,
  ));
  return React.createElement(
    "div",
    { className: "mt-4 flex flex-wrap gap-2", "aria-label": "Denied action remediation" },
    ...copyButtons,
    React.createElement("button", { type: "button", onClick: () => onRun("suggest-allowlist"), className: targetClass }, "Run suggest-allowlist"),
    React.createElement("button", { type: "button", onClick: () => onRun("allowlist-list"), className: targetClass }, "List allowlist"),
  );
}
