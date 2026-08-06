import React from "react";
import { ShieldCheck, Stethoscope, type LucideIcon } from "lucide-react";

import { useDashboardMode, type DashboardMode } from "./dashboard-mode.ts";
import { visibleNavigation } from "./nav.ts";

export interface CommandPaletteItem {
  id: string;
  label: string;
  icon: LucideIcon;
  type: "view" | "action";
  path?: string;
}

const ACTIONS = [
  { id: "doctor", label: "Run Doctor", icon: Stethoscope, machineSafe: true },
  { id: "policy-check", label: "Policy Check", icon: ShieldCheck, machineSafe: false },
  { id: "credentials-check", label: "Credentials Check", icon: ShieldCheck, machineSafe: false },
  { id: "ci-check", label: "CI Check", icon: ShieldCheck, machineSafe: false },
];

export function commandPaletteItems(mode: DashboardMode, query = ""): CommandPaletteItem[] {
  const normalizedQuery = query.toLowerCase();
  const views = visibleNavigation(mode).map((tab) => ({
    id: tab.id,
    label: tab.label,
    icon: tab.icon,
    path: tab.href,
    type: "view" as const,
  }));
  const actions = ACTIONS
    .filter((action) => mode === "workspace" || action.machineSafe)
    .map((action) => ({ ...action, type: "action" as const }));

  return [...views, ...actions].filter((item) => item.label.toLowerCase().includes(normalizedQuery));
}

interface CommandPaletteItemsProps {
  query?: string;
  selectedIndex?: number;
  onSelect?: (item: CommandPaletteItem) => void;
}

export function CommandPaletteItems({ query = "", selectedIndex = 0, onSelect }: CommandPaletteItemsProps = {}) {
  const { mode } = useDashboardMode();
  const items = commandPaletteItems(mode, query);

  if (items.length === 0) {
    return React.createElement("div", { className: "px-4 py-8 text-center text-sm text-text-tertiary" }, "No results found");
  }

  return React.createElement(
    React.Fragment,
    null,
    items.map((item, index) => {
      const Icon = item.icon;
      const isSelected = index === selectedIndex;
      return React.createElement(
        "button",
        {
          key: `${item.type}-${item.id}`,
          role: "option",
          "aria-selected": isSelected,
          className: `flex w-full items-center gap-3 px-4 py-2.5 text-left text-[13px] transition-colors ${
            isSelected ? "bg-accent/10 text-text-primary" : "text-text-secondary hover:bg-surface-hover"
          }`,
          onClick: () => onSelect?.(item),
        },
        React.createElement(Icon, { size: 15, className: "shrink-0", strokeWidth: 1.5 }),
        React.createElement("span", null, item.label),
        React.createElement("span", { className: "ml-auto text-[11px] text-text-tertiary capitalize" }, item.type),
      );
    }),
  );
}
